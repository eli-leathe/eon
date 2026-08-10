(comment) @comment

(string) @string
(character) @character
(number) @number

(identifier) @variable
(declaration name: (identifier) @property)
(field_expression field: (identifier) @property)

[
  "and"
  "or"
] @keyword.operator

[
  "="
  "=="
  "+"
  "-"
  "*"
  "/"
] @operator

[
  "("
  ")"
  "{"
  "}"
] @punctuation.bracket

[
  "."
  ";"
] @punctuation.delimiter
