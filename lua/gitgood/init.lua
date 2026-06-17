-- Public entry. Users call require("gitgood").setup{...} in their config.
local M = {}

function M.setup(opts)
  require("gitgood.config").setup(opts)
end

-- Convenience re-exports so users / mappings can call high-level actions.
function M.prs(opts)
  require("gitgood.ui.list").open(opts)
end

function M.pr(number)
  require("gitgood.ui.pr").open(number)
end

return M
