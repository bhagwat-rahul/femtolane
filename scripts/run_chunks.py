#!/usr/bin/env python3
"""Run a response file in chunks and report which files fail.

A single bad file otherwise aborts the whole batch. This runner keeps the
response header (INCDIR/DEFINE lines), sends a chunk of FILE entries, and on
failure removes the last attempted file before retrying the rest of the chunk.
"""
from __future__ import annotations

import argparse
import collections
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

FAIL_RE = re.compile(r"(panic:|unsatisfied ensure:) (.*)")


def read_response(path: Path):
    header: list[str] = []
    files: list[str] = []
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        if line.startswith("FILE "):
            files.append(line[5:])
        elif line == "RESET":
            continue
        else:
            header.append(line)
    return header, files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("response", type=Path)
    parser.add_argument("--svbench", type=Path, default=Path("build/svbench"))
    parser.add_argument("--chunk", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=600.0)
    args = parser.parse_args()

    header, files = read_response(args.response)
    print(f"files={len(files)} header_lines={len(header)}", flush=True)

    passed = 0
    failures: list[tuple[str, str]] = []
    errors: collections.Counter[str] = collections.Counter()

    for start in range(0, len(files), args.chunk):
        chunk = files[start : start + args.chunk]
        while chunk:
            with tempfile.NamedTemporaryFile(
                "w", suffix=".resp", delete=False
            ) as fh:
                for line in header:
                    fh.write(line + "\n")
                fh.write("RESET\n")
                for path in chunk:
                    fh.write("FILE " + path + "\n")
                response_path = fh.name

            try:
                result = subprocess.run(
                    [str(args.svbench), response_path],
                    capture_output=True,
                    text=True,
                    timeout=args.timeout,
                )
            except subprocess.TimeoutExpired:
                os.unlink(response_path)
                failures.extend((path, "timeout") for path in chunk)
                break
            finally:
                if os.path.exists(response_path):
                    os.unlink(response_path)

            if result.returncode == 0:
                passed += len(chunk)
                break

            tried = re.findall(r"^TRY  (.*)$", result.stderr, re.M)
            last = tried[-1] if tried else None
            if last is None:
                failures.extend((path, "unknown failure") for path in chunk)
                break

            err_line = result.stderr.splitlines()[-1] if result.stderr else ""
            match = FAIL_RE.search(err_line)
            message = match.group(0) if match else err_line
            failures.append((last, message))
            errors[message[:180]] += 1
            if last not in chunk:
                break
            chunk.remove(last)

        if (start // args.chunk) % 20 == 0:
            print(
                f"chunk {start:>6} passed={passed} failed={len(failures)}",
                flush=True,
            )

    print(f"\npassed {passed} failed {len(failures)}")
    for message, count in errors.most_common(30):
        print(f"{count:6} {message}")
    if failures:
        print("\nFailures:")
        for path, message in failures[:200]:
            print(f"{path} :: {message}")
        if len(failures) > 200:
            print(f"... {len(failures) - 200} more")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
