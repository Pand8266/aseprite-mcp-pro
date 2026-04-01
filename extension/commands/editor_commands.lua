local base = require("commands.base")
local M = {}

function M.get_commands()
  return {
    execute_script = M.execute_script,
    undo = M.undo,
    redo = M.redo,
  }
end

function M.execute_script(params)
  local code, err = base.require_string(params, "code")
  if err then return err end

  -- Execute arbitrary Lua code in Aseprite's scripting environment
  local fn, load_err = load(code, "mcp_script", "t")
  if not fn then
    return base.error(-32603, "Lua compile error: " .. tostring(load_err))
  end

  local ok, result = pcall(fn)
  if not ok then
    return base.error(-32603, "Lua runtime error: " .. tostring(result))
  end

  -- If the script returns a value, include it
  if result ~= nil then
    if type(result) == "table" then
      return base.success(result)
    else
      return base.success({ result = tostring(result) })
    end
  end

  return base.success({ executed = true })
end

function M.undo(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local steps = base.optional_number(params, "steps", 1)
  for i = 1, steps do
    app.command.Undo()
  end

  return base.success({ undone = steps })
end

function M.redo(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local steps = base.optional_number(params, "steps", 1)
  for i = 1, steps do
    app.command.Redo()
  end

  return base.success({ redone = steps })
end

return M
