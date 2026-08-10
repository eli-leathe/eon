# tree-sitter-eon

A [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for Eon.
The generated C parser is checked in at `src/parser.c`; syntax highlighting
queries are in `queries/highlights.scm`.

Regenerate and test the parser with Tree-sitter 0.26 or newer:

```sh
tree-sitter generate
tree-sitter test
```
