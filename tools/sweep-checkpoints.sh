#!/usr/bin/env bash
# Checkpoint sweep: for every map, a listen host and one client jump through all campaign
# checkpoints (CoopGoto, the GameEvent save points) and the harness diffs server and client on
# each. One line per checkpoint into .harness/sweep/<map>.txt; a summary in .harness/sweep/all.txt.
# Usage (repo root, Steam running): tools/sweep-checkpoints.sh [map ...]   (default: all 20)
set -u
H=tools/bin/harness.exe
OUT=.harness/sweep
mkdir -p "$OUT"
# checkpoints autosave (save_auto.lua in the mod folder of the install): keep the player's own
GAME=$(sed -n 's/.*"game_dir": *"\(.*\)".*/\1/p' .harness/runs/*/run.json 2>/dev/null | tail -1 | sed 's/\\/\//g')
AUTO="$GAME/Mods/FarCryCoop/save_auto.lua"
[ -d "$GAME/Mods/FarCryCoop" ] || { echo "no game folder from .harness/runs/*/run.json (run harness up once)" >&2; exit 1; }
[ -f "$AUTO" ] && cp "$AUTO" "$OUT/save_auto.lua.bak"
maps=("$@")
[ ${#maps[@]} -eq 0 ] && maps=(training carrier fort pier research treehouse bunker steam regulator control rebellion archive cooler boat catacombs river swamp factory dam volcano)
for m in "${maps[@]}"; do
	f="$OUT/$m.txt"
	: > "$f"
	$H down > /dev/null 2>&1
	if ! $H up -mode host -map "$m" -clients 1 -mod FarCryCoop -asi tools/bin/FarCryCoopNet.asi \
		-start "#COOP_ExpectPlayers=2;#CoopMap(\"$m\")" > /dev/null 2>&1 ||
		! $H wait client1 "players>=2" -t 150s > /dev/null 2>&1; then
		echo "$m: did not start" | tee -a "$f" >> "$OUT/all.txt"
		continue
	fi
	sleep 5
	$H lua server "COOP_God=1 CoopGoto()" > /dev/null 2>&1
	sleep 1
	ids=$($H log server -grep "^checkpoint [0-9]+ at" -n 100 2>/dev/null | sed -E 's/^checkpoint ([0-9]+) at.*/\1/' | sort -n -u)
	n=0 bad=0
	for id in $ids; do
		$H lua server "CoopGoto($id)" > /dev/null 2>&1
		sleep 12
		d=$($H diff -n 200 2>&1)
		# the players and anything off by more than 5 m
		pl=$(echo "$d" | grep -E ' Player ' | sed -E 's/.*pos Δ([0-9.]+)m.*/\1/' | head -1)
		big=$(echo "$d" | grep -o 'pos Δ[0-9.]*' | sed 's/pos Δ//' | awk '$1 > 5' | wc -l)
		hp=$(echo "$d" | grep -c 'health')
		cnt=$(echo "$d" | head -1 | sed -E 's/.*server=([0-9]+) client=([0-9]+).*/\1\/\2/')
		alive=$($H lua server 'local s="" for i,P in CoopPlayers() do s=s..P.cnt.health.." " end return s' 2>/dev/null | sed 's/^ok //')
		top=$(echo "$d" | grep 'pos Δ' | head -3 | sed -E 's/^ *[0-9]+ ([A-Za-z_0-9]+) "([^"]*)": pos Δ([0-9.]+)m.*/\1:\2:\3/' | tr '\n' ' ')
		line="$m cp$id players_off=${pl:-0} over5m=$big health_diff=$hp entities=$cnt hp=[$alive] top=[$top]"
		echo "$line" >> "$f"
		n=$((n + 1))
		if [ -n "${pl:-}" ] && awk "BEGIN{exit !($pl > 3)}"; then bad=$((bad + 1)); fi
	done
	ev=$($H events -n 200 2>/dev/null | grep -c -E 'crash|dialog|stall')
	$H down > /dev/null 2>&1
	echo "$m: $n checkpoints, players >3 m apart on $bad, events $ev" >> "$OUT/all.txt"
done
if [ -f "$OUT/save_auto.lua.bak" ]; then cp "$OUT/save_auto.lua.bak" "$AUTO"; else rm -f "$AUTO"; fi
echo DONE >> "$OUT/all.txt"
