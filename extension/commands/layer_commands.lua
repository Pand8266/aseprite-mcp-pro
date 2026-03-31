local base = require("commands.base")
local M = {}

function M.get_commands()
  return {
    get_layers = M.get_layers,
    add_layer = M.add_layer,
    delete_layer = M.delete_layer,
    rename_layer = M.rename_layer,
    set_layer_visibility = M.set_layer_visibility,
    set_layer_opacity = M.set_layer_opacity,
    set_layer_blend_mode = M.set_layer_blend_mode,
    reorder_layer = M.reorder_layer,
    duplicate_layer = M.duplicate_layer,
    merge_layer_down = M.merge_layer_down,
  }
end

local function layer_info(layer, depth)
  depth = depth or 0
  local info = {
    name = layer.name,
    type = layer.isGroup and "group" or (layer.isTilemap and "tilemap" or "normal"),
    visible = layer.isVisible,
    opacity = layer.opacity,
    blend_mode = tostring(layer.blendMode),
    stack_index = layer.stackIndex,
    depth = depth,
    is_editable = layer.isEditable,
    is_background = layer.isBackground,
  }

  if layer.isGroup then
    info.children = {}
    for i, child in ipairs(layer.layers) do
      info.children[i] = layer_info(child, depth + 1)
    end
  end

  return info
end

function M.get_layers(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layers = {}
  for i, layer in ipairs(sprite.layers) do
    layers[i] = layer_info(layer)
  end

  return base.success({
    layers = layers,
    count = #sprite.layers,
    active_layer = app.layer and app.layer.name or nil,
  })
end

function M.add_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name = base.optional_string(params, "name", nil)
  local layer_type = base.optional_string(params, "type", "normal")

  local layer
  app.transaction("Add Layer", function()
    if layer_type == "group" then
      layer = sprite:newGroup()
    elseif layer_type == "tilemap" then
      layer = sprite:newLayer()
    else
      layer = sprite:newLayer()
    end

    if name and layer then
      layer.name = name
    end
  end)

  if not layer then
    return base.error(-32603, "Failed to create layer")
  end

  return base.success({
    name = layer.name,
    type = layer_type,
    stack_index = layer.stackIndex,
  })
end

function M.delete_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  app.transaction("Delete Layer", function()
    sprite:deleteLayer(layer)
  end)

  return base.success({ deleted = name })
end

function M.rename_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end
  local new_name, err3 = base.require_string(params, "new_name")
  if err3 then return err3 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  app.transaction("Rename Layer", function()
    layer.name = new_name
  end)

  return base.success({ old_name = name, new_name = new_name })
end

function M.set_layer_visibility(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  local visible = params.visible
  if type(visible) ~= "boolean" then
    return base.error_invalid_params("Missing required boolean parameter: visible")
  end

  app.transaction("Set Layer Visibility", function()
    layer.isVisible = visible
  end)

  return base.success({ name = name, visible = visible })
end

function M.set_layer_opacity(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end
  local opacity, err3 = base.require_number(params, "opacity")
  if err3 then return err3 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  app.transaction("Set Layer Opacity", function()
    layer.opacity = math.floor(math.max(0, math.min(255, opacity)))
  end)

  return base.success({ name = name, opacity = layer.opacity })
end

function M.set_layer_blend_mode(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end
  local mode_str, err3 = base.require_string(params, "blend_mode")
  if err3 then return err3 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  local modes = {
    normal = BlendMode.NORMAL,
    multiply = BlendMode.MULTIPLY,
    screen = BlendMode.SCREEN,
    overlay = BlendMode.OVERLAY,
    darken = BlendMode.DARKEN,
    lighten = BlendMode.LIGHTEN,
    color_dodge = BlendMode.COLOR_DODGE,
    color_burn = BlendMode.COLOR_BURN,
    hard_light = BlendMode.HARD_LIGHT,
    soft_light = BlendMode.SOFT_LIGHT,
    difference = BlendMode.DIFFERENCE,
    exclusion = BlendMode.EXCLUSION,
    hue = BlendMode.HSL_HUE,
    saturation = BlendMode.HSL_SATURATION,
    color = BlendMode.HSL_COLOR,
    luminosity = BlendMode.HSL_LUMINOSITY,
    addition = BlendMode.ADDITION,
    subtract = BlendMode.SUBTRACT,
    divide = BlendMode.DIVIDE,
  }

  local mode = modes[mode_str]
  if not mode then
    return base.error_invalid_params("Unknown blend mode: " .. mode_str)
  end

  app.transaction("Set Blend Mode", function()
    layer.blendMode = mode
  end)

  return base.success({ name = name, blend_mode = mode_str })
end

function M.reorder_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end
  local stack_index, err3 = base.require_number(params, "stack_index")
  if err3 then return err3 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  app.transaction("Reorder Layer", function()
    layer.stackIndex = math.floor(stack_index)
  end)

  return base.success({ name = name, stack_index = layer.stackIndex })
end

function M.duplicate_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  app.layer = layer
  app.command.DuplicateLayer()

  local new_layer = app.layer
  local new_name = base.optional_string(params, "new_name", nil)
  if new_name and new_layer then
    app.transaction("Rename Duplicated Layer", function()
      new_layer.name = new_name
    end)
  end

  return base.success({
    name = new_layer and new_layer.name or "unknown",
    stack_index = new_layer and new_layer.stackIndex or 0,
  })
end

function M.merge_layer_down(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, err2 = base.require_string(params, "name")
  if err2 then return err2 end

  local layer = base.find_layer(sprite, name)
  if not layer then return base.error_layer_not_found(name) end

  app.layer = layer
  app.command.MergeDownLayer()

  return base.success({ merged = name })
end

return M
