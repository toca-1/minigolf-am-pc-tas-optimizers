#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import os
from pathlib import Path
from typing import Iterator


def bounded_int(name: str, minimum: int, maximum: int):
    def parse(value: str) -> int:
        try:
            n = int(value)
        except ValueError as exc:
            raise argparse.ArgumentTypeError(f"{name} must be an integer") from exc
        if not minimum <= n <= maximum:
            raise argparse.ArgumentTypeError(
                f"{name} must be {minimum}..{maximum}"
            )
        return n
    return parse


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


def iter_logical_lines(path: Path) -> Iterator[str]:
    data = path.read_text(errors="replace").replace("\\n", "\n")
    yield from data.splitlines()


def collect(root: Path, target_x: int, target_y: int) -> tuple[list[dict], dict[str, int]]:
    ready: list[dict] = []
    counts = {"ended": 0, "hio": 0, "timeout": 0, "no_shot": 0}

    for path in sorted(root.glob("worker-*.log")):
        for line in iter_logical_lines(path):
            if not line.startswith("LANDING_RESULT "):
                continue
            f = parse_fields(line)
            status = f.get("status", "")

            # Compatibility with older test logs.
            if status == "ready":
                status = "ended"

            if status in counts:
                counts[status] += 1

            if status != "ended":
                continue

            ball_x, ball_y = parse_pair(f["ball"])
            raw_x, raw_y = parse_pair(f["raw"])
            dist2 = (ball_x - target_x) ** 2 + (ball_y - target_y) ** 2

            ready.append({
                "worker": int(f["worker"]),
                "plan": int(f["plan"]),
                "raw_x": raw_x,
                "raw_y": raw_y,
                "aliases": int(f["aliases"]),
                "x_bounds": f["x_bounds"],
                "y_bounds": f["y_bounds"],
                "dx": int(f["dx"]),
                "dy": int(f["dy"]),
                "input_frames": int(f["input_frames"]),
                "ready_after": int(f["after"]),
                "ball_x": ball_x,
                "ball_y": ball_y,
                "dist2": dist2,
            })

    ready.sort(key=lambda r: (r["dist2"], r["ready_after"], r["plan"]))
    return ready, counts


def pareto_frontier(rows: list[dict]) -> list[dict]:
    # Non-dominated in (distance^2, ready_after).  Sort by distance first;
    # a row survives only if it improves the best ready time seen so far.
    result: list[dict] = []
    best_ready: int | None = None
    for row in rows:
        ready = row["ready_after"]
        if best_ready is None or ready < best_ready:
            result.append(row)
            best_ready = ready
    return result


def print_rows(rows: list[dict], start_frame: int | None, limit: int) -> None:
    print(
        " #   distance  ended  signal frm  ball       raw mpx,mpy   plan     dx,dy"
    )
    for i, row in enumerate(rows[:limit], 1):
        distance = math.sqrt(row["dist2"])
        tas_frame = (
            str(start_frame + row["ready_after"])
            if start_frame is not None
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


def write_tsv(path: Path, rows: list[dict], start_frame: int | None, limit: int) -> None:
    columns = [
        "rank", "distance", "dist2", "ready_after", "tas_frame",
        "ball_x", "ball_y", "raw_x", "raw_y", "plan", "worker",
        "aliases", "x_bounds", "y_bounds", "dx", "dy", "input_frames",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=columns, delimiter="\t")
        writer.writeheader()
        for rank, row in enumerate(rows[:limit], 1):
            writer.writerow({
                "rank": rank,
                "distance": f"{math.sqrt(row['dist2']):.6f}",
                "dist2": row["dist2"],
                "ready_after": row["ready_after"],
                "tas_frame": (
                    start_frame + row["ready_after"]
                    if start_frame is not None
                    else ""
                ),
                **{k: row[k] for k in columns if k in row},
            })


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Rank first-shot landing states from a Minigolf global run."
    )
    parser.add_argument("currentHoleNumber", type=bounded_int("currentHoleNumber", 1, 18))
    parser.add_argument("targetX", type=bounded_int("targetX", 0, 65535))
    parser.add_argument("targetY", type=bounded_int("targetY", 0, 65535))
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--pareto", action="store_true", help="rank only non-dominated distance/time candidates")
    parser.add_argument("--write", type=Path, help="write the displayed rows as TSV")
    args = parser.parse_args()

    if args.top <= 0:
        parser.error("--top must be > 0")

    out_root = Path(os.environ.get("MINIGOLF_OUT_ROOT", str(Path.home()))).expanduser()
    root = out_root / f"minigolf-hole{args.currentHoleNumber}-exhaustive"
    if not root.is_dir():
        raise SystemExit(f"search directory not found: {root}")

    start_frame: int | None = None
    config = root / "run-config.json"
    if config.is_file():
        import json
        try:
            start_frame = int(json.loads(config.read_text()).get("stateFrame"))
        except (ValueError, TypeError, json.JSONDecodeError):
            start_frame = None

    rows, counts = collect(root, args.targetX, args.targetY)
    selected = pareto_frontier(rows) if args.pareto else rows

    print(f"Target (ball RAM coordinates): {args.targetX},{args.targetY}")
    print(
        "Results: "
        f"ended={counts['ended']} hio={counts['hio']} "
        f"timeout={counts['timeout']} no_shot={counts['no_shot']}"
    )
    if args.pareto:
        print(f"Pareto frontier: {len(selected)} candidates")
    print()

    if not selected:
        print("No rankable landing states found.")
        return 0

    print_rows(selected, start_frame, args.top)

    if args.write:
        write_tsv(args.write, selected, start_frame, args.top)
        print(f"\nWrote: {args.write}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
