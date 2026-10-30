#!/usr/bin/env bash
# Rebuild FarCryCoopNet.asi and harness.exe (the mod pack is packed by `harness up` itself).
# Usage (repo root): build.sh [asi|harness]   (default: both)
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
what=${1:-all}
rc=0
if [ "$what" = all ] || [ "$what" = asi ]; then
	cmd //c "tools\fcc\build-asi.cmd" || { echo "ASI build failed" >&2; rc=1; }
fi
if [ "$what" = all ] || [ "$what" = harness ]; then
	(cd tools && GOARCH=386 go build -o bin/harness.exe ./harness) && echo "built tools/bin/harness.exe" ||
		{ echo "harness build failed" >&2; rc=1; }
fi
ls -l tools/bin/FarCryCoopNet.asi tools/bin/harness.exe 2>/dev/null
exit $rc
