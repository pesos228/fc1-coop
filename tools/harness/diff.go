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

// clientDiff is the comparison of one client with the server.
type clientDiff struct {
	Client        string
	Server, Count int
	Matched       int
	Mismatches    []mismatch
}

// takeDiff snapshots all instances at (nearly) the same moment and compares each
// client with the server: missing/extra entities, position delta, health.
func takeDiff(r *Run, tol float64) ([]clientDiff, error) {
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
				return nil, fmt.Errorf("[%s] no snapshot in 10s", in.Name)
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
		return nil, err
	}
	var out []clientDiff
	for _, in := range r.Instances {
		if in == server {
			continue
		}
		cl, err := loadSnap(filepath.Join(in.Dir, "snap.txt"))
		if err != nil {
			return nil, err
		}
		cd := clientDiff{Client: in.Name, Server: len(sv), Count: len(cl)}
		for id, s := range sv {
			c, ok := cl[id]
			if !ok {
				cd.Mismatches = append(cd.Mismatches, mismatch{s, "missing on client", math.Inf(1)})
				continue
			}
			cd.Matched++
			d := math.Sqrt((s.X-c.X)*(s.X-c.X) + (s.Y-c.Y)*(s.Y-c.Y) + (s.Z-c.Z)*(s.Z-c.Z))
			if d > tol {
				cd.Mismatches = append(cd.Mismatches, mismatch{s, fmt.Sprintf("pos Δ%.2fm (sv %.1f,%.1f,%.1f cl %.1f,%.1f,%.1f)", d, s.X, s.Y, s.Z, c.X, c.Y, c.Z), d})
			}
			if s.Health != c.Health {
				cd.Mismatches = append(cd.Mismatches, mismatch{s, fmt.Sprintf("health sv=%s cl=%s", s.Health, c.Health), 0})
			}
		}
		for id, c := range cl {
			if _, ok := sv[id]; !ok {
				cd.Mismatches = append(cd.Mismatches, mismatch{c, "extra on client (client-only entity)", -1})
			}
		}
		sort.Slice(cd.Mismatches, func(i, j int) bool { return cd.Mismatches[i].d > cd.Mismatches[j].d })
		out = append(out, cd)
	}
	return out, nil
}

func formatDiff(diffs []clientDiff, n int) string {
	report := &strings.Builder{}
	for _, cd := range diffs {
		counts := map[string]int{}
		for _, m := range cd.Mismatches {
			counts[strings.SplitN(m.what, " ", 2)[0]]++
		}
		fmt.Fprintf(report, "[%s vs server] server=%d client=%d matched=%d  mismatches: %v\n", cd.Client, cd.Server, cd.Count, cd.Matched, counts)
		for i, m := range cd.Mismatches {
			if i >= n {
				fmt.Fprintf(report, "  ... %d more\n", len(cd.Mismatches)-n)
				break
			}
			fmt.Fprintf(report, "  %s %s %q: %s\n", m.ent.ID, m.ent.Class, m.ent.Name, m.what)
		}
	}
	return report.String()
}

func cmdDiff(args []string) error {
	fs := flag.NewFlagSet("diff", flag.ExitOnError)
	tol := fs.Float64("tol", 0.5, "position tolerance, meters")
	n := fs.Int("n", 20, "mismatches to print per client")
	fs.Parse(args)
	r, err := currentRun()
	if err != nil {
		return err
	}
	diffs, err := takeDiff(r, *tol)
	if err != nil {
		return err
	}
	report := formatDiff(diffs, *n)
	out := filepath.Join(r.Dir, "diff-"+time.Now().Format("150405")+".txt")
	os.WriteFile(out, []byte(report), 0o644)
	fmt.Print(report)
	fmt.Println("saved:", out)
	return nil
}
