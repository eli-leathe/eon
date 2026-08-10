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

## Plan

I intend to use this as a base to try a few different things:

- Compile to IR + tree graph + dependencies
  - i don't like the interpreter, use IR
  - Don't recompute everything when a value changes, only what is needed

- "Temporal logic": a declaration is a circular buffer of the last few values, you can access them and do some cool stuff (a research thing, it can fail completly)
  For instance:

```eon
try_jump = rise (input "space")
jump_buffer_time = 100ms
jump = take jump_buffer_time try_jump
       when once coyote_grace_period grounded
```

`rise`: detect rising edge
`take dur`: consume the last non expired event (expires after `dur`)
`when`: if
`once dur cond`: returns true if cond was true before (duration given by dur)

This implements coyote time, input buffering in a few lines! quite good no?

## Slop disclosure

I use AI, mainly for the stuff that is secondary and not that important, like the test suite, tree-sitter, the vim syntax, etc.
The core is not AI-generated though and i don't plan to use AI, except to assist in some boring stuff (with thorough code review and more)
(the cli is slop though, but i intend to clean that soon)
