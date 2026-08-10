# Eon

Eon is a small expression language for writing configuration files. It aims to
keep configuration readable like plain data while allowing values to be derived
from other values when a little computation is useful.

## Objectives

- Keep configuration files concise and easy for humans to read and edit.
- Support nested records, references, and simple expressions without becoming a
  general-purpose scripting language.
- Provide useful parse errors and deterministic formatting.
- Be easy to embed, with applications supplying their own values and functions.

## Examples

A basic configuration:

```eon
name = "demo"
cores = 4

server = {
  host = "localhost"
  port = 8080
  workers = cores * 2
}
```

Values can refer to other values, including nested fields:

```eon
base = {
  timeout = 15
}

production = {
  timeout = base.timeout * 2
  endpoint = "api.example.com"
}

selected_timeout = production.timeout
```

Eon currently supports strings, characters, numbers, nested records, field
access, function application, arithmetic, equality, and boolean operators.
Line comments start with `//`.

## Using the CLI

Build Eon with Zig:

```sh
zig build
```

Read a value from a configuration file:

```sh
./zig-out/bin/eon get server.workers config.eon
# 8
```

Format a file to standard output, or update it in place with `-w`:

```sh
./zig-out/bin/eon format config.eon
./zig-out/bin/eon format -w config.eon
```

Validate a file without producing output:

```sh
./zig-out/bin/eon check config.eon
```

Other commands are listed by:

```sh
./zig-out/bin/eon help
```

## Editor support

Vim file detection and syntax highlighting live in `editors/vim`. Copy that
directory's contents into `~/.vim`, or add it to Vim's runtime path.

A Tree-sitter grammar, generated C parser, highlighting queries, and corpus
tests live in `tree-sitter-eon`. From that directory, run `tree-sitter test`
to test the grammar.

Run the Eon test suite with `zig build test`.
