-- :GitGood dispatcher. Routes subcommands to lazily-required modules.
local M = {}

-- subcommand -> handler. Handlers require their module on demand (lazy load).
local handlers = {
  prs = function()
    require("gitgood.ui.list").open()
  end,
  pr = function(args)
    local n = tonumber(args[1])
    if not n then
      return vim.notify("gitgood: :GitGood pr <number>", vim.log.levels.WARN)
    end
    require("gitgood.ui.pr").open(n)
  end,
  create = function()
    require("gitgood.ui.pr").create()
  end,
  submit = function()
    require("gitgood.review").submit_current()
  end,
}

-- Default (no subcommand) opens the PR list.
local function default()
  require("gitgood.ui.list").open()
end

function M.dispatch(opts)
  local fargs = opts.fargs or {}
  local sub = fargs[1]
  if not sub then
    return default()
  end
  local handler = handlers[sub]
  if not handler then
    return vim.notify("gitgood: unknown subcommand '" .. sub .. "'", vim.log.levels.ERROR)
  end
  local rest = { unpack(fargs, 2) }
  local ok, err = pcall(handler, rest)
  if not ok then
    vim.notify("gitgood: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.complete(arglead, _cmdline, _cursorpos)
  local subs = vim.tbl_keys(handlers)
  table.sort(subs)
  return vim.tbl_filter(function(s)
    return s:find(arglead, 1, true) == 1
  end, subs)
end

return M
