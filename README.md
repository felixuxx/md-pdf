# md-pdf

A small CLI tool that converts Markdown files to PDF. Written in Zig.

## Usage

```bash
md_pdf <input.md> [output.pdf]
```

- **`input.md`** — Path to the Markdown file to convert.
- **`output.pdf`** — Optional. If omitted, the output path is derived from the input (e.g. `doc.md` → `doc.pdf`).

## Build

```bash
zig build
```

The binary is installed to `zig-out/bin/md_pdf`.

Run directly:

```bash
zig build run -- path/to/file.md
```

Run tests:

```bash
zig build test
```

## Requirements

- [Zig](https://ziglang.org/) (check `build.zig.zon` for the version used by this project).
