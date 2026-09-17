" Vim syntax file
" Language: Macros (MicrOS programming language)
" Maintainer: MicrOS AI Agent Protocol
" Latest Revision: 2026-09-16

if exists("b:current_syntax")
  finish
endif

" Keywords
syn keyword macrosKeyword fn if else while return
syn keyword macrosBoolean true false nil

" Built-in Functions
syn keyword macrosBuiltin print println len push substr load import

" Comments
syn match macrosComment "//.*$" contains=macrosTodo
syn keyword macrosTodo TODO FIXME NOTE XXX contained

" Literals
syn match macrosNumber "\<\d\+\>"
syn region macrosString start=/"/ skip=/\\\\\|\\"/ end=/"/

" Operators and Punctuation
syn match macrosOperator "[-+*/=><!]"
syn match macrosDelimiter "[()[\]{}]"

" Highlighting Links
hi def link macrosKeyword Keyword
hi def link macrosBoolean Boolean
hi def link macrosBuiltin Function
hi def link macrosComment Comment
hi def link macrosTodo Todo
hi def link macrosNumber Number
hi def link macrosString String
hi def link macrosOperator Operator
hi def link macrosDelimiter Delimiter

let b:current_syntax = "macros"
