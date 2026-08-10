" Vim syntax file
" Language: Eon

if exists("b:current_syntax")
  finish
endif

syntax case match

syntax keyword eonBoolean true false
syntax keyword eonConditional if
syntax keyword eonOperator and or not
syntax keyword eonTodo TODO FIXME XXX NOTE contained

syntax match eonComment "//.*$" contains=eonTodo,@Spell
syntax region eonString start=+"+ end=+"+ oneline
syntax region eonCharacter start=+'+ end=+'+ oneline
syntax match eonNumber "\<\d[[:alnum:]_]*\%\(\.[[:alnum:]_]\+\)\?\>"
syntax match eonIdentifier '@"[^"[:cntrl:]]\+"'
syntax match eonKey "\<[A-Za-z_][A-Za-z0-9_]*\>\ze\s*="
syntax match eonOperator "==\|[+*/-]"
syntax match eonDelimiter "[{}()[\];,.]"

highlight default link eonBoolean Boolean
highlight default link eonCharacter Character
highlight default link eonComment Comment
highlight default link eonConditional Conditional
highlight default link eonDelimiter Delimiter
highlight default link eonIdentifier Identifier
highlight default link eonKey Identifier
highlight default link eonNumber Number
highlight default link eonOperator Operator
highlight default link eonString String
highlight default link eonTodo Todo

let b:current_syntax = "eon"
