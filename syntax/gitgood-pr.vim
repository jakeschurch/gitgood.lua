if exists("b:current_syntax") | finish | endif

syntax match gitgoodHeader   /^gitgood:.*$/
syntax match gitgoodSection  /^ \a[^─]*─\+$/
syntax match gitgoodPRNum    /#\d\+/
syntax match gitgoodAdd      /+\d\+/
syntax match gitgoodDel      /-\d\+/
syntax match gitgoodExpanded /^   ▾ /
syntax match gitgoodCollapsed /^   ▸ /
" inline-expanded hunk lines
syntax match gitgoodHunk     /^     @@ .*$/
syntax match gitgoodDiffAdd  /^   +  .*$/
syntax match gitgoodDiffDel  /^   -  .*$/
syntax match gitgoodHint     /^ <CR>.*$/

highlight default link gitgoodHeader    Title
highlight default link gitgoodSection   Statement
highlight default link gitgoodPRNum     Identifier
highlight default link gitgoodAdd       DiffAdd
highlight default link gitgoodDel       DiffDelete
highlight default link gitgoodExpanded  Special
highlight default link gitgoodCollapsed Comment
highlight default link gitgoodHunk      DiffChange
highlight default link gitgoodDiffAdd   DiffAdd
highlight default link gitgoodDiffDel   DiffDelete
highlight default link gitgoodHint      Comment

let b:current_syntax = "gitgood-pr"
