#!/usr/bin/env bash
# Run harness scenarios one after another and summarize.
# Usage (repo root, Steam running):
#   run-suite.sh                  every tests/*.txt (except smoke-map) + smoke training and dam
#   run-suite.sh pickups heli-rotor        just these (names without .txt; smoke-<map> for smoke)
#   run-suite.sh -n 10 steam-boat-crew      each named scenario 10 times: "k of N failed"
#   run-suite.sh -a items,vehicles          the scenarios of these areas + "always" (scripts/areas.txt)
# Output: .harness/suite/summary.txt (one line per scenario), .harness/suite/<name>[-<i>].out.
# Scenarios with "OPEN" in a header comment are known open failures: marked "open", not a regression.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
H=tools/bin/harness.exe
OUT=.harness/suite
mkdir -p "$OUT"
AREAS="$(dirname "$0")/areas.txt"
N=1
A=""
while [ $# -gt 0 ]; do
	case "$1" in
		-n) N=$2; shift 2 ;;
		-a) A=$2; shift 2 ;;
		*) break ;;
	esac
done

# area -> scenarios; area names a.k.a. the text before ":" in areas.txt
area() { sed -n "s/^$1:[[:space:]]*//p" "$AREAS" | tr -d '\r'; }

# a scenario in no area is skipped by every -a run: say so on each run
unlisted=""
for t in tests/*.txt; do
	n=$(basename "$t" .txt)
	[ "$n" = smoke-map ] && continue
	grep -v '^#' "$AREAS" | tr -d '\r' | grep -qE "[: ]$n( |\$)" || unlisted="$unlisted $n"
done
[ -n "$unlisted" ] && echo "warning: not in any area of $AREAS:$unlisted" >&2

names=("$@")
if [ -n "$A" ]; then
	for a in always ${A//,/ }; do
		list=$(area "$a")
		[ -n "$list" ] || { echo "no such area: $a (see $AREAS)" >&2; exit 1; }
		for n in $list; do
			case " ${names[*]} " in *" $n "*) ;; *) names+=("$n") ;; esac
		done
	done
fi
if [ ${#names[@]} -eq 0 ]; then
	for t in tests/*.txt; do
		n=$(basename "$t" .txt)
		[ "$n" = smoke-map ] || names+=("$n")
	done
	names+=(smoke-training smoke-dam)
fi

query session 2>/dev/null | grep -q '^>console .*Active' ||
	echo "warning: this session is not on the console; with RDP minimized the second instance crashes (D3D9)" >&2

S="$OUT/summary.txt"
: > "$S"
echo "suite $(date '+%F %H:%M'), $(git rev-parse --short HEAD)$(git diff --quiet || echo ' +uncommitted')${A:+, areas $A}" >> "$S"
[ -n "$unlisted" ] && echo "warning: not in any area:$unlisted" >> "$S"
for n in "${names[@]}"; do
	case "$n" in
		smoke-*) file=tests/smoke-map.txt; export MAP=${n#smoke-} ;;
		*) file=tests/$n.txt; unset MAP ;;
	esac
	[ -f "$file" ] || { echo "$n: no such scenario" >> "$S"; continue; }
	open=""
	sed -n '1,/^up /p' "$file" | grep -q '^#.*OPEN' && open=" [open]"
	fails=0
	for i in $(seq 1 "$N"); do
		o="$OUT/$n.out"
		[ "$N" -gt 1 ] && o="$OUT/$n-$i.out"
		$H down > /dev/null 2>&1
		$H test "$file" > "$o" 2>&1
		r=$(grep -E "steps, [0-9]+ failed" "$o" | tail -1)
		[ -n "$r" ] || r="no result (aborted?)"
		run=$(sed -n 's/^run: .*[\\/]runs[\\/]\(.*\)$/\1/p' "$o" | head -1)
		echo "$r" | grep -q ", 0 failed" || fails=$((fails + 1))
		if [ "$N" -eq 1 ]; then
			echo "$n: ${r#*: }$open  (runs/$run)" >> "$S"
		else
			echo "  $n #$i: ${r#*: }  (runs/$run)" >> "$S"
		fi
	done
	[ "$N" -gt 1 ] && echo "$n: $fails of $N failed$open" >> "$S"
done
$H down > /dev/null 2>&1
echo DONE >> "$S"
cat "$S"
