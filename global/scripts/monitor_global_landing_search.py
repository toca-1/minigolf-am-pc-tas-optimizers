#!/usr/bin/env python3

from __future__ import annotations

import argparse
from collections import deque
import json
import math
import os
from pathlib import Path
import re
import struct
import time

DEFAULT_TOTAL = 261_016
TOKEN = b"[minigolf] CPU core -> dynamic_x86"
INTERVAL = 10.0
RATE_WINDOW = 60.0
TOP_N = 10


def bounded_int(name: str, minimum: int, maximum: int):
	def parse(value: str) -> int:
		try:
			n = int(value)
		except ValueError as exc:
			raise argparse.ArgumentTypeError(
				f"{name} must be an integer"
			) from exc

		if not minimum <= n <= maximum:
			raise argparse.ArgumentTypeError(
				f"{name} must be {minimum}..{maximum}"
			)

		return n

	return parse


parser = argparse.ArgumentParser(
	description="Monitor a Minigolf exhaustive landing-state search."
)
parser.add_argument(
	"currentHoleNumber",
	type=bounded_int("currentHoleNumber", 1, 18),
)
parser.add_argument(
	"frames_upperlimit",
	type=bounded_int("frames_upperlimit", 1, 10_000),
)
parser.add_argument(
	"targetX",
	type=bounded_int("targetX", 0, 65_535),
)
parser.add_argument(
	"targetY",
	type=bounded_int("targetY", 0, 65_535),
)
args = parser.parse_args()

hole = args.currentHoleNumber
upper_limit = args.frames_upperlimit
target_x = args.targetX
target_y = args.targetY

out_root = Path(
	os.environ.get("MINIGOLF_OUT_ROOT", str(Path.home()))
).expanduser()

root = out_root / f"minigolf-hole{hole}-exhaustive"
shared_path = root / "shared-best.bin"
config_path = root / "run-config.json"
finished_path = root / "run-finished.json"

total = DEFAULT_TOTAL
candidate_count = 0

improvement_events: list[str] = []
shared_by_score: dict[int, str] = {}
completed: dict[int, str] = {}

landing_counts = {
	"ended": 0,
	"hio": 0,
	"timeout": 0,
	"no_shot": 0,
}
top_landings: list[dict[str, int]] = []

states: dict[Path, dict[str, object]] = {}

samples: deque[tuple[float, int]] = deque()
samples.append((time.monotonic(), 0))


def parse_score(line: str) -> int | None:
	m = re.search(r"\bscore=(\d+)\b", line)
	return int(m.group(1)) if m else None


def parse_plan(line: str) -> int:
	m = re.search(r"\bplan=(\d+)\b", line)
	return int(m.group(1)) if m else -1


def parse_worker(line: str) -> int:
	m = re.search(r"\bworker=(\d+)\b", line)
	return int(m.group(1)) if m else -1


def parse_fields(line: str) -> dict[str, str]:
	fields: dict[str, str] = {}
	for token in line.split()[1:]:
		if "=" not in token:
			continue
		key, value = token.split("=", 1)
		fields[key] = value
	return fields


def parse_pair(value: str) -> tuple[int, int]:
	left, right = value.split(",", 1)
	return int(left), int(right)


def consider_landing(line: str) -> None:
	fields = parse_fields(line)
	status = fields.get("status", "")

	# "ready" is accepted for compatibility with earlier test logs.
	if status == "ready":
		status = "ended"

	if status in landing_counts:
		landing_counts[status] += 1

	if status != "ended":
		return

	try:
		ball_x, ball_y = parse_pair(fields["ball"])
		raw_x, raw_y = parse_pair(fields["raw"])
		row = {
			"worker": int(fields["worker"]),
			"plan": int(fields["plan"]),
			"raw_x": raw_x,
			"raw_y": raw_y,
			"dx": int(fields["dx"]),
			"dy": int(fields["dy"]),
			"ready_after": int(fields["after"]),
			"ball_x": ball_x,
			"ball_y": ball_y,
		}
	except (KeyError, ValueError):
		return

	row["dist2"] = (
		(ball_x - target_x) ** 2
		+ (ball_y - target_y) ** 2
	)

	top_landings.append(row)
	top_landings.sort(
		key=lambda r: (
			r["dist2"],
			r["ready_after"],
			r["plan"],
		)
	)
	del top_landings[TOP_N:]


def consume_logical_line(line: str) -> None:
	global total

	m = re.match(r"unique plans\s*:\s*(\d+)", line)
	if m:
		total = int(m.group(1))

	if line.startswith("LANDING_RESULT "):
		consider_landing(line)
		return

	if line.startswith(("SHARED_BEST ", "NEW_BEST ", "TIE_BEST ")):
		improvement_events.append(line)

	if line.startswith("SHARED_BEST "):
		score = parse_score(line)
		if score is not None:
			shared_by_score[score] = line

	elif line.startswith("SCAN_RESULT "):
		worker = parse_worker(line)
		if worker >= 0:
			completed[worker] = line


def consume_physical_line(raw: bytes) -> None:
	text = raw.decode("utf-8", errors="replace")
	text = text.replace("\\n", "\n")

	for line in text.splitlines():
		consume_logical_line(line)


def scan_full_log(path: Path) -> None:
	global candidate_count

	try:
		data = path.read_bytes()
	except OSError:
		data = b""

	candidate_count += data.count(TOKEN)
	pieces = data.split(b"\n")

	for raw in pieces[:-1]:
		consume_physical_line(raw)

	states[path] = {
		"offset": len(data),
		"token_tail": data[-(len(TOKEN) - 1):] if TOKEN else b"",
		"physical_carry": pieces[-1],
	}


def rescan_all_logs() -> None:
	global total, candidate_count
	global improvement_events, shared_by_score, completed, states, samples
	global landing_counts, top_landings

	total = DEFAULT_TOTAL
	candidate_count = 0
	improvement_events = []
	shared_by_score = {}
	completed = {}
	states = {}
	landing_counts = {
		"ended": 0,
		"hio": 0,
		"timeout": 0,
		"no_shot": 0,
	}
	top_landings = []

	for path in sorted(root.glob("worker-*.log")):
		scan_full_log(path)

	samples = deque()
	samples.append((time.monotonic(), candidate_count))


def read_new_data() -> None:
	global candidate_count

	current_logs = sorted(root.glob("worker-*.log"))

	for path in current_logs:
		if path not in states:
			scan_full_log(path)

	for path in current_logs:
		state = states.get(path)
		if state is None:
			continue

		try:
			size = path.stat().st_size
		except OSError:
			continue

		old_size = int(state["offset"])

		if size < old_size:
			rescan_all_logs()
			return

		if size == old_size:
			continue

		try:
			with path.open("rb") as f:
				f.seek(old_size)
				new = f.read()
		except OSError:
			continue

		state["offset"] = size

		old_tail = state["token_tail"]
		assert isinstance(old_tail, bytes)

		combined_token_data = old_tail + new
		candidate_count += combined_token_data.count(TOKEN)
		state["token_tail"] = combined_token_data[
			-(len(TOKEN) - 1):
		]

		old_carry = state["physical_carry"]
		assert isinstance(old_carry, bytes)

		physical = old_carry + new
		pieces = physical.split(b"\n")

		for raw in pieces[:-1]:
			consume_physical_line(raw)

		state["physical_carry"] = pieces[-1]


def shared_best() -> int:
	try:
		raw = shared_path.read_bytes()[:4]
		if len(raw) == 4:
			return struct.unpack("<i", raw)[0]
	except OSError:
		pass
	return upper_limit


def incumbent_history() -> list[str]:
	rows = sorted(
		shared_by_score.items(),
		key=lambda item: item[0],
		reverse=True,
	)
	return [line for _, line in rows]


def current_best_hits(best: int) -> list[str]:
	rows: list[tuple[int, str]] = []
	for line in improvement_events:
		if not line.startswith(("NEW_BEST ", "TIE_BEST ")):
			continue
		if parse_score(line) != best:
			continue
		rows.append((parse_plan(line), line))
	rows.sort(key=lambda item: item[0])
	return [line for _, line in rows]


def read_config() -> dict | None:
	try:
		return json.loads(config_path.read_text())
	except (OSError, json.JSONDecodeError):
		return None


def config_matches(config: dict) -> bool:
	expected = {
		"currentHoleNumber": hole,
		"frames_upperlimit": upper_limit,
		"targetX": target_x,
		"targetY": target_y,
	}
	return all(
		config.get(key) == value
		for key, value in expected.items()
	)


def finished_info() -> dict | None:
	try:
		return json.loads(finished_path.read_text())
	except (OSError, json.JSONDecodeError):
		return None


def clear_screen() -> None:
	os.system("clear")


def render() -> bool:
	now = time.monotonic()

	samples.append((now, candidate_count))
	while len(samples) > 2 and now - samples[0][0] > RATE_WINDOW:
		samples.popleft()

	t0, c0 = samples[0]
	elapsed = now - t0
	rate = (
		(candidate_count - c0) / elapsed
		if elapsed > 0
		else 0.0
	)

	pct = (
		100.0 * candidate_count / total
		if total > 0
		else 0.0
	)
	pct = max(0.0, min(100.0, pct))
	remaining = max(0, total - candidate_count)

	if rate > 0:
		eta_seconds = int(remaining / rate)
		hours, rem = divmod(eta_seconds, 3600)
		minutes, seconds = divmod(rem, 60)
		eta = f"{hours:02d}:{minutes:02d}:{seconds:02d}"
	else:
		eta = "calculating..."

	width = 75
	filled = min(width, int(width * pct / 100.0))
	bar = "#" * filled + "-" * (width - filled)

	best = shared_best()
	history = incumbent_history()
	best_hits = (
		current_best_hits(best)
		if best < upper_limit
		else []
	)

	config = read_config()
	expected_workers = (
		int(config.get("workers", 0))
		if config and config_matches(config)
		else 0
	)
	state_frame = (
		int(config.get("stateFrame", 0))
		if config and config_matches(config)
		else None
	)
	detected_workers = len(states)

	clear_screen()

	print(
		f"Course {hole} exhaustive landing-state search "
		f"{time.strftime('%H:%M:%S')}"
	)
	print(
		f"upper limit {upper_limit}f | "
		f"target {target_x},{target_y} | "
		f"workers {detected_workers}"
		+ (f"/{expected_workers}" if expected_workers else "")
	)
	print()

	if not root.exists():
		print(f"Waiting for search directory:\n  {root}")
		return False

	if config and not config_matches(config):
		print("WARNING: run-config.json does not match these arguments.")
		print("Check currentHoleNumber, frames_upperlimit, targetX and targetY.")
		print()

	print(f"[{bar}] {pct:6.2f}%")
	print()
	print(f"candidate starts : {candidate_count} / {total}")
	print(f"60s rate         : {rate:.2f} plans/sec")
	print(f"ETA              : {eta}")
	print(
		"landing results  : "
		f"{landing_counts['ended']} ended | "
		f"{landing_counts['timeout']} timeout | "
		f"{landing_counts['no_shot']} no-shot | "
		f"{landing_counts['hio']} HIO"
	)

	if best < upper_limit:
		print(f"HIO BEST         : {best} frames")
	else:
		print("HIO BEST         : none yet")

	print()
	print(f"Top {TOP_N} landing states by distance to {target_x},{target_y}:")
	if top_landings:
		print(" #   distance  ended  signal frm  ball       raw mpx,mpy   plan     dx,dy")
		for i, row in enumerate(top_landings, 1):
			distance = math.sqrt(row["dist2"])
			tas_frame = (
				str(state_frame + row["ready_after"])
				if state_frame is not None
				else "?"
			)
			print(
				f"{i:2d}  {distance:9.3f}  "
				f"{row['ready_after']:5d}  {tas_frame:>9}   "
				f"{row['ball_x']:5d},{row['ball_y']:<5d}  "
				f"{row['raw_x']:4d},{row['raw_y']:<4d}      "
				f"{row['plan']:6d}  "
				f"{row['dx']:+4d},{row['dy']:+4d}"
			)
	else:
		print("(none yet)")

	if history:
		print()
		print("HIO incumbent history:")
		for line in history[-6:]:
			print(line)

	if best_hits:
		print()
		print(f"Current HIO-best classes ({best}f): {len(best_hits)} logged")
		for line in best_hits[-4:]:
			print(line)

	print()
	print("Completed workers:")
	if completed:
		for worker in sorted(completed):
			print(completed[worker])
	else:
		print("(none yet)")

	finished = finished_info()
	if finished is not None:
		print()
		print(
			"Search process finished: "
			f"exit={finished.get('exitStatus', '?')} "
			f"wall={finished.get('wallSeconds', '?')}s"
		)
		return True

	return False


if root.exists():
	rescan_all_logs()

while True:
	done = render()
	if done:
		break
	time.sleep(INTERVAL)
	read_new_data()
