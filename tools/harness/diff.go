package main

import (
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type snapEnt struct {
	ID, Class, Name string
	X, Y, Z         float64
	Health          string
}

func loadSnap(p string) (map[string]snapEnt, error) {
	lines := readLines(p)
	if lines == nil {
		return nil, fmt.Errorf("no snapshot %s", p)
	}
	out := map[string]snapEnt{}
	for _, l := range lines {
		f := strings.Split(l, "\t")
		if len(f) < 7 {
			continue
		}
		e := snapEnt{ID: f[0], Class: f[1], Name: f[2], Health: f[6]}
		e.X, _ = strconv.ParseFloat(f[3], 64)
		e.Y, _ = strconv.ParseFloat(f[4], 64)
		e.Z, _ = strconv.ParseFloat(f[5], 64)
		out[e.ID] = e
	}
	return out, nil
}

type mismatch struct {
	ent  snapEnt
	what string
	d    float64
}

// cmdDiff snapshots all instances at (nearly) the same moment and compares each
// client with the server: missing/extra entities, position delta, health.
func cmdDiff(args []string) error {
	fs := flag.NewFlagSet("diff", flag.ExitOnError)
	tol := fs.Float64("tol", 0.5, "position tolerance, meters")
	n := fs.Int("n", 20, "mismatches to print per client")
	fs.Parse(args)
	r, err := currentRun()
	if err != nil {
		return err
	}
	// Send to all first so snapshots are taken within one agent tick of each other.
	for _, in := range r.Instances {
		os.Remove(filepath.Join(in.Dir, "snap.txt"))
		sendCommand(in, "lua return Harness:Snapshot()")
	}
	deadline := time.Now().Add(10 * time.Second)
	for _, in := range r.Instances {
		for {
			if _, err := os.Stat(filepath.Join(in.Dir, "snap.txt")); err == nil {
				break
			}
			if time.Now().After(deadline) {
				return fmt.Errorf("[%s] no snapshot in 10s", in.Name)
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	time.Sleep(200 * time.Millisecond) // let the agent close the file

	var server *Instance
	for _, in := range r.Instances {
		if in.Role == "server" {
			server = in
		}
	}
	sv, err := loadSnap(filepath.Join(server.Dir, "snap.txt"))
	if err != nil {
		return err
	}
	report := &strings.Builder{}
	for _, in := range r.Instances {
		if in == server {
			continue
		}
		cl, err := loadSnap(filepath.Join(in.Dir, "snap.txt"))
		if err != nil {
			return err
		}
		var ms []mismatch
		matched := 0
		for id, s := range sv {
			c, ok := cl[id]
			if !ok {
				ms = append(ms, mismatch{s, "missing on client", math.Inf(1)})
				continue
			}
			matched++
			d := math.Sqrt((s.X-c.X)*(s.X-c.X) + (s.Y-c.Y)*(s.Y-c.Y) + (s.Z-c.Z)*(s.Z-c.Z))
			if d > *tol {
				ms = append(ms, mismatch{s, fmt.Sprintf("pos Δ%.2fm (sv %.1f,%.1f,%.1f cl %.1f,%.1f,%.1f)", d, s.X, s.Y, s.Z, c.X, c.Y, c.Z), d})
			}
			if s.Health != c.Health {
				ms = append(ms, mismatch{s, fmt.Sprintf("health sv=%s cl=%s", s.Health, c.Health), 0})
			}
		}
		for id, c := range cl {
			if _, ok := sv[id]; !ok {
				ms = append(ms, mismatch{c, "extra on client (client-only entity)", -1})
			}
		}
		sort.Slice(ms, func(i, j int) bool { return ms[i].d > ms[j].d })
		counts := map[string]int{}
		for _, m := range ms {
			counts[strings.SplitN(m.what, " ", 2)[0]]++
		}
		fmt.Fprintf(report, "[%s vs server] server=%d client=%d matched=%d  mismatches: %v\n", in.Name, len(sv), len(cl), matched, counts)
		for i, m := range ms {
			if i >= *n {
				fmt.Fprintf(report, "  ... %d more\n", len(ms)-*n)
				break
			}
			fmt.Fprintf(report, "  %s %s %q: %s\n", m.ent.ID, m.ent.Class, m.ent.Name, m.what)
		}
	}
	out := filepath.Join(r.Dir, "diff-"+time.Now().Format("150405")+".txt")
	os.WriteFile(out, []byte(report.String()), 0o644)
	fmt.Print(report.String())
	fmt.Println("saved:", out)
	return nil
}
