// Command harness launches Far Cry instances (server + N clients) with an in-game
// Lua agent, drives them with console/Lua commands and collects state, logs,
// screenshots and minidumps. Build: GOARCH=386 go build -o ../bin/harness.exe ./harness
package main

import (
	"bufio"
	"flag"
	"fmt"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const usage = `harness — FC1 co-op test harness

  up [-mode sp|host] [-map training] [-mission Training] [-clients N] [-mod NAME] [-asi FILE] [-w 800 -h 600] [-start "cmd;cmd"]
                          start a run (server + clients) and wait until levels are loaded
  status                  instances, pids, heartbeat age, last events
  state [inst...]         agent state (level, players, AI, position)
  cmd <inst> <command>    run a console command in the instance
  lua <inst> <code>       run Lua code in the instance
  wait <inst> <cond> [-t 60s]   wait for state condition: key=value, key!=value, key>=N, key<=N
  waitlog <inst> <regex> [-t 60s]
  log <inst> [-n 40] [-grep regex]
  events [-n 40]
  shot [inst|all]         save screenshot(s), print png paths
  diff [-tol 0.5] [-n 20] snapshot all entities on every instance and compare clients with the server
  test <scenario> [-keep] run a scenario file (tests/*.txt), PASS/FAIL per step
  test <scenario> [-keep] run a scenario file (tests/*.txt), PASS/FAIL per step
  dump <inst>             write a minidump of the process
  down                    quit all instances, restore game configs
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(2)
	}
	var err error
	args := os.Args[2:]
	switch os.Args[1] {
	case "up":
		err = cmdUp(args)
	case "supervise":
		err = cmdSupervise(args[0])
	case "status":
		err = cmdStatus()
	case "state":
		err = cmdState(args)
	case "cmd":
		err = cmdCmd(args, "")
	case "lua":
		err = cmdCmd(args, "lua ")
	case "wait":
		err = cmdWait(args)
	case "waitlog":
		err = cmdWaitLog(args)
	case "log":
		err = cmdLog(args)
	case "events":
		err = cmdEvents(args)
	case "shot":
		err = cmdShot(args)
	case "test":
		err = cmdTest(args)
	case "diff":
		err = cmdDiff(args)
	case "dump":
		err = cmdDump(args)
	case "down":
		err = cmdDown()
	default:
		fmt.Print(usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// splitFlags lets flags follow positional arguments: "cmd server map x -t 5s".
func splitFlags(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos []string
	for len(args) > 0 {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) > 0 {
			pos = append(pos, args[0])
			args = args[1:]
		}
	}
	return pos, nil
}

func cmdUp(args []string) error {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	mode := fs.String("mode", "sp", "sp: single player map; host: listen server + clients")
	mapName := fs.String("map", "training", "level name")
	mission := fs.String("mission", "", "mission name (default: map name; SP maps use e.g. Training)")
	clients := fs.Int("clients", 0, "number of clients (host mode)")
	mod := fs.String("mod", "", "mod folder under Mods/ (FarCryCoop is built from games/far-cry/mod)")
	asi := fs.String("asi", "", "DLL to inject into every instance before it runs (e.g. tools/bin/FarCryCoopNet.asi)")
	w := fs.Int("w", 800, "window width")
	h := fs.Int("h", 600, "window height")
	sound := fs.Bool("sound", false, "keep the game's sound (muted by default: effects and music volume 0)")
	start := fs.String("start", "", "server start commands separated by ';' (default by mode)")
	gameDir := fs.String("game", gameDir(), "Far Cry install dir (default: $FC1_GAME_DIR, .harness/game-dir.txt, Steam)")
	pname := fs.String("pname", "", "every client plays under this p_name and is told apart by its COOP_PlayerKey, as the launcher does")
	keys := fs.String("keys", "", "with -pname: the clients' COOP_PlayerKey in order, separated by ',' (default: the instance name)")
	fs.Parse(args)

	if r, err := currentRun(); err == nil && anyAlive(r) {
		return fmt.Errorf("run %s still has live instances, use `harness down`", r.Dir)
	}
	// The Steam build exits at once (status 53, empty log) when Steam is not running.
	if !steamRunning() {
		return fmt.Errorf("Steam is not running: the Steam build of Far Cry exits at start without it")
	}
	root, err := repoRoot()
	if err != nil {
		return err
	}
	home := filepath.Join(root, ".harness")
	if *mod != "" {
		if err := installMod(root, *gameDir, *mod); err != nil {
			return fmt.Errorf("install mod: %w", err)
		}
	}
	runDir := filepath.Join(home, "runs", time.Now().Format("20060102-150405"))
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		return err
	}

	// The FarCryCoop ASI recognises a co-op client by a Game:Connect( line (see joinMode).
	clientConnect := "connect 127.0.0.1"
	if *asi != "" && strings.EqualFold(*mod, "FarCryCoop") {
		clientConnect = `#Game:Connect("127.0.0.1",1,1)`
	}
	var serverCmds []string
	switch {
	case *start != "":
		serverCmds = strings.Split(*start, ";")
	case *mode == "sp":
		serverCmds = []string{"map " + *mapName}
	case *mode == "host":
		// start_server only accepts MP missions; load the SP mission with listen=true instead.
		m := *mission
		if m == "" {
			m = *mapName
		}
		serverCmds = []string{fmt.Sprintf("#Game:LoadLevelListen('%s','%s')", *mapName, m)}
	default:
		return fmt.Errorf("unknown mode %q", *mode)
	}
	run := &Run{Dir: runDir, GameDir: *gameDir, Agent: filepath.Join(root, "scripts", "harness", "agent.lua"),
		Mode: *mode, Map: *mapName, Mod: *mod, Width: *w, Height: *h, Sound: *sound, PName: *pname, Started: time.Now()}
	if *asi != "" {
		a, err := filepath.Abs(*asi)
		if err != nil {
			return err
		}
		run.ASI = a
	}
	run.Instances = append(run.Instances, &Instance{Name: "server", Role: "server",
		Dir: filepath.Join(runDir, "server"), Commands: serverCmds})
	keyList := strings.Split(*keys, ",")
	for i := 1; i <= *clients; i++ {
		in := &Instance{Name: fmt.Sprintf("client%d", i), Role: "client",
			Dir: filepath.Join(runDir, fmt.Sprintf("client%d", i)), Commands: []string{clientConnect}}
		if *pname != "" {
			in.Key = in.Name
			if i <= len(keyList) && keyList[i-1] != "" {
				in.Key = keyList[i-1]
			}
		}
		run.Instances = append(run.Instances, in)
	}
	if err := run.Save(); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(home, "current"), []byte(runDir), 0o644); err != nil {
		return err
	}

	// Detached supervisor owns the game processes and outlives this command.
	self, _ := os.Executable()
	sup := exec.Command(self, "supervise", runDir)
	logf, _ := os.Create(filepath.Join(runDir, "supervisor.log"))
	sup.Stdout, sup.Stderr = logf, logf
	sup.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x00000008 | 0x00000200} // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
	if err := sup.Start(); err != nil {
		return err
	}
	fmt.Println("run:", runDir)

	// Follow events until ready/failed.
	off := 0
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		lines := readLines(filepath.Join(runDir, "events.log"))
		for _, l := range lines[off:] {
			fmt.Println(l)
			f := strings.Split(l, "\t")
			if len(f) >= 3 && (f[2] == "ready" || f[2] == "failed" || f[2] == "done") {
				if f[2] != "ready" {
					return fmt.Errorf("startup failed, see %s", runDir)
				}
				return nil
			}
		}
		off = len(lines)
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("startup timeout")
}

func anyAlive(r *Run) bool {
	for _, in := range r.Instances {
		if in.PID != 0 && processAlive(in.PID) {
			return true
		}
	}
	return false
}

func processAlive(pid int) bool {
	const queryLimited, stillActive = 0x1000, 259
	h, err := syscall.OpenProcess(queryLimited, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if syscall.GetExitCodeProcess(h, &code) != nil {
		return false
	}
	return code == stillActive
}

func steamRunning() bool {
	out, err := exec.Command("tasklist", "/FI", "IMAGENAME eq steam.exe", "/NH").Output()
	return err == nil && strings.Contains(strings.ToLower(string(out)), "steam.exe")
}

func cmdStatus() error {
	r, err := currentRun()
	if err != nil {
		return err
	}
	fmt.Printf("run %s  mode=%s map=%s mod=%s\n", r.Dir, r.Mode, r.Map, r.Mod)
	for _, in := range r.Instances {
		alive := processAlive(in.PID)
		hb := "-"
		if st, mt, err := readState(in); err == nil {
			hb = fmt.Sprintf("heartbeat %s ago, level=%s players=%s ai=%s/%s", time.Since(mt).Round(100*time.Millisecond),
				st["level"], st["players"], st["ai.alive"], st["ai"])
		}
		dlg := ""
		if alive {
			for _, d := range dialogs(in.PID) {
				dlg += " DIALOG[" + d.Title + "]"
			}
		}
		fmt.Printf("  %-8s pid=%-6d alive=%-5v %s%s\n", in.Name, in.PID, alive, hb, dlg)
	}
	lines := readLines(filepath.Join(r.Dir, "events.log"))
	if len(lines) > 8 {
		lines = lines[len(lines)-8:]
	}
	for _, l := range lines {
		fmt.Println("  ", l)
	}
	return nil
}

func cmdState(args []string) error {
	r, err := currentRun()
	if err != nil {
		return err
	}
	insts := r.Instances
	if len(args) > 0 {
		insts = nil
		for _, a := range args {
			in, err := r.Inst(a)
			if err != nil {
				return err
			}
			insts = append(insts, in)
		}
	}
	for _, in := range insts {
		st, mt, err := readState(in)
		if err != nil {
			fmt.Printf("[%s] no state: %v\n", in.Name, err)
			continue
		}
		fmt.Printf("[%s] (%s ago)\n", in.Name, time.Since(mt).Round(100*time.Millisecond))
		keys := make([]string, 0, len(st))
		for k := range st {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Printf("  %s=%s\n", k, st[k])
		}
	}
	return nil
}

// sendCommand appends a command to the agent's cmd.txt and returns its sequence number.
func sendCommand(in *Instance, command string) int {
	p := filepath.Join(in.Dir, "cmd.txt")
	seq := len(readLines(p)) + 1
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return 0
	}
	defer f.Close()
	fmt.Fprintf(f, "%d\t%s\n", seq, command)
	return seq
}

func cmdCmd(args []string, prefix string) error {
	fs := flag.NewFlagSet("cmd", flag.ExitOnError)
	timeout := fs.Duration("t", 10*time.Second, "ack timeout")
	pos, err := splitFlags(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 2 {
		return fmt.Errorf("usage: cmd <inst> <command>")
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(pos[0])
	if err != nil {
		return err
	}
	status, info, err := execWait(in, prefix+strings.Join(pos[1:], " "), *timeout)
	if err != nil {
		return err
	}
	fmt.Println(status, info)
	if status != "ok" {
		return fmt.Errorf("command failed, see `harness log %s`", in.Name)
	}
	return nil
}

// execWait sends a command to the agent and waits for its ack.
func execWait(in *Instance, command string, timeout time.Duration) (status, info string, err error) {
	seq := sendCommand(in, command)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, l := range readLines(filepath.Join(in.Dir, "ack.txt")) {
			f := strings.SplitN(l, "\t", 3)
			if len(f) >= 2 && f[0] == strconv.Itoa(seq) {
				if len(f) == 3 {
					info = f[2]
				}
				return f[1], info, nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return "", "", fmt.Errorf("[%s] no ack for #%d in %s (agent not ticking? check `harness status`)", in.Name, seq, timeout)
}

var condRe = regexp.MustCompile(`^([\w.]+)(>=|<=|!=|=)(.*)$`)

func cmdWait(args []string) error {
	fs := flag.NewFlagSet("wait", flag.ExitOnError)
	timeout := fs.Duration("t", 60*time.Second, "timeout")
	pos, err := splitFlags(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 2 {
		return fmt.Errorf("usage: wait <inst> <cond>")
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(pos[0])
	if err != nil {
		return err
	}
	m := condRe.FindStringSubmatch(pos[1])
	if m == nil {
		return fmt.Errorf("bad condition %q", pos[1])
	}
	key, op, want := m[1], m[2], m[3]
	deadline := time.Now().Add(*timeout)
	last := ""
	for time.Now().Before(deadline) {
		if st, _, err := readState(in); err == nil {
			last = st[key]
			if evalCond(last, op, want) {
				fmt.Printf("%s=%s\n", key, last)
				return nil
			}
		}
		if !processAlive(in.PID) {
			return fmt.Errorf("%s is not running", in.Name)
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("timeout: %s=%q", key, last)
}

func evalCond(have, op, want string) bool {
	switch op {
	case "=":
		return strings.EqualFold(have, want)
	case "!=":
		return !strings.EqualFold(have, want)
	}
	h, err1 := strconv.ParseFloat(have, 64)
	w, err2 := strconv.ParseFloat(want, 64)
	if err1 != nil || err2 != nil {
		return false
	}
	if op == ">=" {
		return h >= w
	}
	return h <= w
}

func cmdWaitLog(args []string) error {
	fs := flag.NewFlagSet("waitlog", flag.ExitOnError)
	timeout := fs.Duration("t", 60*time.Second, "timeout")
	pos, err := splitFlags(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 2 {
		return fmt.Errorf("usage: waitlog <inst> <regex>")
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(pos[0])
	if err != nil {
		return err
	}
	re, err := regexp.Compile(pos[1])
	if err != nil {
		return err
	}
	p := filepath.Join(in.Dir, "game.log")
	start := len(readLines(p))
	deadline := time.Now().Add(*timeout)
	for time.Now().Before(deadline) {
		lines := readLines(p)
		for _, l := range lines[min(start, len(lines)):] {
			if re.MatchString(l) {
				fmt.Println(l)
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %q", pos[1])
}

func cmdLog(args []string) error {
	fs := flag.NewFlagSet("log", flag.ExitOnError)
	n := fs.Int("n", 40, "lines")
	grep := fs.String("grep", "", "filter regex")
	pos, err := splitFlags(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: log <inst>")
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(pos[0])
	if err != nil {
		return err
	}
	lines := readLines(filepath.Join(in.Dir, "game.log"))
	if *grep != "" {
		re, err := regexp.Compile(*grep)
		if err != nil {
			return err
		}
		var f []string
		for _, l := range lines {
			if re.MatchString(l) {
				f = append(f, l)
			}
		}
		lines = f
	}
	if len(lines) > *n {
		lines = lines[len(lines)-*n:]
	}
	for _, l := range lines {
		fmt.Println(l)
	}
	return nil
}

func cmdEvents(args []string) error {
	fs := flag.NewFlagSet("events", flag.ExitOnError)
	n := fs.Int("n", 40, "lines")
	fs.Parse(args)
	r, err := currentRun()
	if err != nil {
		return err
	}
	lines := readLines(filepath.Join(r.Dir, "events.log"))
	if len(lines) > *n {
		lines = lines[len(lines)-*n:]
	}
	for _, l := range lines {
		fmt.Println(l)
	}
	return nil
}

func cmdShot(args []string) error {
	r, err := currentRun()
	if err != nil {
		return err
	}
	insts := r.Instances
	if len(args) > 0 && args[0] != "all" {
		in, err := r.Inst(args[0])
		if err != nil {
			return err
		}
		insts = []*Instance{in}
	}
	for _, in := range insts {
		w, ok := mainWindow(in.PID)
		if !ok {
			fmt.Printf("[%s] no window\n", in.Name)
			continue
		}
		img, err := capture(w.H)
		if err != nil {
			fmt.Printf("[%s] capture failed: %v\n", in.Name, err)
			continue
		}
		p := filepath.Join(in.Dir, "shot-"+time.Now().Format("150405.000")+".png")
		f, err := os.Create(p)
		if err != nil {
			return err
		}
		png.Encode(f, img)
		f.Close()
		fmt.Println(p)
	}
	return nil
}

func cmdDump(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: dump <inst>")
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(args[0])
	if err != nil {
		return err
	}
	p := filepath.Join(in.Dir, "manual-"+time.Now().Format("150405")+".dmp")
	if err := writeMinidump(in.PID, p); err != nil {
		return err
	}
	fmt.Println(p)
	return nil
}

func cmdDown() error {
	r, err := currentRun()
	if err != nil {
		return err
	}
	os.WriteFile(filepath.Join(r.Dir, "down.req"), nil, 0o644)
	deadline := time.Now().Add(40 * time.Second)
	for time.Now().Before(deadline) {
		for _, l := range readLines(filepath.Join(r.Dir, "events.log")) {
			if strings.Contains(l, "\trestored\t") {
				return cmdEvents([]string{"-n", "12"})
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("supervisor did not finish; check %s", r.Dir)
}

func readLines(p string) []string {
	f, err := os.Open(p)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	return out
}
