#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/svbench-src"
OUT="$ROOT/build/svbench"

mkdir -p "$SRC"
# Drop stale links from older file names before staging the current sources.
find "$SRC" -maxdepth 1 -type l -delete

# The parser is a package-main frontend. Build it together with the harness in an
# ignored staging directory so the checked-in source tree stays a single package.
ln -sfn "$ROOT/src/file_picker" "$SRC/file_picker"
for file in \
	lexer_common.odin \
	system_verilog.odin \
	system_verilog_tokenizer.odin \
	system_verilog_preprocessor.odin \
	system_verilog_parser.odin
do
	ln -sf "$ROOT/src/$file" "$SRC/$file"
done
cp "$ROOT/scripts/svbench/main.odin" "$SRC/main.odin"

odin build "$SRC" -o:speed -out:"$OUT"
echo "built $OUT"
