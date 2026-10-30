#!/usr/bin/env bash
# Run harness scenarios one after another and summarize.
# Usage (repo root, Steam running):
#   run-suite.sh                  every tests/*.txt (except smoke-map) + smoke training and dam
#   run-suite.sh pickups heli-rotor        just these (names without .txt; smoke-<map> for smoke)
#   run-suite.sh -n 10 steam-boat-crew      each named scenario 10 times: "k of N failed"
# Output: .harness/suite/summary.txt (one line per scenario), .harness/suite/<name>[-<i>].out.
# Scenarios with "OPEN" in a header comment are known open failures: marked "open", not a regression.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
H=tools/bin/harness.exe
OUT=.harness/suite
mkdir -p "$OUT"
N=1
if [ "${1:-}" = "-n" ]; then N=$2; shift 2; fi

names=("$@")
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
echo "suite $(date '+%F %H:%M'), $(git rev-parse --short HEAD)$(git diff --quiet || echo ' +uncommitted')" >> "$S"
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
