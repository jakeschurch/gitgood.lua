if exists("b:current_syntax") | finish | endif

syntax match gitgoodHeader   /^gitgood:.*$/
syntax match gitgoodSection  /^ \a.*(\d\+)$/
syntax match gitgoodPRNum    /#\d\+/
syntax match gitgoodAdd      /+\d\+/
syntax match gitgoodDel      /-\d\+/
syntax match gitgoodPass     /✓/
syntax match gitgoodFail     /✗/
syntax match gitgoodDraft    /● draft/
syntax match gitgoodHint     /^ g?.*$/

highlight default link gitgoodHeader  Title
highlight default link gitgoodSection Statement
highlight default link gitgoodPRNum   Identifier
highlight default link gitgoodAdd     DiffAdd
highlight default link gitgoodDel     DiffDelete
highlight default link gitgoodPass    DiffAdd
highlight default link gitgoodFail    DiffDelete
highlight default link gitgoodDraft   Special
highlight default link gitgoodHint    Comment

let b:current_syntax = "gitgood-list"
