-- Coroutine-based async core. No plenary dependency.
--
-- Usage:
--   async.run(function()
--     local out = async.system({ "gh", "pr", "list", "--json", "number" })
--     local a, b = unpack(async.join({ thunkA, thunkB }))   -- parallel
--   end)
--
-- A "thunk" is `function(resume) ... resume(value) end`. await() yields one;
-- run() drives the coroutine, feeding resume() values back in.
local M = {}

-- Drive `fn` (a coroutine body) to completion. on_err handles uncaught errors.
function M.run(fn, on_err)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, thunk = coroutine.resume(co, ...)
    if not ok then
      local handler = on_err
        or function(e)
          vim.notify("gitgood: " .. tostring(e), vim.log.levels.ERROR)
        end
      return handler(thunk)
    end
    if type(thunk) == "function" then
      thunk(step)
    end
  end
  step()
end

-- Yield a thunk; returns whatever the thunk passes to resume().
function M.await(thunk)
  return coroutine.yield(thunk)
end

-- A thunk wrapping vim.system; resumes on the main loop with {code,stdout,stderr}.
function M.system_thunk(cmd, opts)
  return function(resume)
    vim.system(cmd, opts or { text = true }, function(out)
      vim.schedule(function()
        resume(out)
      end)
    end)
  end
end

-- Await a single system command.
function M.system(cmd, opts)
  return M.await(M.system_thunk(cmd, opts))
end

-- Await many thunks in parallel; returns results array in original order.
function M.join(thunks)
  if #thunks == 0 then
    return {}
  end
  return M.await(function(resume)
    local results, remaining = {}, #thunks
    for i, t in ipairs(thunks) do
      t(function(r)
        results[i] = r
        remaining = remaining - 1
        if remaining == 0 then
          resume(results)
        end
      end)
    end
  end)
end

return M
