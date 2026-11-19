#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/svbench-src"
OUT="$ROOT/build/svbench"

mkdir -p "$SRC"

# The parser is a package-main frontend. Build it together with the harness in an
# ignored staging directory so the checked-in source tree stays a single package.
ln -sfn "$ROOT/src/file_picker" "$SRC/file_picker"
for file in \
	lexer_common.odin \
	system_verilog.odin \
	system_verilog_lex.odin \
	system_verilog_pp.odin \
	system_verilog_parser.odin
do
	ln -sf "$ROOT/src/$file" "$SRC/$file"
done
cp "$ROOT/scripts/svbench/main.odin" "$SRC/main.odin"

odin build "$SRC" -o:speed -out:"$OUT"
echo "built $OUT"
