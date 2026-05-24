#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def export_name_for(source: Path) -> str:
    source = source.resolve()
    if source.name == "concepts":
        stem = source.parent.name
    else:
        stem = source.name
    return stem if stem.startswith("ref-") else f"ref-{stem}"


def iter_ttls(source: Path) -> list[Path]:
    return sorted(
        path
        for path in source.rglob("*.ttl")
        if "__pycache__" not in path.parts
    )


def export_tree(source: Path, output_root: Path) -> tuple[Path, int]:
    destination = output_root / export_name_for(source)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)

    count = 0
    for ttl_path in iter_ttls(source):
        target = destination / ttl_path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ttl_path, target)
        count += 1

    return destination, count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Copy every Turtle file under a source tree into fixtures/WIP/ref-*/."
    )
    parser.add_argument("source", help="Source tree to scan for .ttl files")
    parser.add_argument(
        "--output-root",
        default="fixtures/WIP",
        help="Destination root (default: fixtures/WIP)",
    )
    args = parser.parse_args()

    source = Path(args.source).expanduser().resolve()
    if not source.exists():
        parser.error(f"source path does not exist: {source}")

    output_root = Path(args.output_root).resolve()
    destination, count = export_tree(source, output_root)
    print(f"exported {count} ttl files")
    print(f"source: {source}")
    print(f"destination: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
