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
./zig-out/bin/eon --get=server.workers config.eon
# 8
```

Format a file to standard output:

```sh
./zig-out/bin/eon --format config.eon
```

Other commands and options are listed by:

```sh
./zig-out/bin/eon --help
```

Run the test suite with `zig build test`.
