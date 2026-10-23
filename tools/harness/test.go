package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// A scenario is a text file, one step per line ('#' starts a comment):
//
//	up <harness up flags>
//	sleep <duration>
//	wait <inst> <cond> [timeout]            state condition, as in `harness wait`
//	lua <inst> <code>                       must run without a Lua error
//	expect <inst> <code> => <value>         `return <code>` must give <value>
//	expect-log <inst> <regex> [timeout]     the instance log must contain a match
//	expect-diff max=<m> [class=<re>] [exclude=<re>] [missing=0]
//	                                        clients vs server: no matching entity off by more
//	                                        than m meters or with another health
//	expect-no-events                        no crash, error dialog or stalled agent so far
//	down
//
// ${VAR} is replaced from the environment (e.g. MAP=pier harness test tests/smoke-map.txt).
//
// Failed expectations are collected; a failed up/wait/lua stops the scenario.
// The run is always shut down at the end unless -keep is given.

type testResult struct {
	line   int
	step   string
	ok     bool
	detail string
}

func cmdTest(args []string) error {
	fs := flag.NewFlagSet("test", flag.ExitOnError)
	keep := fs.Bool("keep", false, "leave the games running at the end")
	pos, err := splitFlags(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return fmt.Errorf("usage: test <scenario file> [-keep]")
	}
	lines := readLines(pos[0])
	if lines == nil {
		return fmt.Errorf("cannot read %s", pos[0])
	}
	var results []testResult
	started, downed := false, false
	fatal := false
	for i, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = os.Expand(line, func(k string) string { return os.Getenv(k) }) // ${MAP} etc.
		verb, rest, _ := strings.Cut(line, " ")
		rest = strings.TrimSpace(rest)
		fmt.Printf("--- %d: %s\n", i+1, line)
		var stepErr error
		hard := true // a failure stops the scenario
		switch verb {
		case "up":
			stepErr = cmdUp(strings.Fields(rest))
			started = stepErr == nil
		case "down":
			stepErr = cmdDown()
			downed = true
		case "sleep":
			d, err := time.ParseDuration(rest)
			if err != nil {
				stepErr = err
				break
			}
			time.Sleep(d)
		case "wait":
			stepErr = cmdWait(strings.Fields(rest))
		case "lua":
			inst, code, _ := strings.Cut(rest, " ")
			stepErr = runLua(inst, code, nil)
		case "expect":
			hard = false
			inst, body, _ := strings.Cut(rest, " ")
			code, want, ok := strings.Cut(body, " => ")
			if !ok {
				stepErr = fmt.Errorf("expect needs '<code> => <value>'")
				break
			}
			var got string
			stepErr = runLua(inst, "return "+code, &got)
			if stepErr == nil && got != strings.TrimSpace(want) {
				stepErr = fmt.Errorf("got %q, want %q", got, strings.TrimSpace(want))
			}
		case "expect-log":
			hard = false
			stepErr = expectLog(strings.Fields(rest))
		case "expect-diff":
			hard = false
			stepErr = expectDiff(strings.Fields(rest))
		case "expect-no-events":
			hard = false
			stepErr = expectNoEvents()
		default:
			stepErr = fmt.Errorf("unknown step %q", verb)
		}
		res := testResult{line: i + 1, step: line, ok: stepErr == nil}
		if stepErr != nil {
			res.detail = stepErr.Error()
			fmt.Printf("FAIL %d: %s\n", i+1, res.detail)
		} else {
			fmt.Printf("PASS %d\n", i+1)
		}
		results = append(results, res)
		if stepErr != nil && hard {
			fatal = true
			break
		}
	}
	if started && !downed && !*keep {
		cmdDown()
	}

	report := &strings.Builder{}
	failed := 0
	for _, r := range results {
		mark := "PASS"
		if !r.ok {
			mark = "FAIL"
			failed++
		}
		fmt.Fprintf(report, "%s  %3d  %s", mark, r.line, r.step)
		if r.detail != "" {
			fmt.Fprintf(report, "\n            %s", strings.ReplaceAll(r.detail, "\n", "\n            "))
		}
		report.WriteString("\n")
	}
	verdict := fmt.Sprintf("%s: %d steps, %d failed", filepath.Base(pos[0]), len(results), failed)
	if fatal {
		verdict += " (stopped at the first hard failure)"
	}
	fmt.Fprintln(report, verdict)
	fmt.Print("\n", report.String())
	if r, err := currentRun(); err == nil {
		os.WriteFile(filepath.Join(r.Dir, "test-"+strings.TrimSuffix(filepath.Base(pos[0]), filepath.Ext(pos[0]))+".txt"), []byte(report.String()), 0o644)
	}
	if failed > 0 {
		return fmt.Errorf("%d step(s) failed", failed)
	}
	return nil
}

// runLua runs Lua in an instance; with out != nil it returns the agent's result string.
func runLua(inst, code string, out *string) error {
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(inst)
	if err != nil {
		return err
	}
	status, info, err := execWait(in, "lua "+code, 15*time.Second)
	if err != nil {
		return err
	}
	if status != "ok" {
		return fmt.Errorf("lua error (see harness log %s)", inst)
	}
	if out != nil {
		*out = info
	}
	return nil
}

func expectLog(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: expect-log <inst> <regex> [timeout]")
	}
	timeout := 10 * time.Second
	if len(args) > 2 {
		d, err := time.ParseDuration(args[2])
		if err != nil {
			return err
		}
		timeout = d
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	in, err := r.Inst(args[0])
	if err != nil {
		return err
	}
	re, err := regexp.Compile(args[1])
	if err != nil {
		return err
	}
	deadline := time.Now().Add(timeout)
	for {
		for _, l := range readLines(filepath.Join(in.Dir, "game.log")) {
			if re.MatchString(l) {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("no log line matches %q", args[1])
		}
		time.Sleep(250 * time.Millisecond)
	}
}

// expectNoEvents fails if the supervisor saw a crash, an error dialog or a stalled agent.
func expectNoEvents() error {
	r, err := currentRun()
	if err != nil {
		return err
	}
	var bad []string
	for _, l := range readLines(filepath.Join(r.Dir, "events.log")) {
		f := strings.Split(l, "\t")
		if len(f) >= 3 && (f[2] == "crash" || f[2] == "dialog" || f[2] == "stall" || f[2] == "errorlog") {
			bad = append(bad, l)
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("%s", strings.Join(bad, "\n"))
	}
	return nil
}

func expectDiff(args []string) error {
	maxD := 0.5
	classRe := regexp.MustCompile(".")
	var excludeRe *regexp.Regexp
	allowMissing := true
	for _, a := range args {
		k, v, _ := strings.Cut(a, "=")
		var err error
		switch k {
		case "max":
			maxD, err = strconv.ParseFloat(v, 64)
		case "class":
			classRe, err = regexp.Compile(v)
		case "exclude":
			excludeRe, err = regexp.Compile(v)
		case "missing":
			allowMissing = v != "0"
		default:
			err = fmt.Errorf("unknown expect-diff option %q", k)
		}
		if err != nil {
			return err
		}
	}
	r, err := currentRun()
	if err != nil {
		return err
	}
	diffs, err := takeDiff(r, maxD)
	if err != nil {
		return err
	}
	var bad []string
	for _, cd := range diffs {
		for _, m := range cd.Mismatches {
			if !classRe.MatchString(m.ent.Class) || (excludeRe != nil && excludeRe.MatchString(m.ent.Class+" "+m.ent.Name)) {
				continue
			}
			missing := strings.HasPrefix(m.what, "missing") || strings.HasPrefix(m.what, "extra")
			if missing && allowMissing {
				continue
			}
			bad = append(bad, fmt.Sprintf("%s: %s %s %q: %s", cd.Client, m.ent.ID, m.ent.Class, m.ent.Name, m.what))
		}
	}
	if len(bad) > 0 {
		if len(bad) > 12 {
			bad = append(bad[:12], fmt.Sprintf("... %d more", len(bad)-12))
		}
		return fmt.Errorf("%s", strings.Join(bad, "\n"))
	}
	return nil
}
