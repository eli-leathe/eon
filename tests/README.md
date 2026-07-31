# Parser and tokenizer snapshots

Each `cases/*.temporal` file is tokenized and parsed. The generated snapshot records token tags, byte ranges and text, followed by the AST as an S-expression or parse errors.

Run the complete suite:

```sh
zig build test
```

The test generates a fresh snapshot in Zig's cache and compares it with `snapshots/parser-tokenizer.snap` using `git diff --no-index`. It does not modify the accepted snapshot.

After reviewing an intentional change, accept it with:

```sh
zig build update-snapshots
git diff -- tests/snapshots/parser-tokenizer.snap
```

Adding another `.temporal` file to `cases/` automatically adds it to the aggregate snapshot.
