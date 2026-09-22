#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage:
  ./run_global_search.sh currentHoleNumber startingFrame initialX initialY frames_upperlimit
EOF
	exit 2
}

[[ $# -eq 5 ]] || usage

currentHoleNumber="$1"
startingFrame="$2"
initialX="$3"
initialY="$4"
frames_upperlimit="$5"

is_uint() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

is_uint "$currentHoleNumber" || { echo "currentHoleNumber must be an integer." >&2; exit 2; }
is_uint "$startingFrame" || { echo "startingFrame must be an integer." >&2; exit 2; }
is_uint "$initialX" || { echo "initialX must be an integer." >&2; exit 2; }
is_uint "$initialY" || { echo "initialY must be an integer." >&2; exit 2; }
is_uint "$frames_upperlimit" || { echo "frames_upperlimit must be an integer." >&2; exit 2; }

(( currentHoleNumber >= 1 && currentHoleNumber <= 18 )) || {
	echo "currentHoleNumber must be 1..18." >&2
	exit 2
}
(( startingFrame >= 0 && startingFrame <= 2147483647 )) || {
	echo "startingFrame must be 0..2147483647." >&2
	exit 2
}
(( initialX >= 0 && initialX <= 2560 )) || {
	echo "initialX must be 0..2560 (Display Input coordinates)." >&2
	exit 2
}
(( initialY >= 0 && initialY <= 2048 )) || {
	echo "initialY must be 0..2048 (Display Input coordinates)." >&2
	exit 2
}
(( frames_upperlimit >= 1 && frames_upperlimit <= 2147483647 )) || {
	echo "frames_upperlimit must be 1..2147483647." >&2
	exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHRUN="${MINIGOLF_CHRUN:-$HOME/src/chimera/build/meson-linux/chimera-run}"

repo_project="$SCRIPT_DIR/../project/minigolf.chimeraProject"
if [[ -f "$repo_project" ]]; then
	default_project="$repo_project"
else
	default_project="$HOME/minigolf-headless/minigolf.chimeraProject"
fi
PROJECT="${MINIGOLF_PROJECT:-$default_project}"

HYBPKG="${MINIGOLF_CORE:-$HOME/minigolf-headless/core/dosbox-x-hybrid-search.chimeraCore}"

STATE_DIR="${MINIGOLF_STATE_DIR:-$HOME/minigolf-state-extract}"
OUT_ROOT="${MINIGOLF_OUT_ROOT:-$HOME}"

STATE="$STATE_DIR/minigolf-hole${currentHoleNumber}.state"
OUT="$OUT_ROOT/minigolf-hole${currentHoleNumber}-exhaustive"
SHARED="$OUT/shared-best.bin"
RUN_CONFIG="$OUT/run-config.json"
RUN_FINISHED="$OUT/run-finished.json"

START_HOLE=$((currentHoleNumber - 1))
NEXT_HOLE="$currentHoleNumber"

HOLE_ADDRESS=0x023DB7B8
START_AXIS_X=1280
START_AXIS_Y=1024
PROGRESS_INTERVAL=250

[[ -x "$CHRUN" ]] || {
	echo "chimera-run not found/executable: $CHRUN" >&2
	echo "Override with MINIGOLF_CHRUN=/path/to/chimera-run if needed." >&2
	exit 1
}
[[ -f "$PROJECT" ]] || {
	echo "Chimera project not found: $PROJECT" >&2
	echo "Override with MINIGOLF_PROJECT=/path/to/minigolf.chimeraProject if needed." >&2
	exit 1
}
[[ -f "$HYBPKG" ]] || {
	echo "Hybrid DOSBox-X package not found: $HYBPKG" >&2
	echo "Override with MINIGOLF_CORE=/path/to/dosbox-x.chimeraCore if needed." >&2
	exit 1
}

mkdir -p "$STATE_DIR"

old_pids="$(pgrep -f -- "$CHRUN" || true)"
if [[ -n "$old_pids" ]]; then
	echo "Stopping previous chimera-run process(es): $old_pids"
	kill $old_pids 2>/dev/null || true
	sleep 1

	old_pids="$(pgrep -f -- "$CHRUN" || true)"
	if [[ -n "$old_pids" ]]; then
		echo "Force-stopping remaining process(es): $old_pids"
		kill -KILL $old_pids 2>/dev/null || true
		sleep 1
	fi
fi

tmpdir="$(mktemp -d -t minigolf-global-state.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

state_frame="$startingFrame"

echo
echo "=== Preparing Course $currentHoleNumber exhaustive search ==="
echo "Starting frame : $startingFrame"
echo "Cursor         : $initialX,$initialY"
echo "Upper limit    : $frames_upperlimit frames"
echo "Hole byte      : $START_HOLE -> $NEXT_HOLE"
echo

echo "Creating state at frame $state_frame: $STATE"
rm -f "$STATE"

"$CHRUN" \
	--project "$PROJECT" \
	"$HYBPKG" \
	--allow-core-mismatch \
	--files "$HOME" \
	--frames "$state_frame" \
	--final-state "$STATE"

[[ -s "$STATE" ]] || {
	echo "State was not created: $STATE" >&2
	exit 1
}

verify_ram="$tmpdir/verify.ram"
"$CHRUN" \
	--project "$PROJECT" \
	"$HYBPKG" \
	--allow-core-mismatch \
	--files "$HOME" \
	--state "$STATE" \
	--frames 0 \
	--dump "Physical RAM=$verify_ram" \
	>/dev/null 2>&1

state_hole="$(
	python3 - "$verify_ram" "$HOLE_ADDRESS" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
address = int(sys.argv[2], 0)
if address >= len(data):
	raise SystemExit("Physical RAM dump is too small")
print(data[address])
PY
)"

if (( state_hole != START_HOLE )); then
	echo "State verification failed: expected hole byte $START_HOLE, got $state_hole." >&2
	echo "The supplied startingFrame ($startingFrame) may not be on Course $currentHoleNumber." >&2
	exit 1
fi

echo "State verified: frame $state_frame, hole byte $state_hole."

CPUS=()
if command -v lscpu >/dev/null 2>&1; then
	mapfile -t CPUS < <(
		lscpu -p=CPU,CORE,SOCKET |
		awk -F, '
			!/^#/ {
				key=$3 ":" $2
				if (!seen[key]++) print $1
			}
		'
	)
fi

if (( ${#CPUS[@]} == 0 )); then
	mapfile -t CPUS < <(seq 0 $(( $(nproc) - 1 )))
fi

WORKERS="${#CPUS[@]}"

rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$SHARED" "$frames_upperlimit" <<'PY'
import struct
import sys

path = sys.argv[1]
ceiling = int(sys.argv[2])
with open(path, "wb") as f:
	f.write(struct.pack("<i", ceiling))
PY

python3 - \
	"$RUN_CONFIG" \
	"$currentHoleNumber" "$startingFrame" "$initialX" "$initialY" "$frames_upperlimit" \
	"$state_frame" "$START_HOLE" "$NEXT_HOLE" "$WORKERS" \
	"$STATE" "$PROJECT" "$HYBPKG" "$CHRUN" <<'PY'
import json
import sys
from pathlib import Path

(
	out,
	hole, starting_frame, x, y, limit,
	state_frame, start_hole, next_hole, workers,
	state, project, core, chimera_run,
) = sys.argv[1:]

payload = {
	"currentHoleNumber": int(hole),
	"startingFrame": int(starting_frame),
	"initialX": int(x),
	"initialY": int(y),
	"frames_upperlimit": int(limit),
	"stateFrame": int(state_frame),
	"startHoleByte": int(start_hole),
	"nextHoleByte": int(next_hole),
	"workers": int(workers),
	"state": state,
	"project": project,
	"core": core,
	"chimeraRun": chimera_run,
}
Path(out).write_text(json.dumps(payload, indent=2) + "\n")
PY

echo
echo "=== Launching Course $currentHoleNumber exhaustive optimization ==="
echo "State       : frame $state_frame"
echo "Cursor      : $initialX,$initialY"
echo "Carrier     : $START_AXIS_X,$START_AXIS_Y"
echo "Hole byte   : $START_HOLE -> $NEXT_HOLE"
echo "Upper limit : $frames_upperlimit frames"
echo "Workers     : $WORKERS"
echo "CPUs        : ${CPUS[*]}"
echo "Output      : $OUT"
echo
echo "Monitor in another terminal with:"
echo "  python3 monitor_global_search.py $currentHoleNumber $initialX $initialY $frames_upperlimit"
echo

START="$(date +%s)"
pids=()

for ((w = 0; w < WORKERS; w++)); do
	cpu="${CPUS[$w]}"
	echo "worker $w -> CPU $cpu"

	/usr/bin/time \
		-o "$OUT/worker-$w.time" \
		-f 'REAL=%e USER=%U SYS=%S' \
		taskset -c "$cpu" \
		env \
		MINIGOLF_SCAN=1 \
		MINIGOLF_SCAN_WORKER="$w" \
		MINIGOLF_SCAN_WORKERS="$WORKERS" \
		MINIGOLF_SCAN_MAX_FRAMES="$frames_upperlimit" \
		MINIGOLF_SCAN_PROGRESS="$PROGRESS_INTERVAL" \
		MINIGOLF_SCAN_CURSOR_X="$initialX" \
		MINIGOLF_SCAN_CURSOR_Y="$initialY" \
		MINIGOLF_SCAN_START_AXIS_X="$START_AXIS_X" \
		MINIGOLF_SCAN_START_AXIS_Y="$START_AXIS_Y" \
		MINIGOLF_SCAN_START_HOLE="$START_HOLE" \
		MINIGOLF_SCAN_NEXT_HOLE="$NEXT_HOLE" \
		MINIGOLF_SCAN_ORDER=bottom-up \
		MINIGOLF_SCAN_SHARED_BEST_FILE="$SHARED" \
		MINIGOLF_SWITCH_DYNAMIC=1 \
		"$CHRUN" \
		--project "$PROJECT" \
		"$HYBPKG" \
		--allow-core-mismatch \
		--files "$HOME" \
		--state "$STATE" \
		--frames 0 \
		>"$OUT/worker-$w.log" 2>&1 &

	pids+=("$!")
done

rc=0
for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		rc=1
	fi
done

END="$(date +%s)"

python3 - "$RUN_FINISHED" "$rc" "$((END - START))" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(
	json.dumps(
		{
			"exitStatus": int(sys.argv[2]),
			"wallSeconds": int(sys.argv[3]),
		},
		indent=2,
	) + "\n"
)
PY

echo
echo "All workers finished."
echo "exit status  : $rc"
echo "wall seconds : $((END - START))"

echo
echo "Final shared incumbent:"
python3 - "$SHARED" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as f:
	raw = f.read(4)
if len(raw) != 4:
	raise SystemExit("shared-best.bin is incomplete")
print(struct.unpack("<i", raw)[0])
PY

echo
echo "Worker results:"
shopt -s nullglob
worker_logs=("$OUT"/worker-*.log)
if (( ${#worker_logs[@]} )); then
	for f in "${worker_logs[@]}"; do
		perl -pe 's/\\n/\n/g' "$f"
	done |
		grep '^SCAN_RESULT ' |
		sort -V || true
else
	echo "(no worker logs)"
fi

exit "$rc"
