# femtolane

A performant, simple *physical design tool* to convert your RTL (Register-Transfer Level) design to an OASIS (Open Artwork System Interchange Standard) binary.

Will be written in Odin with no dependencies except odin stdlib, and *maybe* `vendor:raylib` for the rendering since it handles platform specific rendering.
Platform native, statically linked binaries will be shipped for frictionless use.

Meant to be a more performant and simpler alternative to:
1. [OpenROAD](https://github.com/The-OpenROAD-Project/OpenROAD)
2. [Cadence Genus/Innovus](https://www.cadence.com/en_US/home/resources/white-papers/innovus-plus-synthesis-implementation-system-wp.html)
3. [Synopsys Design Compiler](https://www.synopsys.com/content/dam/synopsys/implementation&signoff/datasheets/design-compiler-nxt-ds.pdf)

## Usage (Download a release or build from source)

### 1. Download

We will ship binaries for all major operating systems (windows, linux/unix based OSes, macOS) once the software is in alpha stage

### 2. From source (if you would like to inspect the code / run experiments or make changes)

- To build the project you will need the Odin compiler and stdlib.
- You can install it by following the instuctions on [Odin's Official Website](https://odin-lang.org/docs/install/)
- Once Odin is installed you can either run the program by running `odin run src` or build it using `odin build src` (both from repository root)
- On Linux, you need to explicitly pass a linker flag for dbus like `--extra-linker-flags:"-ldbus-1"` since that is what we use to show native file dialogs. (eg. `odin run src --extra-linker-flags:"-ldbus-1"` / `odin build src --extra-linker-flags:"-ldbus-1"`)

## Codebase Naming / Styling Conventions

1. Constants are all caps with `_` for spaces like `EXAMPLE_CONSTANT`
2. Functions are all lowercase with `_` spaces like `example_function`
3. Variables are all lowercase with `_` spaces like `example_var` (same as functions)
4. Filenames are all lowercase with `_` like `example_file.odin`
5. Spaces between operators like `c = a + b` and not `c=a+b`
6. Types capitalize each word with no underscore like `MyType`
7. Don't alias imports so don't import like `import ex "example"` just `import `example` (exception for name collision / super long name but unlikely cz we're low dependency)
