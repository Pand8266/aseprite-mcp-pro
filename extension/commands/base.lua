-- Base command helpers for Aseprite MCP Pro
local M = {}

--- Return a success result
---@param data table|nil
---@return table
function M.success(data)
  return { result = data or {} }
end

--- Return an error result
---@param code number JSON-RPC error code
---@param message string Error message
---@param data table|nil Additional error data
---@return table
function M.error(code, message, data)
  local err = { code = code, message = message }
  if data then err.data = data end
  return { error = err }
end

--- No sprite open error
---@return table
function M.error_no_sprite()
  return M.error(-32000, "No sprite is open", {
    suggestion = "Use create_sprite or open_sprite first"
  })
end

--- Invalid parameters error
---@param message string
---@return table
function M.error_invalid_params(message)
  return M.error(-32602, message)
end

--- Layer not found error
---@param name string
---@return table
function M.error_layer_not_found(name)
  return M.error(-32001, "Layer not found: " .. tostring(name))
end

--- Tag not found error
---@param name string
---@return table
function M.error_tag_not_found(name)
  return M.error(-32002, "Tag not found: " .. tostring(name))
end

--- Require a string parameter
---@param params table
---@param key string
---@return string|nil, table|nil
function M.require_string(params, key)
  local val = params[key]
  if val == nil or type(val) ~= "string" or val == "" then
    return nil, M.error_invalid_params("Missing required string parameter: " .. key)
  end
  return val, nil
end

--- Require a number parameter
---@param params table
---@param key string
---@return number|nil, table|nil
function M.require_number(params, key)
  local val = params[key]
  if val == nil or type(val) ~= "number" then
    return nil, M.error_invalid_params("Missing required number parameter: " .. key)
  end
  return val, nil
end

--- Get optional string with default
---@param params table
---@param key string
---@param default_val string|nil
---@return string
function M.optional_string(params, key, default_val)
  local val = params[key]
  if val ~= nil and type(val) == "string" then return val end
  return default_val
end

--- Get optional number with default
---@param params table
---@param key string
---@param default_val number|nil
---@return number|nil
function M.optional_number(params, key, default_val)
  local val = params[key]
  if val ~= nil and type(val) == "number" then return val end
  return default_val
end

--- Get optional boolean with default
---@param params table
---@param key string
---@param default_val boolean
---@return boolean
function M.optional_bool(params, key, default_val)
  local val = params[key]
  if val ~= nil and type(val) == "boolean" then return val end
  return default_val
end

--- Get the active sprite or return an error
---@return Sprite|nil, table|nil
function M.get_sprite()
  local sprite = app.sprite
  if not sprite then
    return nil, M.error_no_sprite()
  end
  return sprite, nil
end

--- Find a layer by name in the sprite
---@param sprite Sprite
---@param name string
---@return Layer|nil
function M.find_layer(sprite, name)
  for _, layer in ipairs(sprite.layers) do
    if layer.name == name then return layer end
    -- Search in groups recursively
    if layer.isGroup then
      local found = M._find_layer_in_group(layer, name)
      if found then return found end
    end
  end
  return nil
end

--- Recursive layer search in group
function M._find_layer_in_group(group, name)
  for _, layer in ipairs(group.layers) do
    if layer.name == name then return layer end
    if layer.isGroup then
      local found = M._find_layer_in_group(layer, name)
      if found then return found end
    end
  end
  return nil
end

--- Find a tag by name
---@param sprite Sprite
---@param name string
---@return Tag|nil
function M.find_tag(sprite, name)
  for _, tag in ipairs(sprite.tags) do
    if tag.name == name then return tag end
  end
  return nil
end

--- Get the target layer (by name or active)
---@param sprite Sprite
---@param params table
---@return Layer|nil, table|nil
function M.get_target_layer(sprite, params)
  local layer_name = params.layer
  if layer_name then
    local layer = M.find_layer(sprite, layer_name)
    if not layer then
      return nil, M.error_layer_not_found(layer_name)
    end
    return layer, nil
  end
  return app.layer, nil
end

--- Get the target frame (by number or active)
---@param sprite Sprite
---@param params table
---@return Frame|nil, table|nil
function M.get_target_frame(sprite, params)
  local frame_num = params.frame
  if frame_num then
    if frame_num < 1 or frame_num > #sprite.frames then
      return nil, M.error_invalid_params(
        string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
    end
    return sprite.frames[frame_num], nil
  end
  return app.frame, nil
end

--- Wrap a function in an Aseprite transaction for undo support
---@param name string Transaction description
---@param fn function
---@return any
function M.transaction(name, fn)
  app.transaction(name, fn)
end

return M
