package main

import (
	"errors"
	"fmt"
	"image/png"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// cfgFiles are written by the game on quit or touched by the harness; restored after the run.
var cfgFiles = []string{"system.cfg", "game.cfg", "SystemCfgOverride.cfg"}

type supervisor struct {
	run    *Run
	mu     sync.Mutex
	procs  map[string]*exec.Cmd
	exited map[string]bool
	// monitor bookkeeping
	seenDialogs map[hwnd]bool
	stalled     map[string]bool
	errLogTime  time.Time
}

func cmdSupervise(runDir string) error {
	run, err := loadRun(runDir)
	if err != nil {
		return err
	}
	s := &supervisor{run: run, procs: map[string]*exec.Cmd{}, exited: map[string]bool{},
		seenDialogs: map[hwnd]bool{}, stalled: map[string]bool{}}
	ev := func(inst, kind, msg string) { appendEvent(run.Dir, inst, kind, msg) }

	if err := s.backupConfigs(); err != nil {
		ev("-", "failed", "backup configs: "+err.Error())
		return err
	}
	defer s.restoreConfigs()
	if st, err := os.Stat(filepath.Join(run.GameDir, "error.log")); err == nil {
		s.errLogTime = st.ModTime()
	}

	if err := s.startAll(); err != nil {
		ev("-", "failed", err.Error())
		s.shutdown()
		return err
	}
	ev("-", "ready", "all instances up")
	s.monitor()
	return nil
}

func (s *supervisor) backupConfigs() error {
	bak := filepath.Join(s.run.Dir, "cfg-backup")
	if err := os.MkdirAll(bak, 0o755); err != nil {
		return err
	}
	for _, f := range cfgFiles {
		src := filepath.Join(s.run.GameDir, f)
		if _, err := os.Stat(src); errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err := copyFile(src, filepath.Join(bak, f)); err != nil {
			return err
		}
	}
	// Plugins compute the game folder from their own path (<game>\Bin32\x.asi).
	if s.run.ASI != "" {
		if err := copyFile(s.run.ASI, s.asiInGame()); err != nil {
			return err
		}
	}
	// Windowed mode for every instance: loaded by CSystem::Init right after System.cfg.
	// The user's system.cfg may have log_FileVerbosity = 0, which silences the log after init.
	override := fmt.Sprintf("r_Fullscreen = \"0\"\r\nr_Width = \"%d\"\r\nr_Height = \"%d\"\r\n"+
		"log_Verbosity = \"3\"\r\nlog_FileVerbosity = \"3\"\r\n", s.run.Width, s.run.Height)
	return os.WriteFile(filepath.Join(s.run.GameDir, "SystemCfgOverride.cfg"), []byte(override), 0o644)
}

func (s *supervisor) asiInGame() string {
	return filepath.Join(s.run.GameDir, "Bin32", filepath.Base(s.run.ASI))
}

func (s *supervisor) restoreConfigs() {
	if s.run.ASI != "" {
		os.Remove(s.asiInGame())
	}
	bak := filepath.Join(s.run.Dir, "cfg-backup")
	for _, f := range cfgFiles {
		dst := filepath.Join(s.run.GameDir, f)
		src := filepath.Join(bak, f)
		if _, err := os.Stat(src); err == nil {
			copyFile(src, dst)
		} else {
			os.Remove(dst)
		}
	}
	appendEvent(s.run.Dir, "-", "restored", "game configs restored")
}

func (s *supervisor) startAll() error {
	for i, in := range s.run.Instances {
		if err := s.start(in); err != nil {
			return fmt.Errorf("%s: %w", in.Name, err)
		}
		if err := s.waitWindow(in, i); err != nil {
			return fmt.Errorf("%s: %w", in.Name, err)
		}
		// The server must have the level loaded before clients connect.
		if in.Role == "server" {
			if err := s.waitLevel(in, 2*time.Minute); err != nil {
				return fmt.Errorf("%s: %w", in.Name, err)
			}
		}
	}
	for _, in := range s.run.Instances {
		if in.Role == "client" {
			if err := s.waitLevel(in, 2*time.Minute); err != nil {
				return fmt.Errorf("%s: %w", in.Name, err)
			}
		}
	}
	return nil
}

func (s *supervisor) start(in *Instance) error {
	if err := os.MkdirAll(in.Dir, 0o755); err != nil {
		return err
	}
	for _, f := range []string{"cmd.txt", "ack.txt", "state.txt", "state.tmp"} {
		os.Remove(filepath.Join(in.Dir, f))
	}
	// FarCry.exe truncates its command line at 256 chars (MAX_CMDLINE_LEN in the
	// launcher), so everything except a short dofile goes into boot.lua.
	boot := fmt.Sprintf("HARNESS_DIR = '%s'\nHARNESS_NAME = '%s'\ndofile('%s')\n",
		slash(in.Dir), in.Name, slash(s.run.Agent))
	if !s.joinMode() {
		for _, c := range in.Commands {
			boot += fmt.Sprintf("System:ExecuteCommand(%q)\n", c)
		}
	}
	if err := os.WriteFile(filepath.Join(in.Dir, "boot.lua"), []byte(boot), 0o644); err != nil {
		return err
	}
	args := []string{
		"-DEVMODE",
		"-LOGFILE:" + slash(filepath.Join(in.Dir, "game.log")),
	}
	if s.run.Mod != "" {
		args = append(args, "-MOD:"+s.run.Mod)
	}
	args = append(args, quote(fmt.Sprintf("#dofile('%s')", slash(filepath.Join(in.Dir, "boot.lua")))))
	exe := filepath.Join(s.run.GameDir, "Bin32", "FarCry.exe")
	cmd := exec.Command(exe)
	cmd.Dir = s.run.GameDir
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: quote(exe) + " " + strings.Join(args, " ")}
	if s.run.ASI != "" {
		cmd.SysProcAttr.CreationFlags = 0x4 // CREATE_SUSPENDED: inject before any game code runs
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	in.PID = cmd.Process.Pid
	if s.run.ASI != "" {
		if err := injectDLL(in.PID, s.asiInGame()); err != nil {
			appendEvent(s.run.Dir, in.Name, "warn", "inject: "+err.Error())
		} else {
			appendEvent(s.run.Dir, in.Name, "inject", s.asiInGame())
		}
		if err := resumeProcess(in.PID); err != nil {
			cmd.Process.Kill()
			return err
		}
	}
	s.run.Save()
	appendEvent(s.run.Dir, in.Name, "start", fmt.Sprintf("pid=%d %s", in.PID, cmd.SysProcAttr.CmdLine))
	if s.joinMode() {
		go s.deliverJoin(in)
	}

	s.mu.Lock()
	s.procs[in.Name] = cmd
	s.mu.Unlock()
	go func() {
		err := cmd.Wait()
		code := uint32(0)
		if cmd.ProcessState != nil {
			code = uint32(cmd.ProcessState.ExitCode())
		}
		s.mu.Lock()
		s.exited[in.Name] = true
		s.mu.Unlock()
		kind := "exit"
		if code >= 0xC0000000 {
			kind = "crash"
		}
		appendEvent(s.run.Dir, in.Name, kind, fmt.Sprintf("code=0x%08X err=%v", code, err))
	}()
	return nil
}

func quote(s string) string { return `"` + s + `"` }

func (s *supervisor) downRequested() bool {
	_, err := os.Stat(filepath.Join(s.run.Dir, "down.req"))
	return err == nil
}

func (s *supervisor) alive(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.procs[name] != nil && !s.exited[name]
}

// waitWindow waits for the render window and tiles it left to right.
func (s *supervisor) waitWindow(in *Instance, slot int) error {
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		if s.downRequested() {
			return errors.New("down requested")
		}
		if !s.alive(in.Name) {
			return errors.New("process exited during startup")
		}
		if w, ok := mainWindow(in.PID); ok {
			ww := int(w.Rect.Right - w.Rect.Left)
			moveWindow(w.H, slot*(ww+4), 0)
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return errors.New("no window after 90s")
}

func (s *supervisor) waitLevel(in *Instance, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s.downRequested() {
			return errors.New("down requested")
		}
		if !s.alive(in.Name) {
			return errors.New("process exited while loading")
		}
		s.checkDialogs(in)
		if st, _, err := readState(in); err == nil && st.levelLoaded() {
			appendEvent(s.run.Dir, in.Name, "level", st["level"])
			// A level started from the console leaves the in-game menu open on top.
			sendCommand(in, "lua Game:HideMenu()")
			return nil
		}
		time.Sleep(time.Second)
	}
	s.snapshot(in, "timeout")
	return fmt.Errorf("level not loaded after %s", timeout)
}

func (s *supervisor) monitor() {
	for {
		if s.downRequested() {
			s.shutdown()
			return
		}
		allDead := true
		for _, in := range s.run.Instances {
			if !s.alive(in.Name) {
				continue
			}
			allDead = false
			s.checkDialogs(in)
			s.checkHeartbeat(in)
		}
		if allDead {
			s.collectErrorLog()
			appendEvent(s.run.Dir, "-", "done", "all instances exited")
			return
		}
		time.Sleep(time.Second)
	}
}

func (s *supervisor) checkDialogs(in *Instance) {
	for _, d := range dialogs(in.PID) {
		if s.seenDialogs[d.H] {
			continue
		}
		s.seenDialogs[d.H] = true
		appendEvent(s.run.Dir, in.Name, "dialog", d.Title+": "+dialogText(d.H))
		s.snapshot(in, "dialog")
	}
}

func (s *supervisor) checkHeartbeat(in *Instance) {
	st, err := os.Stat(filepath.Join(in.Dir, "state.txt"))
	if err != nil {
		return
	}
	age := time.Since(st.ModTime())
	if age > 20*time.Second && !s.stalled[in.Name] {
		s.stalled[in.Name] = true
		appendEvent(s.run.Dir, in.Name, "stall", fmt.Sprintf("no agent heartbeat for %s", age.Round(time.Second)))
		s.snapshot(in, "stall")
	} else if age < 5*time.Second && s.stalled[in.Name] {
		s.stalled[in.Name] = false
		appendEvent(s.run.Dir, in.Name, "recovered", "agent heartbeat back")
	}
}

// snapshot saves a screenshot and a minidump for post-mortem analysis.
func (s *supervisor) snapshot(in *Instance, why string) {
	stamp := time.Now().Format("150405")
	if w, ok := mainWindow(in.PID); ok {
		if img, err := capture(w.H); err == nil {
			p := filepath.Join(in.Dir, fmt.Sprintf("%s-%s.png", why, stamp))
			if f, err := os.Create(p); err == nil {
				png.Encode(f, img)
				f.Close()
			}
		}
	}
	p := filepath.Join(in.Dir, fmt.Sprintf("%s-%s.dmp", why, stamp))
	if err := writeMinidump(in.PID, p); err != nil {
		appendEvent(s.run.Dir, in.Name, "warn", "minidump: "+err.Error())
	} else {
		appendEvent(s.run.Dir, in.Name, "dump", p)
	}
}

func (s *supervisor) shutdown() {
	appendEvent(s.run.Dir, "-", "down", "shutting down")
	for _, in := range s.run.Instances {
		if s.alive(in.Name) {
			sendCommand(in, "quit")
		}
	}
	// Agent may be dead; also ask the window to close.
	for _, in := range s.run.Instances {
		if w, ok := mainWindow(in.PID); ok && s.alive(in.Name) {
			closeWindow(w.H)
		}
	}
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		any := false
		for _, in := range s.run.Instances {
			any = any || s.alive(in.Name)
		}
		if !any {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	for _, in := range s.run.Instances {
		if s.alive(in.Name) {
			appendEvent(s.run.Dir, in.Name, "kill", "did not quit in 15s")
			s.mu.Lock()
			s.procs[in.Name].Process.Kill()
			s.mu.Unlock()
		}
	}
	time.Sleep(time.Second)
	s.collectErrorLog()
	os.Remove(filepath.Join(s.run.Dir, "down.req"))
	appendEvent(s.run.Dir, "-", "done", "shutdown complete")
}

// collectErrorLog copies the engine crash report (written to the game root) if it changed.
func (s *supervisor) collectErrorLog() {
	src := filepath.Join(s.run.GameDir, "error.log")
	st, err := os.Stat(src)
	if err != nil || !st.ModTime().After(s.errLogTime) {
		return
	}
	dst := filepath.Join(s.run.Dir, "error.log")
	if copyFile(src, dst) == nil {
		appendEvent(s.run.Dir, "-", "errorlog", dst)
	}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// joinMode: the FarCryCoop ASI only treats a game as co-op (and, e.g., skips the level
// files' baked physics states that crash Treehouse/Swamp in multiplayer) when its start
// line comes through Mods\FarCryCoop\join_<pid>.txt, as its launcher does. So with that
// ASI the start commands go through the join file instead of boot.lua.
func (s *supervisor) joinMode() bool {
	return s.run.ASI != "" && strings.EqualFold(s.run.Mod, "FarCryCoop")
}

// deliverJoin writes the instance's commands one at a time to its join file; the ASI
// polls it every 500 ms after a game frame, runs the line and deletes the file.
func (s *supervisor) deliverJoin(in *Instance) {
	p := filepath.Join(s.run.GameDir, "Mods", s.run.Mod, fmt.Sprintf("join_%d.txt", in.PID))
	for _, c := range in.Commands {
		if err := os.WriteFile(p, []byte(c), 0o644); err != nil {
			appendEvent(s.run.Dir, in.Name, "warn", "join: "+err.Error())
			return
		}
		deadline := time.Now().Add(3 * time.Minute)
		for {
			if _, err := os.Stat(p); err != nil {
				appendEvent(s.run.Dir, in.Name, "join", c)
				break
			}
			if time.Now().After(deadline) || !s.alive(in.Name) {
				appendEvent(s.run.Dir, in.Name, "warn", "join: not consumed: "+c)
				os.Remove(p)
				return
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
}
