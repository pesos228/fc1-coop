package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const defaultGameDir = `D:\SteamLibrary\steamapps\common\FarCry`

// Instance is one game process (server or client).
type Instance struct {
	Name     string   `json:"name"`
	Role     string   `json:"role"` // server | client
	Dir      string   `json:"dir"`
	PID      int      `json:"pid"`
	Commands []string `json:"commands"` // console commands passed on the command line
}

// Run describes one harness session; stored as <run>/run.json.
type Run struct {
	Dir       string      `json:"dir"`
	GameDir   string      `json:"game_dir"`
	Agent     string      `json:"agent"`
	Mode      string      `json:"mode"` // sp | host
	Map       string      `json:"map"`
	Mod       string      `json:"mod"`
	Width     int         `json:"width"`
	Height    int         `json:"height"`
	Instances []*Instance `json:"instances"`
	Started   time.Time   `json:"started"`
}

func (r *Run) Save() error {
	b, _ := json.MarshalIndent(r, "", "  ")
	tmp := filepath.Join(r.Dir, "run.json.tmp")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(r.Dir, "run.json"))
}

func (r *Run) Inst(name string) (*Instance, error) {
	for _, in := range r.Instances {
		if strings.EqualFold(in.Name, name) {
			return in, nil
		}
	}
	return nil, fmt.Errorf("no instance %q in run (have: %s)", name, r.names())
}

func (r *Run) names() string {
	var n []string
	for _, in := range r.Instances {
		n = append(n, in.Name)
	}
	return strings.Join(n, ", ")
}

func loadRun(dir string) (*Run, error) {
	b, err := os.ReadFile(filepath.Join(dir, "run.json"))
	if err != nil {
		return nil, err
	}
	var r Run
	return &r, json.Unmarshal(b, &r)
}

// repoRoot walks up from the working directory to the repository root.
func repoRoot() (string, error) {
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "scripts", "harness", "agent.lua")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("repo root not found (run inside D:\\fc1-coop)")
		}
		dir = parent
	}
}

func harnessHome() (string, error) {
	root, err := repoRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, ".harness"), nil
}

func currentRun() (*Run, error) {
	home, err := harnessHome()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(home, "current"))
	if err != nil {
		return nil, errors.New("no current run, use `harness up`")
	}
	return loadRun(strings.TrimSpace(string(b)))
}

// slash converts a Windows path to forward slashes for Lua strings and game args.
func slash(p string) string { return filepath.ToSlash(p) }

// State is the agent's last state.txt as key/value pairs.
type State map[string]string

func readState(in *Instance) (State, time.Time, error) {
	p := filepath.Join(in.Dir, "state.txt")
	st, err := os.Stat(p)
	if err != nil {
		return nil, time.Time{}, err
	}
	f, err := os.Open(p)
	if err != nil {
		return nil, time.Time{}, err
	}
	defer f.Close()
	s := State{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), "="); ok {
			s[k] = v
		}
	}
	return s, st.ModTime(), nil
}

// levelLoaded: the agent ticks and reports a level.
func (s State) levelLoaded() bool {
	l := s["level"]
	return l != "" && l != "nil"
}

// Events are appended to <run>/events.log by the supervisor.
func appendEvent(runDir, inst, kind, msg string) {
	f, err := os.OpenFile(filepath.Join(runDir, "events.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	msg = strings.ReplaceAll(strings.TrimSpace(msg), "\n", " | ")
	fmt.Fprintf(f, "%s\t%s\t%s\t%s\n", time.Now().Format("15:04:05.000"), inst, kind, msg)
}
