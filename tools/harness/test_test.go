package main

import (
	"regexp"
	"testing"
)

func TestDiffFailures(t *testing.T) {
	mm := func(class, name, what string) mismatch {
		return mismatch{ent: snapEnt{ID: "1", Class: class, Name: name}, what: what}
	}
	diffs := []clientDiff{{Client: "client1", Mismatches: []mismatch{
		mm("MercCover", "REINF_ONE2", "pos Δ4.61m"),
		mm("MercCover", "Merc_Cover.MercCover_M4_4", "pos Δ3.28m"),
		mm("Boat", "AB01_attackboat2", "pos Δ2.50m"),
		mm("Player", "Alex", "missing on client"),
	}}}
	all := regexp.MustCompile(".")
	cases := []struct {
		name         string
		class        *regexp.Regexp
		exclude      string
		allowMissing bool
		want         int
	}{
		{"everything", all, "", false, 4},
		{"missing allowed", all, "", true, 3},
		{"anchored name", all, "^REINF_ONE2$", true, 2},
		{"name substring", all, "REINF_|MercCover_M4_[456]$", true, 1},
		{"class and name", all, "^Boat AB01_", true, 2},
		{"anchored class only skips nothing by name", all, "^MercCover$", true, 3},
		{"class filter", regexp.MustCompile("^Boat$"), "", false, 1},
		{"class filter and exclude", regexp.MustCompile("^Boat$"), "AB01_attackboat2", false, 0},
	}
	for _, c := range cases {
		var ex *regexp.Regexp
		if c.exclude != "" {
			ex = regexp.MustCompile(c.exclude)
		}
		got := diffFailures(diffs, c.class, ex, c.allowMissing)
		if len(got) != c.want {
			t.Errorf("%s: %d failures, want %d: %q", c.name, len(got), c.want, got)
		}
	}
}
