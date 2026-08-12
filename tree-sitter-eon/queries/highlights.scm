(comment) @comment

(string) @string
(character) @character
(number) @number
(boolean) @boolean

(identifier) @variable
(declaration name: (identifier) @property)
(field_expression field: (identifier) @property)
(atom name: (identifier) @constant)

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
  "["
  "]"
] @punctuation.bracket

[
  "."
  ";"
  ","
] @punctuation.delimiter
