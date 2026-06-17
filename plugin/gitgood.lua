-- gitgood.lua — entry point. Keep this cheap: define the command + nothing else.
-- Heavy modules are require()'d lazily on first :GitGood invocation.
if vim.g.loaded_gitgood then
  return
end
vim.g.loaded_gitgood = true

vim.api.nvim_create_user_command("GitGood", function(opts)
  require("gitgood.commands").dispatch(opts)
end, {
  nargs = "*",
  desc = "gitgood: review pull requests",
  complete = function(arglead, cmdline, cursorpos)
    return require("gitgood.commands").complete(arglead, cmdline, cursorpos)
  end,
})
