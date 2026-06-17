-- Drill-in / back navigation stack (fugitive's <CR> deeper, `-` back).
-- Each entry is a render closure; `back` re-runs the previous one.
local M = {}

local stack = {}

-- Start a fresh navigation rooted at `render`.
function M.reset(render)
  stack = { render }
  render()
end

-- Drill into a new view.
function M.go(render)
  table.insert(stack, render)
  render()
end

-- Pop current view and re-render the previous one. No-op at the root.
function M.back()
  if #stack <= 1 then
    return
  end
  table.remove(stack)
  stack[#stack]()
end

return M
