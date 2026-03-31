local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    get_cel = M.get_cel,
    set_cel_position = M.set_cel_position,
    set_cel_opacity = M.set_cel_opacity,
    clear_cel = M.clear_cel,
    link_cels = M.link_cels,
  }
end

function M.get_cel(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, err2 = base.require_string(params, "layer")
  if err2 then return err2 end
  local frame_num, err3 = base.require_number(params, "frame")
  if err3 then return err3 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end

  local cel = layer:cel(frame_num)
  if not cel then
    return base.success({
      exists = false,
      layer = layer_name,
      frame = frame_num,
    })
  end

  return base.success({
    exists = true,
    layer = layer_name,
    frame = frame_num,
    x = cel.position.x,
    y = cel.position.y,
    opacity = cel.opacity,
    image_width = cel.image.width,
    image_height = cel.image.height,
  })
end

function M.set_cel_position(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, err2 = base.require_string(params, "layer")
  if err2 then return err2 end
  local frame_num, err3 = base.require_number(params, "frame")
  if err3 then return err3 end
  local x, err4 = base.require_number(params, "x")
  if err4 then return err4 end
  local y, err5 = base.require_number(params, "y")
  if err5 then return err5 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end

  local cel = layer:cel(frame_num)
  if not cel then
    return base.error(-32001, string.format("No cel at layer '%s' frame %d", layer_name, frame_num))
  end

  app.transaction("Set Cel Position", function()
    cel.position = Point(x, y)
  end)

  return base.success({ layer = layer_name, frame = frame_num, x = x, y = y })
end

function M.set_cel_opacity(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, err2 = base.require_string(params, "layer")
  if err2 then return err2 end
  local frame_num, err3 = base.require_number(params, "frame")
  if err3 then return err3 end
  local opacity, err4 = base.require_number(params, "opacity")
  if err4 then return err4 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end

  local cel = layer:cel(frame_num)
  if not cel then
    return base.error(-32001, string.format("No cel at layer '%s' frame %d", layer_name, frame_num))
  end

  app.transaction("Set Cel Opacity", function()
    cel.opacity = math.floor(math.max(0, math.min(255, opacity)))
  end)

  return base.success({ layer = layer_name, frame = frame_num, opacity = cel.opacity })
end

function M.clear_cel(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, err2 = base.require_string(params, "layer")
  if err2 then return err2 end
  local frame_num, err3 = base.require_number(params, "frame")
  if err3 then return err3 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end

  local cel = layer:cel(frame_num)
  if cel then
    app.transaction("Clear Cel", function()
      sprite:deleteCel(cel)
    end)
  end

  return base.success({ layer = layer_name, frame = frame_num, cleared = true })
end

function M.link_cels(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, err2 = base.require_string(params, "layer")
  if err2 then return err2 end
  local from_frame, err3 = base.require_number(params, "from_frame")
  if err3 then return err3 end
  local to_frame, err4 = base.require_number(params, "to_frame")
  if err4 then return err4 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end

  app.layer = layer
  app.range.frames = {}
  for i = from_frame, to_frame do
    if i >= 1 and i <= #sprite.frames then
      app.range.frames[#app.range.frames + 1] = sprite.frames[i]
    end
  end
  app.command.LinkCels()

  return base.success({
    layer = layer_name,
    from_frame = from_frame,
    to_frame = to_frame,
    linked = true,
  })
end

return M
