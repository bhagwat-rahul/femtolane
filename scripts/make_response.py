#!/usr/bin/env python3
"""Build an svbench response file from a directory or a source file list.

Examples:
  scripts/make_response.py rtl/ --include rtl/include --out /tmp/rtl.resp
  scripts/make_response.py --filelist build/rtl/filelist.f --out /tmp/soc.resp
"""
from __future__ import annotations

import argparse
import fnmatch
from pathlib import Path


def source_files(root: Path, excludes: list[str]) -> list[Path]:
    out: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in (".v", ".sv"):
            continue
        rel = path.relative_to(root).as_posix()
        if any(fnmatch.fnmatch(rel, pattern) for pattern in excludes):
            continue
        out.append(path.resolve())
    return sorted(out)


def list_files(filelist: Path, excludes: list[str]) -> list[Path]:
    base = filelist.resolve().parent
    out: list[Path] = []
    seen: set[Path] = set()
    for raw in filelist.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        path = Path(line)
        if not path.is_absolute():
            path = base / path
        path = path.resolve()
        if path.suffix.lower() not in (".v", ".sv"):
            continue
        rel = path.as_posix()
        if any(fnmatch.fnmatch(rel, pattern) for pattern in excludes):
            continue
        if path not in seen:
            seen.add(path)
            out.append(path)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("root", nargs="?", type=Path, help="directory to scan")
    source.add_argument("--filelist", type=Path, help="file containing source paths")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--include", action="append", default=[], type=Path)
    parser.add_argument("--define", action="append", default=[])
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument(
        "--reset",
        action="store_true",
        help="emit RESET before each file (per-file compilation units)",
    )
    args = parser.parse_args()

    if args.filelist:
        files = list_files(args.filelist, args.exclude)
    else:
        files = source_files(args.root, args.exclude)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    lines = 0
    size = 0
    with args.out.open("w") as fh:
        for include in args.include:
            fh.write(f"INCDIR {include.resolve()}\n")
        for define in args.define:
            fh.write(f"DEFINE {define}\n")
        for path in files:
            if args.reset:
                fh.write("RESET\n")
            fh.write(f"FILE {path}\n")
            lines += path.read_bytes().count(b"\n")
            size += path.stat().st_size

    print(
        f"{len(files)} files, {lines:,} lines, {size / 1e6:.1f} MB -> {args.out}"
    )


if __name__ == "__main__":
    main()
