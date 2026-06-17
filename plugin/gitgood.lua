-- gitgood.lua — entry point. Keep this cheap: define the command + nothing else.
-- Heavy modules are require()'d lazily on first :GitGood invocation.
if vim.g.loaded_gitgood then
  return
end
vim.g.loaded_gitgood = true

local opts = {
  nargs = "*",
  desc = "gitgood: review pull requests",
  complete = function(arglead, cmdline, cursorpos)
    return require("gitgood.commands").complete(arglead, cmdline, cursorpos)
  end,
}
local function dispatch(o)
  require("gitgood.commands").dispatch(o)
end

vim.api.nvim_create_user_command("GitGood", dispatch, opts)
vim.api.nvim_create_user_command("GG", dispatch, opts) -- alias
