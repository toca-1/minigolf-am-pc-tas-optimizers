#!/usr/bin/env python3

from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile

try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit(
        "Pillow is required. On Ubuntu, install it with: sudo apt install python3-pil"
    ) from None


BALL_PATTERN = re.compile(r"(?:^|\s)ball=(-?\d+),(-?\d+)(?:\s|$)")
STATUS_PATTERN = re.compile(r"(?:^|\s)status=([a-z_]+)(?:\s|$)")
COLOR_PATTERN = re.compile(r"#?([0-9a-fA-F]{6})\Z")
VIDEO_SIZE = (640, 480)
CACHE_VERSION = 1
DEFAULT_OFFSET_X = 6
DEFAULT_OFFSET_Y = 45


def positive_scale(text: str) -> float:
    try:
        value = float(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("scale must be a positive number") from exc
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("scale must be positive and finite")
    return value


def hex_color(text: str) -> tuple[int, int, int]:
    match = COLOR_PATTERN.fullmatch(text)
    if not match:
        raise argparse.ArgumentTypeError("color must be a six-digit hex value, e.g. '#ff00ff'")
    code = match.group(1)
    return tuple(int(code[i : i + 2], 16) for i in (0, 2, 4))


def log_snapshot(log_dir: Path) -> tuple[list[Path], list[dict]]:
    paths = sorted(log_dir.glob("worker-*.log"))
    sources = []
    for path in paths:
        stat = path.stat()
        sources.append({"name": path.name, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns})
    return paths, sources


def collect_landings(paths: list[Path]) -> tuple[Counter[tuple[int, int]], Counter[str]]:
    counts: Counter[tuple[int, int]] = Counter()
    statuses: Counter[str] = Counter()

    for path in paths:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for physical_line in handle:
                for line in physical_line.split(r"\n"):
                    line = line.strip()
                    if not line.startswith("LANDING_RESULT "):
                        continue
                    status_match = STATUS_PATTERN.search(line)
                    if status_match is None:
                        statuses["malformed"] += 1
                        continue
                    status = status_match.group(1)
                    if status == "ready":  # Older test logs used this spelling.
                        status = "ended"
                    statuses[status] += 1
                    if status != "ended":
                        continue
                    ball_match = BALL_PATTERN.search(line)
                    if ball_match is None:
                        statuses["ended_missing_ball"] += 1
                        continue
                    x, y = map(int, ball_match.groups())
                    if x < 0 or y < 0:
                        statuses["ended_invalid_ball"] += 1
                        continue
                    counts[(x, y)] += 1

    return counts, statuses


def cache_meta_path(cache_path: Path) -> Path:
    return cache_path.with_suffix(".meta.json")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_cache(
    cache_path: Path,
    counts: Counter[tuple[int, int]],
    statuses: Counter[str],
    sources: list[dict],
) -> None:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path = cache_meta_path(cache_path)
    temporary: Path | None = None
    meta_temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="", dir=cache_path.parent,
            prefix=f".{cache_path.name}.", delete=False,
        ) as handle:
            temporary = Path(handle.name)
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            writer.writerow(("x", "y", "count"))
            for (x, y), count in sorted(counts.items()):
                writer.writerow((x, y, count))

        metadata = {
            "cache_version": CACHE_VERSION,
            "sources": sources,
            "statuses": dict(statuses),
            "landing_records": sum(counts.values()),
            "distinct_positions": len(counts),
            "tsv_sha256": file_sha256(temporary),
        }
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=meta_path.parent,
            prefix=f".{meta_path.name}.", delete=False,
        ) as handle:
            meta_temporary = Path(handle.name)
            json.dump(metadata, handle, indent=2, sort_keys=True)
            handle.write("\n")

        temporary.replace(cache_path)
        temporary = None
        meta_temporary.replace(meta_path)
        meta_temporary = None
    finally:
        for leftover in (temporary, meta_temporary):
            if leftover is not None:
                leftover.unlink(missing_ok=True)


def read_cache(
    cache_path: Path, expected_sources: list[dict] | None,
) -> tuple[Counter[tuple[int, int]], Counter[str], int] | None:
    meta_path = cache_meta_path(cache_path)
    try:
        with meta_path.open("r", encoding="utf-8") as handle:
            metadata = json.load(handle)
        if metadata.get("cache_version") != CACHE_VERSION:
            return None
        if expected_sources is not None and metadata.get("sources") != expected_sources:
            return None
        if metadata.get("tsv_sha256") != file_sha256(cache_path):
            return None
        positions: Counter[tuple[int, int]] = Counter()
        with cache_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            if reader.fieldnames != ["x", "y", "count"]:
                return None
            for row in reader:
                x, y, count = int(row["x"]), int(row["y"]), int(row["count"])
                if x < 0 or y < 0 or count <= 0 or (x, y) in positions:
                    return None
                positions[(x, y)] = count
        if len(positions) != metadata.get("distinct_positions"):
            return None
        if sum(positions.values()) != metadata.get("landing_records"):
            return None
        statuses = Counter(metadata["statuses"])
        return positions, statuses, len(metadata["sources"])
    except (OSError, ValueError, TypeError, KeyError, csv.Error, json.JSONDecodeError):
        return None


def positions_from_cache_or_logs(
    log_dir: Path, cache_path: Path, refresh: bool, cache_only: bool,
) -> tuple[Counter[tuple[int, int]], Counter[str], int, str]:
    if cache_only:
        cached = read_cache(cache_path, expected_sources=None)
        if cached is None:
            raise ValueError(f"no usable cache at {cache_path} (or matching .meta.json)")
        return *cached, "reused (cache-only; log changes not checked)"

    paths, sources = log_snapshot(log_dir)
    if not paths:
        raise ValueError(f"no worker-*.log files found in {log_dir}")

    if not refresh:
        cached = read_cache(cache_path, expected_sources=sources)
        if cached is not None:
            return *cached, "reused (worker logs unchanged)"

    # Logs may still be growing during a search: don't claim an incomplete
    # extraction is up to date if any file changed while we were reading it.
    for attempt in range(2):
        counts, statuses = collect_landings(paths)
        paths_after, sources_after = log_snapshot(log_dir)
        if paths_after == paths and sources_after == sources:
            write_cache(cache_path, counts, statuses, sources)
            return counts, statuses, len(paths), "created/refreshed from logs"
        paths, sources = paths_after, sources_after
        if not paths:
            break
    raise ValueError("worker logs changed while being parsed; rerun when they are stable")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mark every recorded finished-shot landing position on a Minigolf course image."
    )
    parser.add_argument("currentHoleNumber", type=int, help="course number (1..18)")
    parser.add_argument("image", type=Path, help="course screenshot (not necessarily a cropped game view)")
    parser.add_argument(
        "--logs", type=Path,
        help="search output folder (default: $MINIGOLF_OUT_ROOT/minigolf-holeN-exhaustive, or ~/...)"
    )
    parser.add_argument(
        "--cache", type=Path,
        help="position cache TSV (default: <logs>/landing-positions.tsv)"
    )
    parser.add_argument(
        "--refresh-cache", action="store_true", help="force fresh extraction even if the logs are unchanged"
    )
    parser.add_argument(
        "--cache-only", action="store_true", help="plot using the cache without reading or checking the worker logs"
    )
    parser.add_argument(
        "--output", type=Path,
        help="output PNG (default: <image_stem>_landings.png alongside the input image)"
    )
    parser.add_argument("--radius", type=int, default=2, help="filled circle radius in output pixels (0 = one pixel; default: 2)")
    parser.add_argument("--color", type=hex_color, default=(0, 0, 255), help="marker RGB hex color (default: #0000ff)")
    parser.add_argument("--opacity", type=int, default=255, help="marker opacity 1..255 (default: 255 = solid)")
    parser.add_argument(
        "--offset-x",
        type=int,
        default=DEFAULT_OFFSET_X,
        help=f"image X coordinate corresponding to RAM x=0 (default: {DEFAULT_OFFSET_X})",
    )
    parser.add_argument(
        "--offset-y",
        type=int,
        default=DEFAULT_OFFSET_Y,
        help=f"image Y coordinate corresponding to RAM y=0 (default: {DEFAULT_OFFSET_Y})",
    )
    parser.add_argument("--scale-x", type=positive_scale, default=1.0, help="horizontal image pixels per RAM unit (default: 1)")
    parser.add_argument("--scale-y", type=positive_scale, default=1.0, help="vertical image pixels per RAM unit (default: 1)")
    args = parser.parse_args()

    if not 1 <= args.currentHoleNumber <= 18:
        parser.error("currentHoleNumber must be 1..18")
    if args.radius < 0:
        parser.error("--radius must be >= 0")
    if not 1 <= args.opacity <= 255:
        parser.error("--opacity must be 1..255")
    if args.cache_only and args.refresh_cache:
        parser.error("--cache-only and --refresh-cache cannot be combined")

    out_root = Path(os.environ.get("MINIGOLF_OUT_ROOT", str(Path.home()))).expanduser()
    log_dir = (args.logs or (out_root / f"minigolf-hole{args.currentHoleNumber}-exhaustive")).expanduser()
    cache = (args.cache or (log_dir / "landing-positions.tsv")).expanduser()
    output = (args.output or args.image.with_name(f"{args.image.stem}_landings.png")).expanduser()
    if output.suffix.lower() != ".png":
        parser.error("--output must end in .png (to preserve exact pixel markers)")
    if args.image.resolve() == output.resolve():
        parser.error("input image and output image must be different files")

    try:
        positions, statuses, num_logs, cache_action = positions_from_cache_or_logs(
            log_dir, cache, args.refresh_cache, args.cache_only
        )
        if not positions:
            raise ValueError(f"no valid 'status=ended' landing positions found in {log_dir}")
        with Image.open(args.image) as source:
            base = source.convert("RGBA")
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Error: {exc}\n")

    width, height = base.size
    if base.size != VIDEO_SIZE and (
        args.offset_x,
        args.offset_y,
        args.scale_x,
        args.scale_y,
    ) == (DEFAULT_OFFSET_X, DEFAULT_OFFSET_Y, 1.0, 1.0):
        print(
            f"WARNING: image is {width}x{height}, not 640x480. "
            "Check alignment; use --offset-x/--offset-y and --scale-x/--scale-y as needed.",
            file=sys.stderr,
        )

    # Deduplicate destination pixels, including positions collapsed by scaling.
    pixel_positions: set[tuple[int, int]] = set()
    offscreen_landings = 0
    offscreen_unique = 0
    for (x, y), num_shots in positions.items():
        px = args.offset_x + round(x * args.scale_x)
        py = args.offset_y + round(y * args.scale_y)
        if not (0 <= px < width and 0 <= py < height):
            offscreen_unique += 1
            offscreen_landings += num_shots
            continue
        pixel_positions.add((px, py))

    if not pixel_positions:
        parser.exit(
            1,
            "Error: all landing positions fall outside the image. "
            "Check image dimensions, --offset-x/--offset-y, and --scale-x/--scale-y.\n",
        )

    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    fill = (*args.color, args.opacity)
    for x, y in pixel_positions:
        if args.radius == 0:
            draw.point((x, y), fill=fill)
        else:
            draw.ellipse(
                (x - args.radius, y - args.radius, x + args.radius, y + args.radius),
                fill=fill,
            )

    result = Image.alpha_composite(base, overlay)
    try:
        result.save(output)
    except OSError as exc:
        parser.exit(1, f"Error writing {output}: {exc}\n")

    print(f"Cache               : {cache} ({cache_action})")
    print(f"Worker logs recorded: {num_logs}")
    print(f"Landing records     : {sum(positions.values())} (status=ended, valid coordinates)")
    print(f"Distinct RAM points : {len(positions)}")
    print(f"Markers drawn       : {len(pixel_positions)}")
    print(f"Off-image positions : {offscreen_unique} distinct / {offscreen_landings} records")
    others = ("hio", "timeout", "no_shot", "malformed", "ended_missing_ball", "ended_invalid_ball")
    print(
        "Other statuses      : " + ", ".join(f"{s}={statuses[s]}" for s in others if statuses[s])
        if any(statuses[s] for s in others) else "Other statuses      : none"
    )
    print(f"Saved               : {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
