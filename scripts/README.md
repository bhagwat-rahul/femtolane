# SystemVerilog parser harness

Small response-file harness used while profiling the SystemVerilog frontend.
It is deliberately separate from the regression tests and from the normal
`src` package.

## Build

```sh
scripts/build_svbench.sh
```

This stages the parser sources under `build/svbench-src` and writes
`build/svbench`. `build/` is already gitignored.

## Response files

One directive per line:

```text
INCDIR /path/to/include
DEFINE SYNTHESIS
DEFINE WIDTH=32
FILE /path/to/top.sv
FILE /path/to/core.sv
RESET
FILE /path/to/other_top.sv
```

`RESET` starts a new compilation unit in batch mode. Include directories and
defines are part of the AST, so repeat them after `RESET` if each file should
be parsed independently. Blank lines and lines beginning with `#` or `//` are
ignored.

Generate a response file from a directory or simulator-style filelist:

```sh
scripts/make_response.py rtl/ --include rtl/include --out /tmp/rtl.resp
scripts/make_response.py --filelist build/rtl/filelist.f --out /tmp/soc.resp
scripts/make_response.py rtl/ --reset --out /tmp/per_file.resp
```

## Modes

```sh
build/svbench /tmp/soc.resp          # batch parse
build/svbench --time /tmp/soc.resp   # preprocess + parse phase timings
build/svbench --lex /tmp/soc.resp    # raw lexer throughput
```

Batch mode prints `TRY <file>` before each parse and a final
`OK modules=... packages=... interfaces=...`. It exits on the first error, like
a compiler.

Timed mode reads all sources once, then reports:

- `pp=` preprocessing/lexing time
- `parse=` AST construction time
- `tokens=` preprocessed token count
- `arena=` total arena bytes used
- `pp_alloc=` bytes used by the token/source stream
- `parse_alloc=` bytes used by AST nodes and arrays

Lex mode reports raw lexer tokens and time only.

Use `scripts/run_chunks.py` to avoid one bad file aborting a large corpus run:

```sh
scripts/run_chunks.py /tmp/soc.resp --svbench build/svbench --chunk 200
```

## Corpus links

The repositories used for parser testing are listed in
`.references/sv-test-repos.txt`. Large datasets:

- HighTide: <https://github.com/VLSIDA/HighTide>
- OpenROAD-flow-scripts: <https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts>
- SCORE: <https://github.com/SCORE-CIRCUITS/score>
- XiangShan: <https://github.com/OpenXiangShan/XiangShan>
- VerilogDB: <https://huggingface.co/datasets/Rohan-code/Verilog_DB_read>
- OpenRTLSet: <https://huggingface.co/datasets/ESCAD/OpenRTLSet>
- OpenCores corpus: <https://github.com/stefanpie/hardware-design-dataset-opencores>
