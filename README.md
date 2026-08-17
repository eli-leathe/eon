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

Values can refer to other values, including sibling fields, values in enclosing
records, and nested fields. Bare identifiers are resolved from the innermost
record outward:

```eon
base_timeout = 15

production = {
  timeout = base_timeout * 2
  retry_delay = timeout / 3
  endpoint = "api.example.com"
}

selected_timeout = production.timeout
```

Eon currently supports strings, characters, numbers, booleans, atoms, arrays,
nested records, field access, function application, arithmetic, equality, and
boolean operators. Atoms use Zig-style enum literal syntax: `.ready` is the atom
`"ready"`.
Line comments start with `//`. Keywords can be used as identifiers with Zig-style
quoting, such as `@"if" = 1`.

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

Embedded applications can generate key/value documents with `eon.Emit.emit`,
passing a slice of `eon.Emit.Field` values and an `std.Io.Writer`.

Applications can also provide host functions with
`eon.Interpreter.initWithBindings`. A host function receives a `TreeCursor`, so
its argument can be a scalar, record, or array. It returns a scalar Eon value,
and any evaluation error it returns is propagated to the caller. For example,
the Eon expression:

```eon
speed = dragFloat { value = 5; start = 0; end = 100; scale = .log }
```

can be embedded as:

```zig
const Interpreter = eon.Interpreter;

fn dragFloat(_: ?*anyopaque, argument: Interpreter.TreeCursor) Interpreter.EvaluationError!Interpreter.Value {
    const options = try argument.map();
    return switch (try (try options.field("value")).value()) {
        .number => |number| .{ .number = number },
        else => error.UnexpectedType,
    };
}

const bindings = [_]Interpreter.Binding{.{
    .name = "dragFloat",
    .value = .{ .function = .{ .call_fn = dragFloat } },
}};
var interpreter = Interpreter.initWithBindings(allocator, ast, &bindings);
```

This allows an embedding layer to retain UI metadata while exposing the
function's numeric result to configuration consumers.

Semantic edits can be rendered through three tree views:

- `eon.Tree.Parsed` wraps the parsed AST and its source locations.
- `eon.Tree.Virtual` contains synthesized nodes with no source locations.
- `eon.Tree.Merge` mounts virtual subtrees over parsed nodes while retaining
  the parsed mount points as formatting and comment anchors.

For example, a parsed expression can be replaced without mutating its AST:

```zig
var parsed = eon.Tree.Parsed{ .ast = &ast };
var virtual: eon.Tree.Virtual = .{};
defer virtual.deinit(allocator);
const replacement = try virtual.addValue(allocator, .{ .number = 42.5 });
virtual.setRoot(replacement);

var merged = eon.Tree.Merge.init(parsed.reader(), virtual.reader());
defer merged.deinit(allocator);
try merged.mount(allocator, parsed.nodeFromRef(value_node), virtual.nodeFromRef(replacement));
try eon.Format.renderTree(merged.reader(), writer);
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
