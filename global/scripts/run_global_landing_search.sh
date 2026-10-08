#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage:
  ./run_global_landing_search.sh currentHoleNumber startingFrame initialX initialY frames_upperlimit targetX targetY

Coordinates:
  initialX/initialY : Display Input coordinates (X 0..2560, Y 0..2048)
  targetX/targetY   : ball-position RAM coordinates used only to rank landing states
EOF
	exit 2
}

[[ $# -eq 7 ]] || usage

currentHoleNumber="$1"
startingFrame="$2"
initialX="$3"
initialY="$4"
frames_upperlimit="$5"
targetX="$6"
targetY="$7"

is_uint() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

for name in currentHoleNumber startingFrame initialX initialY frames_upperlimit targetX targetY; do
	value="${!name}"
	is_uint "$value" || { echo "$name must be a non-negative integer." >&2; exit 2; }
done

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
(( frames_upperlimit >= 1 && frames_upperlimit <= 10000 )) || {
	echo "frames_upperlimit must be 1..10000." >&2
	exit 2
}
(( targetX >= 0 && targetX <= 65535 )) || {
	echo "targetX must be 0..65535 (ball-position RAM coordinate)." >&2
	exit 2
}
(( targetY >= 0 && targetY <= 65535 )) || {
	echo "targetY must be 0..65535 (ball-position RAM coordinate)." >&2
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
TOP_TSV="$OUT/top-10.tsv"

START_HOLE=$((currentHoleNumber - 1))
if (( currentHoleNumber == 18 )); then
	NEXT_HOLE=0
else
	NEXT_HOLE="$currentHoleNumber"
fi

HOLE_ADDRESS=0x023B9A18
BALL_PLAYABLE_ADDRESS=0x0069DF4C
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
command -v setsid >/dev/null 2>&1 || {
	echo "setsid is required but was not found." >&2
	exit 1
}

mkdir -p "$STATE_DIR"
tmpdir="$(mktemp -d -t minigolf-global-state.XXXXXX)"
active_pgids=()

remove_active_pgid() {
	local target="$1"
	local remaining=()
	local pgid

	for pgid in "${active_pgids[@]}"; do
		if [[ "$pgid" != "$target" ]]; then
			remaining+=("$pgid")
		fi
	done
	active_pgids=("${remaining[@]}")
}

cleanup() {
	local rc=$?
	trap - EXIT INT TERM
	set +e

	if (( ${#active_pgids[@]} > 0 )); then
		echo
		echo "Stopping active chimera-run process group(s)..."
		for pgid in "${active_pgids[@]}"; do
			if kill -0 -- "-$pgid" 2>/dev/null; then
				echo "  stopping process group $pgid"
				kill -TERM -- "-$pgid" 2>/dev/null
			fi
		done

		for _ in {1..10}; do
			any_alive=0
			for pgid in "${active_pgids[@]}"; do
				if kill -0 -- "-$pgid" 2>/dev/null; then
					any_alive=1
					break
				fi
			done
			(( any_alive == 0 )) && break
			sleep 0.1
		done

		for pgid in "${active_pgids[@]}"; do
			if kill -0 -- "-$pgid" 2>/dev/null; then
				echo "  force-stopping process group $pgid"
				kill -KILL -- "-$pgid" 2>/dev/null
			fi
		done
	fi

	rm -rf -- "$tmpdir"
	exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

state_frame="$startingFrame"
echo
echo "=== Preparing Course $currentHoleNumber exhaustive landing-state search ==="
echo "Starting frame : $startingFrame"
echo "Cursor         : $initialX,$initialY (Display Input)"
echo "Upper limit    : $frames_upperlimit frames/candidate"
echo "Ranking target : $targetX,$targetY (ball-position RAM coordinates)"
echo "Hole byte      : $START_HOLE -> $NEXT_HOLE"
echo

echo "Creating state at frame $state_frame: $STATE"
rm -f "$STATE"

setsid "$CHRUN" \
	--project "$PROJECT" \
	"$HYBPKG" \
	--allow-core-mismatch \
	--files "$HOME" \
	--frames "$state_frame" \
	--final-state "$STATE" &
state_pgid=$!
active_pgids+=("$state_pgid")
wait "$state_pgid"
remove_active_pgid "$state_pgid"

[[ -s "$STATE" ]] || {
	echo "State was not created: $STATE" >&2
	exit 1
}

verify_ram="$tmpdir/verify.ram"
setsid "$CHRUN" \
	--project "$PROJECT" \
	"$HYBPKG" \
	--allow-core-mismatch \
	--files "$HOME" \
	--state "$STATE" \
	--frames 0 \
	--dump "Physical RAM=$verify_ram" \
	>/dev/null 2>&1 &
verify_pgid=$!
active_pgids+=("$verify_pgid")
wait "$verify_pgid"
remove_active_pgid "$verify_pgid"

read -r state_hole state_playable < <(
	python3 - "$verify_ram" "$HOLE_ADDRESS" "$BALL_PLAYABLE_ADDRESS" <<'PY'
from pathlib import Path
import struct
import sys

data = Path(sys.argv[1]).read_bytes()
hole_address = int(sys.argv[2], 0)
playable_address = int(sys.argv[3], 0)

if hole_address >= len(data):
    raise SystemExit("Physical RAM dump is too small for hole address")
if playable_address + 4 > len(data):
    raise SystemExit("Physical RAM dump is too small for playable address")

hole = data[hole_address]
playable = struct.unpack_from("<I", data, playable_address)[0]
print(hole, playable)
PY
)

if (( state_hole != START_HOLE )); then
	echo "State verification failed: expected hole byte $START_HOLE, got $state_hole." >&2
	echo "The supplied startingFrame ($startingFrame) may not be on Course $currentHoleNumber." >&2
	exit 1
fi
echo "State verified: frame $state_frame, hole byte $state_hole, playable=$state_playable."

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
if [[ -e "$OUT" ]]; then
	backup="${OUT}.previous.$(date +'%Y%m%d-%H%M%S')"
	echo
	echo "Preserving previous output:"
	echo "  $OUT"
	echo "  -> $backup"
	mv -- "$OUT" "$backup"
fi
mkdir -p "$OUT"

python3 - "$SHARED" "$frames_upperlimit" <<'PY'
import struct
import sys
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<i", int(sys.argv[2])))
PY

python3 - \
	"$RUN_CONFIG" \
	"$currentHoleNumber" "$startingFrame" "$initialX" "$initialY" "$frames_upperlimit" \
	"$targetX" "$targetY" \
	"$state_frame" "$START_HOLE" "$NEXT_HOLE" "$WORKERS" \
	"$STATE" "$PROJECT" "$HYBPKG" "$CHRUN" <<'PY'
import json
import sys
from pathlib import Path

(
    out,
    hole, starting_frame, x, y, limit,
    target_x, target_y,
    state_frame, start_hole, next_hole, workers,
    state, project, core, chimera_run,
) = sys.argv[1:]

payload = {
    "currentHoleNumber": int(hole),
    "startingFrame": int(starting_frame),
    "initialX": int(x),
    "initialY": int(y),
    "frames_upperlimit": int(limit),
    "targetX": int(target_x),
    "targetY": int(target_y),
    "targetCoordinateSystem": "Physical RAM ball position (u16 little-endian)",
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
echo "=== Launching Course $currentHoleNumber exhaustive landing-state search ==="
echo "State       : frame $state_frame"
echo "Cursor      : $initialX,$initialY"
echo "Carrier     : $START_AXIS_X,$START_AXIS_Y"
echo "Hole byte   : $START_HOLE -> $NEXT_HOLE"
echo "Upper limit : $frames_upperlimit frames"
echo "Target      : $targetX,$targetY (ball RAM coordinates)"
echo "Workers     : $WORKERS"
echo "CPUs        : ${CPUS[*]}"
echo "Output      : $OUT"
echo
echo "Monitor in another terminal with:"
echo "  python3 monitor_global_landing_search.py $currentHoleNumber $frames_upperlimit $targetX $targetY"
echo

START="$(date +%s)"
pids=()

for ((w = 0; w < WORKERS; w++)); do
	cpu="${CPUS[$w]}"
	echo "worker $w -> CPU $cpu"
	setsid /usr/bin/time \
		-o "$OUT/worker-$w.time" \
		-f 'REAL=%e USER=%U SYS=%S EXIT=%x' \
		taskset -c "$cpu" \
		env \
		MINIGOLF_SCAN=1 \
		MINIGOLF_SCAN_LANDINGS=1 \
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
		MINIGOLF_SCAN_ORDER=native \
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
	pid=$!
	pids+=("$pid")
	active_pgids+=("$pid")
done

rc=0
for w in "${!pids[@]}"; do
	pid="${pids[$w]}"
	if wait "$pid"; then
		status=0
	else
		status=$?
		rc=1
	fi
	remove_active_pgid "$pid"
	printf 'worker %d exit=%d\n' "$w" "$status"
	if (( status != 0 )); then
		echo "  log: $OUT/worker-$w.log"
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
echo "All workers exited."
echo "exit status  : $rc"
echo "wall seconds : $((END - START))"

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

if [[ -f "$SCRIPT_DIR/rank_global_results.py" ]]; then
	echo
echo "Top landing candidates:"
	python3 "$SCRIPT_DIR/rank_global_results.py" \
		"$currentHoleNumber" "$targetX" "$targetY" \
		--top 10 --write "$TOP_TSV" || true
	echo
echo "Rerank the same run later with any target (no emulation rerun):"
	echo "  python3 rank_global_results.py $currentHoleNumber NEW_TARGET_X NEW_TARGET_Y --top 10"
fi

exit "$rc"
