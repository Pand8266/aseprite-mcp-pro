----------------------------------------------------------------------
-- Aseprite MCP Pro - Plugin (Single-File Merged Build)
-- WebSocket client that connects to the MCP server and dispatches
-- JSON-RPC commands to Lua command handlers.
-- All command modules, utilities, and base helpers are inlined here
-- to avoid multiple security permission dialogs.
----------------------------------------------------------------------

-- Base64 encoder/decoder (global, used by command handlers at runtime)
local _base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_G.MCP_BASE64 = {
  encode = function(data)
    return ((data:gsub(".", function(x)
      local r, b2 = "", x:byte()
      for i = 8, 1, -1 do
        r = r .. (b2 % 2 ^ i - b2 % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
      if #x < 6 then return "" end
      local c = 0
      for i = 1, 6 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
      end
      return _base64_chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
  end,
  decode = function(data)
    data = string.gsub(data, "[^" .. _base64_chars .. "=]", "")
    return (data:gsub(".", function(x)
      if x == "=" then return "" end
      local r, f = "", (_base64_chars:find(x) - 1)
      for i = 6, 1, -1 do
        r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
      if #x ~= 8 then return "" end
      local c = 0
      for i = 1, 8 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
      end
      return string.char(c)
    end))
  end,
}

-- Configuration
local DEFAULT_PORT = 6515
local RECONNECT_INTERVAL_MS = 3000
local VERSION = "1.0.0"

-- State
local ws = nil
local connected = false
local handlers = {}
local reconnect_timer = nil
local port = DEFAULT_PORT

----------------------------------------------------------------------
-- JSON (Aseprite built-in)
----------------------------------------------------------------------
local json = json

----------------------------------------------------------------------
-- Utility: Color
----------------------------------------------------------------------
local color_util = {}

function color_util.from_hex(hex)
  if not hex then return Color(0, 0, 0, 255) end
  hex = hex:gsub("^#", "")
  local r, g, b, a
  if #hex == 3 then
    r = tonumber(hex:sub(1, 1) .. hex:sub(1, 1), 16)
    g = tonumber(hex:sub(2, 2) .. hex:sub(2, 2), 16)
    b = tonumber(hex:sub(3, 3) .. hex:sub(3, 3), 16)
    a = 255
  elseif #hex == 6 then
    r = tonumber(hex:sub(1, 2), 16)
    g = tonumber(hex:sub(3, 4), 16)
    b = tonumber(hex:sub(5, 6), 16)
    a = 255
  elseif #hex == 8 then
    r = tonumber(hex:sub(1, 2), 16)
    g = tonumber(hex:sub(3, 4), 16)
    b = tonumber(hex:sub(5, 6), 16)
    a = tonumber(hex:sub(7, 8), 16)
  else
    return Color(0, 0, 0, 255)
  end
  return Color(r or 0, g or 0, b or 0, a or 255)
end

function color_util.to_hex(color, include_alpha)
  if include_alpha and color.alpha < 255 then
    return string.format("#%02X%02X%02X%02X",
      color.red, color.green, color.blue, color.alpha)
  end
  return string.format("#%02X%02X%02X",
    color.red, color.green, color.blue)
end

function color_util.pixel_to_color(pixel_value, color_mode, palette)
  if color_mode == ColorMode.RGB then
    local r = app.pixelColor.rgbaR(pixel_value)
    local g = app.pixelColor.rgbaG(pixel_value)
    local b = app.pixelColor.rgbaB(pixel_value)
    local a = app.pixelColor.rgbaA(pixel_value)
    return Color(r, g, b, a)
  elseif color_mode == ColorMode.GRAYSCALE then
    local v = app.pixelColor.grayaV(pixel_value)
    local a = app.pixelColor.grayaA(pixel_value)
    return Color(v, v, v, a)
  elseif color_mode == ColorMode.INDEXED then
    if palette and pixel_value >= 0 and pixel_value < #palette then
      return palette:getColor(pixel_value)
    end
    return Color(0, 0, 0, 0)
  end
  return Color(0, 0, 0, 255)
end

function color_util.color_to_pixel(color, color_mode, palette)
  if color_mode == ColorMode.RGB then
    return app.pixelColor.rgba(color.red, color.green, color.blue, color.alpha)
  elseif color_mode == ColorMode.GRAYSCALE then
    local v = math.floor(0.299 * color.red + 0.587 * color.green + 0.114 * color.blue)
    return app.pixelColor.graya(v, color.alpha)
  elseif color_mode == ColorMode.INDEXED then
    if palette then
      local best_idx = 0
      local best_dist = math.huge
      for i = 0, #palette - 1 do
        local pc = palette:getColor(i)
        local dr = pc.red - color.red
        local dg = pc.green - color.green
        local db = pc.blue - color.blue
        local da = pc.alpha - color.alpha
        local dist = dr * dr + dg * dg + db * db + da * da
        if dist < best_dist then
          best_dist = dist
          best_idx = i
        end
      end
      return best_idx
    end
    return 0
  end
  return 0
end

----------------------------------------------------------------------
-- Utility: Geometry
----------------------------------------------------------------------
local geometry = {}

function geometry.rect_from_params(params)
  return Rectangle(
    params.x or 0,
    params.y or 0,
    params.width or 0,
    params.height or 0
  )
end

function geometry.point_from_params(params)
  return Point(params.x or 0, params.y or 0)
end

function geometry.in_bounds(x, y, sprite)
  return x >= 0 and y >= 0 and x < sprite.width and y < sprite.height
end

function geometry.clamp_rect(rect, sprite)
  local x = math.max(0, rect.x)
  local y = math.max(0, rect.y)
  local x2 = math.min(sprite.width, rect.x + rect.width)
  local y2 = math.min(sprite.height, rect.y + rect.height)
  return Rectangle(x, y, math.max(0, x2 - x), math.max(0, y2 - y))
end

----------------------------------------------------------------------
-- Base command helpers
----------------------------------------------------------------------
local base = {}

function base.success(data)
  return { result = data or {} }
end

function base.error(code, message, data)
  local err = { code = code, message = message }
  if data then err.data = data end
  return { error = err }
end

function base.error_no_sprite()
  return base.error(-32000, "No sprite is open", {
    suggestion = "Use create_sprite or open_sprite first"
  })
end

function base.error_invalid_params(message)
  return base.error(-32602, message)
end

function base.error_layer_not_found(name)
  return base.error(-32001, "Layer not found: " .. tostring(name))
end

function base.error_tag_not_found(name)
  return base.error(-32002, "Tag not found: " .. tostring(name))
end

function base.require_string(params, key)
  local val = params[key]
  if val == nil or type(val) ~= "string" or val == "" then
    return nil, base.error_invalid_params("Missing required string parameter: " .. key)
  end
  return val, nil
end

function base.require_number(params, key)
  local val = params[key]
  if val == nil or type(val) ~= "number" then
    return nil, base.error_invalid_params("Missing required number parameter: " .. key)
  end
  return val, nil
end

function base.optional_string(params, key, default_val)
  local val = params[key]
  if val ~= nil and type(val) == "string" then return val end
  return default_val
end

function base.optional_number(params, key, default_val)
  local val = params[key]
  if val ~= nil and type(val) == "number" then return val end
  return default_val
end

function base.optional_bool(params, key, default_val)
  local val = params[key]
  if val ~= nil and type(val) == "boolean" then return val end
  return default_val
end

function base.get_sprite()
  local sprite = app.sprite
  if not sprite then
    return nil, base.error_no_sprite()
  end
  return sprite, nil
end

function base.find_layer(sprite, name)
  for _, layer in ipairs(sprite.layers) do
    if layer.name == name then return layer end
    if layer.isGroup then
      local found = base._find_layer_in_group(layer, name)
      if found then return found end
    end
  end
  return nil
end

function base._find_layer_in_group(group, name)
  for _, layer in ipairs(group.layers) do
    if layer.name == name then return layer end
    if layer.isGroup then
      local found = base._find_layer_in_group(layer, name)
      if found then return found end
    end
  end
  return nil
end

function base.find_tag(sprite, name)
  for _, tag in ipairs(sprite.tags) do
    if tag.name == name then return tag end
  end
  return nil
end

function base.get_target_layer(sprite, params)
  local layer_name = params.layer
  if layer_name then
    local layer = base.find_layer(sprite, layer_name)
    if not layer then
      return nil, base.error_layer_not_found(layer_name)
    end
    return layer, nil
  end
  return app.layer, nil
end

function base.get_target_frame(sprite, params)
  local frame_num = params.frame
  if frame_num then
    if frame_num < 1 or frame_num > #sprite.frames then
      return nil, base.error_invalid_params(
        string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
    end
    return sprite.frames[frame_num], nil
  end
  return app.frame, nil
end

function base.transaction(name, fn)
  app.transaction(name, fn)
end

----------------------------------------------------------------------
-- Sprite Commands
----------------------------------------------------------------------
local sprite_cmds = {}

function sprite_cmds.create_sprite(params)
  local width = base.optional_number(params, "width", 32)
  local height = base.optional_number(params, "height", 32)
  local color_mode_str = base.optional_string(params, "color_mode", "rgba")

  local mode = ColorMode.RGB
  if color_mode_str == "indexed" then
    mode = ColorMode.INDEXED
  elseif color_mode_str == "grayscale" then
    mode = ColorMode.GRAY
  end

  local sprite = Sprite(width, height, mode)
  if not sprite then
    return base.error(-32603, "Failed to create sprite")
  end

  return base.success({
    width = sprite.width,
    height = sprite.height,
    color_mode = tostring(sprite.colorMode),
    filename = sprite.filename,
    layers = #sprite.layers,
    frames = #sprite.frames,
  })
end

function sprite_cmds.open_sprite(params)
  local path, err = base.require_string(params, "path")
  if err then return err end

  local sprite = app.open(path)
  if not sprite then
    return base.error(-32603, "Failed to open file: " .. path)
  end

  return base.success({
    width = sprite.width,
    height = sprite.height,
    color_mode = tostring(sprite.colorMode),
    filename = sprite.filename,
    layers = #sprite.layers,
    frames = #sprite.frames,
  })
end

function sprite_cmds.save_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path = base.optional_string(params, "path", nil)
  if path then
    sprite:saveCopyAs(path)
    return base.success({ filename = path, saved_as_copy = true })
  elseif sprite.filename and sprite.filename ~= "" and sprite.filename ~= "Sprite" then
    sprite:saveAs(sprite.filename)
    return base.success({ filename = sprite.filename })
  else
    return base.error_invalid_params(
      "Sprite has no filename. Please provide a 'path' parameter to save to.")
  end
end

function sprite_cmds.close_sprite(params)
  local sprite
  local filename = base.optional_string(params, "filename", nil)

  if filename then
    for _, s in ipairs(app.sprites) do
      if s.filename == filename or s.filename:match("[/\\]" .. filename .. "$") then
        sprite = s
        break
      end
    end
    if not sprite then
      return base.error(-32001, "Sprite not found: " .. filename)
    end
  else
    sprite = app.sprite
    if not sprite then return base.error_no_sprite() end
  end

  sprite:close()
  return base.success({ closed = true })
end

function sprite_cmds.get_sprite_info(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layers_info = {}
  for i, layer in ipairs(sprite.layers) do
    layers_info[i] = {
      name = layer.name,
      type = layer.isGroup and "group" or (layer.isTilemap and "tilemap" or "normal"),
      visible = layer.isVisible,
      opacity = layer.opacity,
      blend_mode = tostring(layer.blendMode),
    }
  end

  local tags_info = {}
  for i, tag in ipairs(sprite.tags) do
    tags_info[i] = {
      name = tag.name,
      from_frame = tag.fromFrame.frameNumber,
      to_frame = tag.toFrame.frameNumber,
      ani_dir = tostring(tag.aniDir),
    }
  end

  return base.success({
    filename = sprite.filename,
    width = sprite.width,
    height = sprite.height,
    color_mode = tostring(sprite.colorMode),
    frame_count = #sprite.frames,
    layer_count = #sprite.layers,
    tag_count = #sprite.tags,
    slice_count = #sprite.slices,
    grid_width = sprite.gridBounds.width,
    grid_height = sprite.gridBounds.height,
    layers = layers_info,
    tags = tags_info,
    palette_size = #sprite.palettes[1],
  })
end

function sprite_cmds.list_open_sprites(params)
  local sprites = {}
  for i, s in ipairs(app.sprites) do
    sprites[i] = {
      filename = s.filename,
      width = s.width,
      height = s.height,
      frames = #s.frames,
      layers = #s.layers,
      is_active = (s == app.sprite),
    }
  end
  return base.success({ sprites = sprites, count = #sprites })
end

function sprite_cmds.set_active_sprite(params)
  local filename, err = base.require_string(params, "filename")
  if err then return err end

  for _, s in ipairs(app.sprites) do
    if s.filename == filename or s.filename:match("[/\\]" .. filename .. "$") then
      app.sprite = s
      return base.success({ active = s.filename })
    end
  end
  return base.error(-32001, "Sprite not found: " .. filename)
end

function sprite_cmds.resize_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local width, err2 = base.require_number(params, "width")
  if err2 then return err2 end
  local height, err3 = base.require_number(params, "height")
  if err3 then return err3 end

  local scale_content = base.optional_bool(params, "scale_content", true)
  local method = base.optional_string(params, "method", "nearest")

  if scale_content then
    app.command.SpriteSize {
      ui = false,
      width = width,
      height = height,
      method = method,
    }
  else
    app.command.CanvasSize {
      ui = false,
      width = width,
      height = height,
    }
  end

  return base.success({
    width = sprite.width,
    height = sprite.height,
  })
end

function sprite_cmds.crop_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local mode = base.optional_string(params, "mode", "content")
  if mode == "selection" then
    app.command.CropSprite()
  else
    app.command.AutocropSprite()
  end

  return base.success({
    width = sprite.width,
    height = sprite.height,
  })
end

function sprite_cmds.flatten_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  app.command.FlattenLayers()

  return base.success({
    layers = #sprite.layers,
  })
end

function sprite_cmds.get_sprite_screenshot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num = base.optional_number(params, "frame", nil)
  if frame_num then
    app.frame = sprite.frames[frame_num]
  end

  local tmp_path = app.fs.tempPath .. app.fs.pathSeparator .. "mcp_screenshot.png"
  local flat = Image(sprite.spec)
  flat:drawSprite(sprite, app.frame.frameNumber)

  flat:saveAs(tmp_path)
  local f = io.open(tmp_path, "rb")
  if not f then
    return base.error(-32603, "Failed to capture screenshot")
  end
  local data = f:read("*a")
  f:close()
  os.remove(tmp_path)

  local b64 = _G.MCP_BASE64
  return base.success({
    image = b64.encode(data),
    width = sprite.width,
    height = sprite.height,
    frame = app.frame.frameNumber,
  })
end

function sprite_cmds.set_sprite_grid(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local gw, err2 = base.require_number(params, "grid_width")
  if err2 then return err2 end
  local gh, err3 = base.require_number(params, "grid_height")
  if err3 then return err3 end

  local ox = base.optional_number(params, "origin_x", 0)
  local oy = base.optional_number(params, "origin_y", 0)

  sprite.gridBounds = Rectangle(ox, oy, gw, gh)

  return base.success({
    grid_width = gw,
    grid_height = gh,
    origin_x = ox,
    origin_y = oy,
  })
end

----------------------------------------------------------------------
-- Layer Commands
----------------------------------------------------------------------
local layer_cmds = {}

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

function layer_cmds.get_layers(params)
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

function layer_cmds.add_layer(params)
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

function layer_cmds.delete_layer(params)
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

function layer_cmds.rename_layer(params)
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

function layer_cmds.set_layer_visibility(params)
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

function layer_cmds.set_layer_opacity(params)
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

function layer_cmds.set_layer_blend_mode(params)
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

function layer_cmds.reorder_layer(params)
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

function layer_cmds.duplicate_layer(params)
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

function layer_cmds.merge_layer_down(params)
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

----------------------------------------------------------------------
-- Frame Commands
----------------------------------------------------------------------
local frame_cmds = {}

function frame_cmds.get_frames(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frames = {}
  for i, frame in ipairs(sprite.frames) do
    frames[i] = {
      number = frame.frameNumber,
      duration_ms = math.floor(frame.duration * 1000),
    }
  end

  return base.success({
    frames = frames,
    count = #sprite.frames,
    active_frame = app.frame and app.frame.frameNumber or 1,
  })
end

function frame_cmds.add_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local after = base.optional_number(params, "after", nil)
  local copy = base.optional_bool(params, "copy", false)

  local new_frame
  app.transaction("Add Frame", function()
    if after then
      new_frame = sprite:newFrame(sprite.frames[after])
    else
      new_frame = sprite:newFrame(app.frame)
    end

    if not copy and new_frame then
      for _, layer in ipairs(sprite.layers) do
        if not layer.isGroup then
          local cel = sprite:cel(layer, new_frame)
          if cel then
            sprite:deleteCel(cel)
          end
        end
      end
    end
  end)

  return base.success({
    frame = new_frame and new_frame.frameNumber or 0,
    total_frames = #sprite.frames,
  })
end

function frame_cmds.delete_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num, err2 = base.require_number(params, "frame")
  if err2 then return err2 end

  if frame_num < 1 or frame_num > #sprite.frames then
    return base.error_invalid_params(
      string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
  end

  if #sprite.frames <= 1 then
    return base.error(-32603, "Cannot delete the last frame")
  end

  app.transaction("Delete Frame", function()
    sprite:deleteFrame(sprite.frames[frame_num])
  end)

  return base.success({ deleted = frame_num, total_frames = #sprite.frames })
end

function frame_cmds.set_frame_duration(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num, err2 = base.require_number(params, "frame")
  if err2 then return err2 end
  local duration_ms, err3 = base.require_number(params, "duration_ms")
  if err3 then return err3 end

  if frame_num < 1 or frame_num > #sprite.frames then
    return base.error_invalid_params(
      string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
  end

  app.transaction("Set Frame Duration", function()
    sprite.frames[frame_num].duration = duration_ms / 1000.0
  end)

  return base.success({
    frame = frame_num,
    duration_ms = duration_ms,
  })
end

function frame_cmds.set_frame_range_duration(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local from, err2 = base.require_number(params, "from_frame")
  if err2 then return err2 end
  local to, err3 = base.require_number(params, "to_frame")
  if err3 then return err3 end
  local duration_ms, err4 = base.require_number(params, "duration_ms")
  if err4 then return err4 end

  from = math.max(1, math.floor(from))
  to = math.min(#sprite.frames, math.floor(to))

  app.transaction("Set Frame Range Duration", function()
    for i = from, to do
      sprite.frames[i].duration = duration_ms / 1000.0
    end
  end)

  return base.success({
    from_frame = from,
    to_frame = to,
    duration_ms = duration_ms,
    frames_updated = to - from + 1,
  })
end

function frame_cmds.set_active_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num, err2 = base.require_number(params, "frame")
  if err2 then return err2 end

  if frame_num < 1 or frame_num > #sprite.frames then
    return base.error_invalid_params(
      string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
  end

  app.frame = sprite.frames[frame_num]

  return base.success({ active_frame = frame_num })
end

function frame_cmds.duplicate_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num = base.optional_number(params, "frame", nil)
  local source_frame = frame_num and sprite.frames[frame_num] or app.frame

  local new_frame
  app.transaction("Duplicate Frame", function()
    new_frame = sprite:newFrame(source_frame)
  end)

  return base.success({
    source_frame = source_frame.frameNumber,
    new_frame = new_frame and new_frame.frameNumber or 0,
    total_frames = #sprite.frames,
  })
end

function frame_cmds.reverse_frames(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local from, err2 = base.require_number(params, "from_frame")
  if err2 then return err2 end
  local to, err3 = base.require_number(params, "to_frame")
  if err3 then return err3 end

  app.range.frames = {}
  for i = from, to do
    app.range.frames[#app.range.frames + 1] = sprite.frames[i]
  end
  app.command.ReverseFrames()

  return base.success({
    from_frame = from,
    to_frame = to,
    reversed = to - from + 1,
  })
end

----------------------------------------------------------------------
-- Cel Commands
----------------------------------------------------------------------
local cel_cmds = {}

function cel_cmds.get_cel(params)
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

function cel_cmds.set_cel_position(params)
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

function cel_cmds.set_cel_opacity(params)
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

function cel_cmds.clear_cel(params)
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

function cel_cmds.link_cels(params)
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

----------------------------------------------------------------------
-- Drawing Commands
----------------------------------------------------------------------
local drawing_cmds = {}

-- Helper: get target cel's image
local function get_target_image(sprite, params)
  local layer, err = base.get_target_layer(sprite, params)
  if err then return nil, nil, nil, err end
  local frame, err2 = base.get_target_frame(sprite, params)
  if err2 then return nil, nil, nil, err2 end

  local cel = layer:cel(frame.frameNumber)
  if not cel then
    local img = Image(sprite.spec)
    img:clear()
    cel = sprite:newCel(layer, frame, img, Point(0, 0))
  end
  return cel, layer, frame, nil
end

function drawing_cmds.put_pixel(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, err2 = base.require_number(params, "x")
  if err2 then return err2 end
  local y, err3 = base.require_number(params, "y")
  if err3 then return err3 end
  local color_hex, err4 = base.require_string(params, "color")
  if err4 then return err4 end

  local cel, _, _, err5 = get_target_image(sprite, params)
  if err5 then return err5 end

  local color = color_util.from_hex(color_hex)
  local pixel_val = color_util.color_to_pixel(color, sprite.colorMode, sprite.palettes[1])

  local lx = x - cel.position.x
  local ly = y - cel.position.y

  app.transaction("Put Pixel", function()
    if lx >= 0 and ly >= 0 and lx < cel.image.width and ly < cel.image.height then
      cel.image:putPixel(lx, ly, pixel_val)
    end
  end)

  return base.success({ x = x, y = y, color = color_hex })
end

function drawing_cmds.put_pixels(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local pixels = params.pixels
  if not pixels then
    return base.error_invalid_params("Missing required parameter: pixels (array)")
  end

  local pixel_count = #pixels
  if pixel_count == 0 then
    return base.success({ pixels_set = 0 })
  end

  local cel, _, _, err2 = get_target_image(sprite, params)
  if err2 then return err2 end

  local palette = sprite.palettes[1]
  local cm = sprite.colorMode
  local img = cel.image
  local ox, oy = cel.position.x, cel.position.y

  app.transaction("Put Pixels", function()
    for i = 1, pixel_count do
      local p = pixels[i]
      if p and p.x and p.y and p.color then
        local color = color_util.from_hex(p.color)
        local pv = color_util.color_to_pixel(color, cm, palette)
        local lx = p.x - ox
        local ly = p.y - oy
        if lx >= 0 and ly >= 0 and lx < img.width and ly < img.height then
          img:putPixel(lx, ly, pv)
        end
      end
    end
  end)

  return base.success({ pixels_set = #pixels })
end

function drawing_cmds.get_pixel(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, err2 = base.require_number(params, "x")
  if err2 then return err2 end
  local y, err3 = base.require_number(params, "y")
  if err3 then return err3 end

  local cel, _, _, err4 = get_target_image(sprite, params)
  if err4 then return err4 end

  local lx = x - cel.position.x
  local ly = y - cel.position.y

  if lx < 0 or ly < 0 or lx >= cel.image.width or ly >= cel.image.height then
    return base.success({ x = x, y = y, color = "#00000000", alpha = 0 })
  end

  local pv = cel.image:getPixel(lx, ly)
  local color = color_util.pixel_to_color(pv, sprite.colorMode, sprite.palettes[1])

  return base.success({
    x = x, y = y,
    color = color_util.to_hex(color, true),
    r = color.red, g = color.green, b = color.blue, a = color.alpha,
  })
end

function drawing_cmds.get_image_data(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local format = base.optional_string(params, "format", "base64_png")
  local cel, _, _, err2 = get_target_image(sprite, params)
  if err2 then return err2 end

  if format == "hex_array" then
    local pixels = {}
    local palette = sprite.palettes[1]
    for y = 0, cel.image.height - 1 do
      for x = 0, cel.image.width - 1 do
        local pv = cel.image:getPixel(x, y)
        local c = color_util.pixel_to_color(pv, sprite.colorMode, palette)
        pixels[#pixels + 1] = color_util.to_hex(c, true)
      end
    end
    return base.success({
      pixels = pixels,
      width = cel.image.width,
      height = cel.image.height,
      offset_x = cel.position.x,
      offset_y = cel.position.y,
    })
  else
    local tmp = app.fs.tempPath .. app.fs.pathSeparator .. "mcp_tmp.png"
    cel.image:saveAs(tmp)
    local f = io.open(tmp, "rb")
    if not f then return base.error(-32603, "Failed to save image data") end
    local data = f:read("*a")
    f:close()
    os.remove(tmp)

    local b64 = _G.MCP_BASE64
    return base.success({
      image = b64.encode(data),
      width = cel.image.width,
      height = cel.image.height,
      offset_x = cel.position.x,
      offset_y = cel.position.y,
    })
  end
end

function drawing_cmds.set_image_data(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local data, err2 = base.require_string(params, "data")
  if err2 then return err2 end

  local format = base.optional_string(params, "format", "base64_png")
  local layer, err3 = base.get_target_layer(sprite, params)
  if err3 then return err3 end
  local frame, err4 = base.get_target_frame(sprite, params)
  if err4 then return err4 end

  if format == "base64_png" then
    local b64 = _G.MCP_BASE64
    local decoded = b64.decode(data)
    local tmp = app.fs.tempPath .. app.fs.pathSeparator .. "mcp_tmp.png"
    local f = io.open(tmp, "wb")
    if not f then return base.error(-32603, "Failed to write temp file") end
    f:write(decoded)
    f:close()

    local img = Image { fromFile = tmp }
    os.remove(tmp)

    if not img then return base.error(-32603, "Failed to load image data") end

    app.transaction("Set Image Data", function()
      local cel = layer:cel(frame.frameNumber)
      if cel then
        sprite:deleteCel(cel)
      end
      sprite:newCel(layer, frame, img, Point(0, 0))
    end)

    return base.success({ width = img.width, height = img.height })
  else
    return base.error_invalid_params("hex_array format for set_image_data is not yet supported. Use base64_png.")
  end
end

function drawing_cmds.draw_line(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x1, e1 = base.require_number(params, "x1")
  if e1 then return e1 end
  local y1, e2 = base.require_number(params, "y1")
  if e2 then return e2 end
  local x2, e3 = base.require_number(params, "x2")
  if e3 then return e3 end
  local y2, e4 = base.require_number(params, "y2")
  if e4 then return e4 end
  local color_hex, e5 = base.require_string(params, "color")
  if e5 then return e5 end

  local brush_size = base.optional_number(params, "brush_size", 1)
  local layer, e6 = base.get_target_layer(sprite, params)
  if e6 then return e6 end
  local frame, e7 = base.get_target_frame(sprite, params)
  if e7 then return e7 end

  local color = color_util.from_hex(color_hex)

  app.transaction("Draw Line", function()
    local cel = layer:cel(frame.frameNumber)
    app.useTool {
      tool = "line",
      color = color,
      brush = Brush(brush_size),
      points = { Point(x1, y1), Point(x2, y2) },
      cel = cel,
      layer = layer,
      frame = frame,
    }
  end)

  return base.success({ x1 = x1, y1 = y1, x2 = x2, y2 = y2 })
end

function drawing_cmds.draw_rect(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, e1 = base.require_number(params, "x")
  if e1 then return e1 end
  local y, e2 = base.require_number(params, "y")
  if e2 then return e2 end
  local w, e3 = base.require_number(params, "width")
  if e3 then return e3 end
  local h, e4 = base.require_number(params, "height")
  if e4 then return e4 end
  local color_hex, e5 = base.require_string(params, "color")
  if e5 then return e5 end

  local filled = base.optional_bool(params, "filled", true)
  local brush_size = base.optional_number(params, "brush_size", 1)
  local layer, e6 = base.get_target_layer(sprite, params)
  if e6 then return e6 end
  local frame, e7 = base.get_target_frame(sprite, params)
  if e7 then return e7 end

  local color = color_util.from_hex(color_hex)
  local tool = filled and "filled_rectangle" or "rectangle"

  app.transaction("Draw Rectangle", function()
    app.useTool {
      tool = tool,
      color = color,
      brush = Brush(brush_size),
      points = { Point(x, y), Point(x + w - 1, y + h - 1) },
      layer = layer,
      frame = frame,
    }
  end)

  return base.success({ x = x, y = y, width = w, height = h, filled = filled })
end

function drawing_cmds.draw_ellipse(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, e1 = base.require_number(params, "x")
  if e1 then return e1 end
  local y, e2 = base.require_number(params, "y")
  if e2 then return e2 end
  local w, e3 = base.require_number(params, "width")
  if e3 then return e3 end
  local h, e4 = base.require_number(params, "height")
  if e4 then return e4 end
  local color_hex, e5 = base.require_string(params, "color")
  if e5 then return e5 end

  local filled = base.optional_bool(params, "filled", true)
  local brush_size = base.optional_number(params, "brush_size", 1)
  local layer, e6 = base.get_target_layer(sprite, params)
  if e6 then return e6 end
  local frame, e7 = base.get_target_frame(sprite, params)
  if e7 then return e7 end

  local color = color_util.from_hex(color_hex)
  local tool = filled and "filled_ellipse" or "ellipse"

  app.transaction("Draw Ellipse", function()
    app.useTool {
      tool = tool,
      color = color,
      brush = Brush(brush_size),
      points = { Point(x, y), Point(x + w - 1, y + h - 1) },
      layer = layer,
      frame = frame,
    }
  end)

  return base.success({ x = x, y = y, width = w, height = h, filled = filled })
end

function drawing_cmds.flood_fill(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, e1 = base.require_number(params, "x")
  if e1 then return e1 end
  local y, e2 = base.require_number(params, "y")
  if e2 then return e2 end
  local color_hex, e3 = base.require_string(params, "color")
  if e3 then return e3 end

  local tolerance = base.optional_number(params, "tolerance", 0)
  local contiguous = base.optional_bool(params, "contiguous", true)
  local layer, e4 = base.get_target_layer(sprite, params)
  if e4 then return e4 end
  local frame, e5 = base.get_target_frame(sprite, params)
  if e5 then return e5 end

  local color = color_util.from_hex(color_hex)

  app.transaction("Flood Fill", function()
    app.useTool {
      tool = "paint_bucket",
      color = color,
      points = { Point(x, y) },
      layer = layer,
      frame = frame,
      tolerance = tolerance,
      contiguous = contiguous,
    }
  end)

  return base.success({ x = x, y = y, color = color_hex })
end

function drawing_cmds.draw_brush_stroke(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local points_data = params.points
  if not points_data or type(points_data) ~= "table" or #points_data < 1 then
    return base.error_invalid_params("Missing required parameter: points (array of {x,y})")
  end

  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  local brush_size = base.optional_number(params, "brush_size", 1)
  local brush_type = base.optional_string(params, "brush_type", "circle")
  local layer, e2 = base.get_target_layer(sprite, params)
  if e2 then return e2 end
  local frame, e3 = base.get_target_frame(sprite, params)
  if e3 then return e3 end

  local color = color_util.from_hex(color_hex)
  local points = {}
  for i = 1, #points_data do
    local p = points_data[i]
    points[#points + 1] = Point(p.x, p.y)
  end

  local brush
  if brush_type == "square" then
    brush = Brush { type = BrushType.SQUARE, size = brush_size }
  elseif brush_type == "line" then
    brush = Brush { type = BrushType.LINE, size = brush_size }
  else
    brush = Brush { type = BrushType.CIRCLE, size = brush_size }
  end

  app.transaction("Draw Brush Stroke", function()
    app.useTool {
      tool = "pencil",
      color = color,
      brush = brush,
      points = points,
      layer = layer,
      frame = frame,
    }
  end)

  return base.success({ points = #points, brush_size = brush_size })
end

function drawing_cmds.clear_image(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local color_hex = base.optional_string(params, "color", nil)
  local layer, e1 = base.get_target_layer(sprite, params)
  if e1 then return e1 end
  local frame, e2 = base.get_target_frame(sprite, params)
  if e2 then return e2 end

  app.transaction("Clear Image", function()
    local cel = layer:cel(frame.frameNumber)
    if cel then
      if color_hex then
        local color = color_util.from_hex(color_hex)
        local pv = color_util.color_to_pixel(color, sprite.colorMode, sprite.palettes[1])
        cel.image:clear(pv)
      else
        cel.image:clear()
      end
    end
  end)

  return base.success({ cleared = true })
end

function drawing_cmds.replace_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local from_hex, e1 = base.require_string(params, "from_color")
  if e1 then return e1 end
  local to_hex, e2 = base.require_string(params, "to_color")
  if e2 then return e2 end

  local scope = base.optional_string(params, "scope", "cel")
  local tolerance = base.optional_number(params, "tolerance", 0)

  local from_color = color_util.from_hex(from_hex)
  local to_color = color_util.from_hex(to_hex)
  local palette = sprite.palettes[1]
  local cm = sprite.colorMode
  local from_pv = color_util.color_to_pixel(from_color, cm, palette)
  local to_pv = color_util.color_to_pixel(to_color, cm, palette)

  local replaced = 0

  app.transaction("Replace Color", function()
    local function replace_in_image(img)
      for y = 0, img.height - 1 do
        for x = 0, img.width - 1 do
          local pv = img:getPixel(x, y)
          if tolerance == 0 then
            if pv == from_pv then
              img:putPixel(x, y, to_pv)
              replaced = replaced + 1
            end
          else
            local c = color_util.pixel_to_color(pv, cm, palette)
            local dr = math.abs(c.red - from_color.red)
            local dg = math.abs(c.green - from_color.green)
            local db = math.abs(c.blue - from_color.blue)
            if dr <= tolerance and dg <= tolerance and db <= tolerance then
              img:putPixel(x, y, to_pv)
              replaced = replaced + 1
            end
          end
        end
      end
    end

    if scope == "sprite" then
      for _, layer in ipairs(sprite.layers) do
        if not layer.isGroup then
          for _, frame in ipairs(sprite.frames) do
            local cel = layer:cel(frame.frameNumber)
            if cel then replace_in_image(cel.image) end
          end
        end
      end
    elseif scope == "layer" then
      local layer = app.layer
      for _, frame in ipairs(sprite.frames) do
        local cel = layer:cel(frame.frameNumber)
        if cel then replace_in_image(cel.image) end
      end
    else
      local cel = app.cel
      if cel then replace_in_image(cel.image) end
    end
  end)

  return base.success({
    from_color = from_hex,
    to_color = to_hex,
    pixels_replaced = replaced,
    scope = scope,
  })
end

function drawing_cmds.outline(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  local outside = base.optional_bool(params, "outside", true)
  local layer, e2 = base.get_target_layer(sprite, params)
  if e2 then return e2 end
  local frame, e3 = base.get_target_frame(sprite, params)
  if e3 then return e3 end

  local cel = layer:cel(frame.frameNumber)
  if not cel then
    return base.error(-32001, "No cel content to outline")
  end

  local color = color_util.from_hex(color_hex)
  local palette = sprite.palettes[1]
  local cm = sprite.colorMode
  local outline_pv = color_util.color_to_pixel(color, cm, palette)

  local img = cel.image
  local w, h = img.width, img.height
  local src = img:clone()

  app.transaction("Outline", function()
    local dirs = { {-1,0}, {1,0}, {0,-1}, {0,1} }
    if outside then
      for y = 0, h - 1 do
        for x = 0, w - 1 do
          local pv = src:getPixel(x, y)
          local c = color_util.pixel_to_color(pv, cm, palette)
          if c.alpha == 0 then
            for _, d in ipairs(dirs) do
              local nx, ny = x + d[1], y + d[2]
              if nx >= 0 and ny >= 0 and nx < w and ny < h then
                local npv = src:getPixel(nx, ny)
                local nc = color_util.pixel_to_color(npv, cm, palette)
                if nc.alpha > 0 then
                  img:putPixel(x, y, outline_pv)
                  break
                end
              end
            end
          end
        end
      end
    else
      for y = 0, h - 1 do
        for x = 0, w - 1 do
          local pv = src:getPixel(x, y)
          local c = color_util.pixel_to_color(pv, cm, palette)
          if c.alpha > 0 then
            for _, d in ipairs(dirs) do
              local nx, ny = x + d[1], y + d[2]
              if nx < 0 or ny < 0 or nx >= w or ny >= h then
                img:putPixel(x, y, outline_pv)
                break
              else
                local npv = src:getPixel(nx, ny)
                local nc = color_util.pixel_to_color(npv, cm, palette)
                if nc.alpha == 0 then
                  img:putPixel(x, y, outline_pv)
                  break
                end
              end
            end
          end
        end
      end
    end
  end)

  return base.success({ color = color_hex, outside = outside })
end

----------------------------------------------------------------------
-- Selection Commands
----------------------------------------------------------------------
local selection_cmds = {}

local function selection_mode_value(mode_str)
  if mode_str == "add" then return SelectionMode.ADD end
  if mode_str == "subtract" then return SelectionMode.SUBTRACT end
  if mode_str == "intersect" then return SelectionMode.INTERSECT end
  return SelectionMode.REPLACE
end

function selection_cmds.select_rect(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, e1 = base.require_number(params, "x")
  if e1 then return e1 end
  local y, e2 = base.require_number(params, "y")
  if e2 then return e2 end
  local w, e3 = base.require_number(params, "width")
  if e3 then return e3 end
  local h, e4 = base.require_number(params, "height")
  if e4 then return e4 end

  local mode = base.optional_string(params, "mode", "replace")
  local sel = sprite.selection

  sel:select(Rectangle(x, y, w, h))

  return base.success({
    bounds = { x = sel.bounds.x, y = sel.bounds.y,
               width = sel.bounds.width, height = sel.bounds.height },
  })
end

function selection_cmds.select_ellipse(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local x, e1 = base.require_number(params, "x")
  if e1 then return e1 end
  local y, e2 = base.require_number(params, "y")
  if e2 then return e2 end
  local w, e3 = base.require_number(params, "width")
  if e3 then return e3 end
  local h, e4 = base.require_number(params, "height")
  if e4 then return e4 end

  app.command.SelectEllipse {
    ui = false,
    bounds = Rectangle(x, y, w, h),
  }

  local sel = sprite.selection
  return base.success({
    bounds = { x = sel.bounds.x, y = sel.bounds.y,
               width = sel.bounds.width, height = sel.bounds.height },
  })
end

function selection_cmds.select_all(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  sprite.selection:selectAll()

  return base.success({
    bounds = { x = 0, y = 0, width = sprite.width, height = sprite.height },
  })
end

function selection_cmds.deselect(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  sprite.selection:deselect()

  return base.success({ deselected = true })
end

function selection_cmds.select_by_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  local tolerance = base.optional_number(params, "tolerance", 0)
  local color = color_util.from_hex(color_hex)

  app.fgColor = color
  app.command.MaskByColor {
    ui = false,
    tolerance = tolerance,
  }

  local sel = sprite.selection
  return base.success({
    is_empty = sel.isEmpty,
    bounds = not sel.isEmpty and {
      x = sel.bounds.x, y = sel.bounds.y,
      width = sel.bounds.width, height = sel.bounds.height,
    } or nil,
  })
end

function selection_cmds.get_selection(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local sel = sprite.selection

  return base.success({
    is_empty = sel.isEmpty,
    bounds = not sel.isEmpty and {
      x = sel.bounds.x, y = sel.bounds.y,
      width = sel.bounds.width, height = sel.bounds.height,
    } or nil,
  })
end

function selection_cmds.invert_selection(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  app.command.InvertMask()

  local sel = sprite.selection
  return base.success({
    is_empty = sel.isEmpty,
    bounds = not sel.isEmpty and {
      x = sel.bounds.x, y = sel.bounds.y,
      width = sel.bounds.width, height = sel.bounds.height,
    } or nil,
  })
end

----------------------------------------------------------------------
-- Palette Commands
----------------------------------------------------------------------
local palette_cmds = {}

function palette_cmds.get_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local palette = sprite.palettes[1]
  local max_colors = base.optional_number(params, "max_colors", #palette)
  local count = math.min(max_colors, #palette)

  local colors = {}
  for i = 0, count - 1 do
    local c = palette:getColor(i)
    colors[i + 1] = {
      index = i,
      color = color_util.to_hex(c, true),
      r = c.red, g = c.green, b = c.blue, a = c.alpha,
    }
  end

  return base.success({ colors = colors, size = #palette })
end

function palette_cmds.set_palette_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local index, e1 = base.require_number(params, "index")
  if e1 then return e1 end
  local color_hex, e2 = base.require_string(params, "color")
  if e2 then return e2 end

  local palette = sprite.palettes[1]
  if index < 0 or index >= #palette then
    return base.error_invalid_params(
      string.format("Index %d out of range (0-%d)", index, #palette - 1))
  end

  local color = color_util.from_hex(color_hex)
  app.transaction("Set Palette Color", function()
    palette:setColor(index, color)
  end)

  return base.success({ index = index, color = color_hex })
end

function palette_cmds.set_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local colors = params.colors
  if not colors or type(colors) ~= "table" then
    return base.error_invalid_params("Missing required parameter: colors (array of hex strings)")
  end

  app.transaction("Set Palette", function()
    local palette = sprite.palettes[1]
    palette:resize(#colors)
    for i = 1, #colors do
      local hex = colors[i]
      palette:setColor(i - 1, color_util.from_hex(hex))
    end
  end)

  return base.success({ size = #colors })
end

function palette_cmds.add_palette_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  local palette = sprite.palettes[1]
  local new_index = #palette

  app.transaction("Add Palette Color", function()
    palette:resize(new_index + 1)
    palette:setColor(new_index, color_util.from_hex(color_hex))
  end)

  return base.success({ index = new_index, color = color_hex, size = #palette })
end

function palette_cmds.resize_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local size, e1 = base.require_number(params, "size")
  if e1 then return e1 end

  app.transaction("Resize Palette", function()
    sprite.palettes[1]:resize(math.floor(size))
  end)

  return base.success({ size = #sprite.palettes[1] })
end

function palette_cmds.load_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local palette = Palette { fromFile = path }
  if not palette then
    return base.error(-32603, "Failed to load palette from: " .. path)
  end

  app.transaction("Load Palette", function()
    sprite:setPalette(palette)
  end)

  return base.success({ size = #palette, path = path })
end

function palette_cmds.save_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  sprite.palettes[1]:saveAs(path)

  return base.success({ path = path, size = #sprite.palettes[1] })
end

function palette_cmds.set_fg_color(params)
  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  app.fgColor = color_util.from_hex(color_hex)

  return base.success({ color = color_hex })
end

function palette_cmds.set_bg_color(params)
  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  app.bgColor = color_util.from_hex(color_hex)

  return base.success({ color = color_hex })
end

function palette_cmds.generate_palette_from_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local max_colors = base.optional_number(params, "max_colors", 256)

  local color_counts = {}
  local palette = sprite.palettes[1]
  local cm = sprite.colorMode

  for _, layer in ipairs(sprite.layers) do
    if not layer.isGroup and layer.isVisible then
      for _, frame in ipairs(sprite.frames) do
        local cel = layer:cel(frame.frameNumber)
        if cel then
          for y = 0, cel.image.height - 1 do
            for x = 0, cel.image.width - 1 do
              local pv = cel.image:getPixel(x, y)
              local c = color_util.pixel_to_color(pv, cm, palette)
              if c.alpha > 0 then
                local hex = color_util.to_hex(c, false)
                color_counts[hex] = (color_counts[hex] or 0) + 1
              end
            end
          end
        end
      end
    end
  end

  local sorted = {}
  for hex, count in pairs(color_counts) do
    sorted[#sorted + 1] = { hex = hex, count = count }
  end
  table.sort(sorted, function(a, b) return a.count > b.count end)

  local new_colors = {}
  for i = 1, math.min(#sorted, max_colors) do
    new_colors[i] = sorted[i].hex
  end

  app.transaction("Generate Palette", function()
    local pal = sprite.palettes[1]
    pal:resize(#new_colors)
    for i, hex in ipairs(new_colors) do
      pal:setColor(i - 1, color_util.from_hex(hex))
    end
  end)

  return base.success({
    unique_colors = #sorted,
    palette_size = #new_colors,
  })
end

function palette_cmds.sort_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local sort_by = base.optional_string(params, "sort_by", "hue")
  local reverse = base.optional_bool(params, "reverse", false)
  local palette = sprite.palettes[1]

  local colors = {}
  for i = 0, #palette - 1 do
    local c = palette:getColor(i)
    colors[#colors + 1] = {
      index = i,
      color = c,
      hex = color_util.to_hex(c),
      h = c.hslHue,
      s = c.hslSaturation,
      l = c.hslLightness,
    }
  end

  if sort_by == "hue" then
    table.sort(colors, function(a, b) return a.h < b.h end)
  elseif sort_by == "saturation" then
    table.sort(colors, function(a, b) return a.s < b.s end)
  elseif sort_by == "lightness" or sort_by == "brightness" then
    table.sort(colors, function(a, b) return a.l < b.l end)
  elseif sort_by == "red" then
    table.sort(colors, function(a, b) return a.color.red < b.color.red end)
  elseif sort_by == "green" then
    table.sort(colors, function(a, b) return a.color.green < b.color.green end)
  elseif sort_by == "blue" then
    table.sort(colors, function(a, b) return a.color.blue < b.color.blue end)
  end

  if reverse then
    local reversed = {}
    for i = #colors, 1, -1 do reversed[#reversed + 1] = colors[i] end
    colors = reversed
  end

  app.transaction("Sort Palette", function()
    for i, entry in ipairs(colors) do
      palette:setColor(i - 1, entry.color)
    end
  end)

  return base.success({ size = #palette, sort_by = sort_by, reverse = reverse })
end

function palette_cmds.import_palette_from_image(params)
  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local max_colors = base.optional_number(params, "max_colors", 256)

  local img = Image { fromFile = path }
  if not img then
    return base.error(-32603, "Failed to load image: " .. path)
  end

  local color_counts = {}
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      local pv = img:getPixel(x, y)
      local r = app.pixelColor.rgbaR(pv)
      local g = app.pixelColor.rgbaG(pv)
      local b = app.pixelColor.rgbaB(pv)
      local a = app.pixelColor.rgbaA(pv)
      if a > 0 then
        local hex = string.format("#%02X%02X%02X", r, g, b)
        color_counts[hex] = (color_counts[hex] or 0) + 1
      end
    end
  end

  local sorted = {}
  for hex, count in pairs(color_counts) do
    sorted[#sorted + 1] = { hex = hex, count = count }
  end
  table.sort(sorted, function(a, b) return a.count > b.count end)

  local sprite, _ = base.get_sprite()
  if sprite then
    local count = math.min(#sorted, max_colors)
    app.transaction("Import Palette from Image", function()
      local pal = sprite.palettes[1]
      pal:resize(count)
      for i = 1, count do
        pal:setColor(i - 1, color_util.from_hex(sorted[i].hex))
      end
    end)
    return base.success({ palette_size = count, source = path, unique_colors = #sorted })
  else
    return base.error_no_sprite()
  end
end

----------------------------------------------------------------------
-- Tag Commands
----------------------------------------------------------------------
local tag_cmds = {}

function tag_cmds.get_tags(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local tags = {}
  for i, tag in ipairs(sprite.tags) do
    tags[i] = {
      name = tag.name,
      from_frame = tag.fromFrame.frameNumber,
      to_frame = tag.toFrame.frameNumber,
      frame_count = tag.frames,
      ani_dir = tostring(tag.aniDir),
      repeat_count = tag.repeats,
      color = color_util.to_hex(tag.color),
    }
  end

  return base.success({ tags = tags, count = #sprite.tags })
end

function tag_cmds.create_tag(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local from_frame, e2 = base.require_number(params, "from_frame")
  if e2 then return e2 end
  local to_frame, e3 = base.require_number(params, "to_frame")
  if e3 then return e3 end

  if from_frame < 1 or from_frame > #sprite.frames then
    return base.error_invalid_params("from_frame out of range")
  end
  if to_frame < from_frame or to_frame > #sprite.frames then
    return base.error_invalid_params("to_frame out of range")
  end

  local tag
  app.transaction("Create Tag", function()
    tag = sprite:newTag(from_frame, to_frame)
    tag.name = name

    local color_hex = base.optional_string(params, "color", nil)
    if color_hex then
      tag.color = color_util.from_hex(color_hex)
    end

    local ani_dir = base.optional_string(params, "ani_dir", nil)
    if ani_dir then
      local dirs = {
        forward = AniDir.FORWARD,
        reverse = AniDir.REVERSE,
        ping_pong = AniDir.PING_PONG,
        ping_pong_reverse = AniDir.PING_PONG_REVERSE,
      }
      if dirs[ani_dir] then tag.aniDir = dirs[ani_dir] end
    end

    local repeat_count = base.optional_number(params, "repeat", nil)
    if repeat_count then
      tag.repeats = math.floor(repeat_count)
    end
  end)

  return base.success({
    name = name,
    from_frame = from_frame,
    to_frame = to_frame,
  })
end

function tag_cmds.delete_tag(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Delete Tag", function()
    sprite:deleteTag(tag)
  end)

  return base.success({ deleted = name })
end

function tag_cmds.rename_tag(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local new_name, e2 = base.require_string(params, "new_name")
  if e2 then return e2 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Rename Tag", function()
    tag.name = new_name
  end)

  return base.success({ old_name = name, new_name = new_name })
end

function tag_cmds.set_tag_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local color_hex, e2 = base.require_string(params, "color")
  if e2 then return e2 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Set Tag Color", function()
    tag.color = color_util.from_hex(color_hex)
  end)

  return base.success({ name = name, color = color_hex })
end

function tag_cmds.set_tag_range(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local from_frame, e2 = base.require_number(params, "from_frame")
  if e2 then return e2 end
  local to_frame, e3 = base.require_number(params, "to_frame")
  if e3 then return e3 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Set Tag Range", function()
    tag.fromFrame = sprite.frames[from_frame]
    tag.toFrame = sprite.frames[to_frame]
  end)

  return base.success({ name = name, from_frame = from_frame, to_frame = to_frame })
end

----------------------------------------------------------------------
-- Slice Commands
----------------------------------------------------------------------
local slice_cmds = {}

function slice_cmds.get_slices(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local slices = {}
  for i, slice in ipairs(sprite.slices) do
    local info = {
      name = slice.name,
      bounds = {
        x = slice.bounds.x,
        y = slice.bounds.y,
        width = slice.bounds.width,
        height = slice.bounds.height,
      },
      color = color_util.to_hex(slice.color),
    }
    if slice.center then
      info.center = {
        x = slice.center.x,
        y = slice.center.y,
        width = slice.center.width,
        height = slice.center.height,
      }
    end
    if slice.pivot then
      info.pivot = { x = slice.pivot.x, y = slice.pivot.y }
    end
    slices[i] = info
  end

  return base.success({ slices = slices, count = #sprite.slices })
end

function slice_cmds.create_slice(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local x, e2 = base.require_number(params, "x")
  if e2 then return e2 end
  local y, e3 = base.require_number(params, "y")
  if e3 then return e3 end
  local w, e4 = base.require_number(params, "width")
  if e4 then return e4 end
  local h, e5 = base.require_number(params, "height")
  if e5 then return e5 end

  local slice
  app.transaction("Create Slice", function()
    slice = sprite:newSlice(Rectangle(x, y, w, h))
    slice.name = name

    local color_hex = base.optional_string(params, "color", nil)
    if color_hex then
      slice.color = color_util.from_hex(color_hex)
    end
  end)

  return base.success({
    name = name,
    bounds = { x = x, y = y, width = w, height = h },
  })
end

function slice_cmds.delete_slice(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == name then
      target = slice
      break
    end
  end

  if not target then
    return base.error(-32001, "Slice not found: " .. name)
  end

  app.transaction("Delete Slice", function()
    sprite:deleteSlice(target)
  end)

  return base.success({ deleted = name })
end

function slice_cmds.set_slice_9patch(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local cx, e2 = base.require_number(params, "center_x")
  if e2 then return e2 end
  local cy, e3 = base.require_number(params, "center_y")
  if e3 then return e3 end
  local cw, e4 = base.require_number(params, "center_width")
  if e4 then return e4 end
  local ch, e5 = base.require_number(params, "center_height")
  if e5 then return e5 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == name then target = slice; break end
  end
  if not target then
    return base.error(-32001, "Slice not found: " .. name)
  end

  app.transaction("Set 9-Patch", function()
    target.center = Rectangle(cx, cy, cw, ch)
  end)

  return base.success({
    name = name,
    center = { x = cx, y = cy, width = cw, height = ch },
  })
end

function slice_cmds.set_slice_pivot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local px, e2 = base.require_number(params, "pivot_x")
  if e2 then return e2 end
  local py, e3 = base.require_number(params, "pivot_y")
  if e3 then return e3 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == name then target = slice; break end
  end
  if not target then
    return base.error(-32001, "Slice not found: " .. name)
  end

  app.transaction("Set Slice Pivot", function()
    target.pivot = Point(px, py)
  end)

  return base.success({ name = name, pivot = { x = px, y = py } })
end

----------------------------------------------------------------------
-- Tilemap Commands
----------------------------------------------------------------------
local tilemap_cmds = {}

function tilemap_cmds.create_tilemap_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local tile_width, e1 = base.require_number(params, "tile_width")
  if e1 then return e1 end
  local tile_height, e2 = base.require_number(params, "tile_height")
  if e2 then return e2 end

  local name = base.optional_string(params, "name", nil)

  sprite.gridBounds = Rectangle(0, 0, tile_width, tile_height)

  local layer
  app.transaction("Create Tilemap Layer", function()
    layer = sprite:newLayer()
    app.layer = layer
    app.command.NewLayer { tilemap = true }
    layer = app.layer
    if name and layer then
      layer.name = name
    end
  end)

  return base.success({
    name = layer and layer.name or "Tilemap",
    tile_width = tile_width,
    tile_height = tile_height,
    is_tilemap = layer and layer.isTilemap or false,
  })
end

function tilemap_cmds.get_tileset(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, e1 = base.require_string(params, "layer")
  if e1 then return e1 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end
  if not layer.isTilemap then
    return base.error(-32001, "Layer is not a tilemap: " .. layer_name)
  end

  local tileset = layer.tileset
  if not tileset then
    return base.error(-32001, "No tileset found for layer: " .. layer_name)
  end

  return base.success({
    name = tileset.name or "",
    tile_count = #tileset,
    tile_width = tileset.grid.tileSize.width,
    tile_height = tileset.grid.tileSize.height,
  })
end

function tilemap_cmds.set_tile(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, e1 = base.require_string(params, "layer")
  if e1 then return e1 end
  local col, e2 = base.require_number(params, "col")
  if e2 then return e2 end
  local row, e3 = base.require_number(params, "row")
  if e3 then return e3 end
  local tile_index, e4 = base.require_number(params, "tile_index")
  if e4 then return e4 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end
  if not layer.isTilemap then
    return base.error(-32001, "Layer is not a tilemap: " .. layer_name)
  end

  local frame_num = base.optional_number(params, "frame", nil)
  local frame = frame_num and sprite.frames[frame_num] or app.frame

  local cel = layer:cel(frame.frameNumber)
  if not cel then
    return base.error(-32001, "No cel at frame " .. frame.frameNumber)
  end

  app.transaction("Set Tile", function()
    cel.image:putPixel(col, row, tile_index)
  end)

  return base.success({ col = col, row = row, tile_index = tile_index })
end

function tilemap_cmds.get_tile(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, e1 = base.require_string(params, "layer")
  if e1 then return e1 end
  local col, e2 = base.require_number(params, "col")
  if e2 then return e2 end
  local row, e3 = base.require_number(params, "row")
  if e3 then return e3 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end

  local frame_num = base.optional_number(params, "frame", nil)
  local frame = frame_num and sprite.frames[frame_num] or app.frame

  local cel = layer:cel(frame.frameNumber)
  if not cel then
    return base.success({ col = col, row = row, tile_index = -1, empty = true })
  end

  local tile_index = cel.image:getPixel(col, row)
  return base.success({ col = col, row = row, tile_index = tile_index })
end

function tilemap_cmds.get_tilemap_info(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, e1 = base.require_string(params, "layer")
  if e1 then return e1 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end
  if not layer.isTilemap then
    return base.error(-32001, "Layer is not a tilemap: " .. layer_name)
  end

  local frame_num = base.optional_number(params, "frame", nil)
  local frame = frame_num and sprite.frames[frame_num] or app.frame

  local cel = layer:cel(frame.frameNumber)
  local grid_cols = 0
  local grid_rows = 0
  local used_tiles = {}

  if cel then
    grid_cols = cel.image.width
    grid_rows = cel.image.height
    local seen = {}
    for y = 0, grid_rows - 1 do
      for x = 0, grid_cols - 1 do
        local idx = cel.image:getPixel(x, y)
        if not seen[idx] then
          seen[idx] = true
          used_tiles[#used_tiles + 1] = idx
        end
      end
    end
    table.sort(used_tiles)
  end

  local tileset = layer.tileset
  return base.success({
    layer = layer_name,
    grid_cols = grid_cols,
    grid_rows = grid_rows,
    tile_width = tileset and tileset.grid.tileSize.width or 0,
    tile_height = tileset and tileset.grid.tileSize.height or 0,
    tile_count = tileset and #tileset or 0,
    used_tile_indices = used_tiles,
  })
end

----------------------------------------------------------------------
-- Export Commands
----------------------------------------------------------------------
local export_cmds = {}

function export_cmds.export_png(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local frame_num = base.optional_number(params, "frame", nil)

  if frame_num then
    if frame_num < 1 or frame_num > #sprite.frames then
      return base.error_invalid_params("Frame out of range")
    end
    local img = Image(sprite.spec)
    img:drawSprite(sprite, frame_num)
    img:saveAs(path)
  else
    if #sprite.frames == 1 then
      local img = Image(sprite.spec)
      img:drawSprite(sprite, 1)
      img:saveAs(path)
    else
      for i = 1, #sprite.frames do
        local frame_path = path:gsub("{frame}", string.format("%03d", i))
        local img = Image(sprite.spec)
        img:drawSprite(sprite, i)
        img:saveAs(frame_path)
      end
    end
  end

  return base.success({ path = path, frames_exported = frame_num and 1 or #sprite.frames })
end

function export_cmds.export_sprite_sheet(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local sheet_type_str = base.optional_string(params, "sheet_type", "horizontal")
  local columns = base.optional_number(params, "columns", nil)
  local padding = base.optional_number(params, "padding", 0)
  local tag_name = base.optional_string(params, "tag", nil)

  local from_frame, to_frame = 1, #sprite.frames
  if tag_name then
    local tag = base.find_tag(sprite, tag_name)
    if tag then
      from_frame = tag.fromFrame.frameNumber
      to_frame = tag.toFrame.frameNumber
    end
  end

  local frame_count = to_frame - from_frame + 1
  local fw = sprite.width
  local fh = sprite.height

  local cols, rows_count
  if sheet_type_str == "vertical" then
    cols = 1
    rows_count = frame_count
  elseif sheet_type_str == "rows" or sheet_type_str == "columns" then
    cols = columns or frame_count
    rows_count = math.ceil(frame_count / cols)
  else -- horizontal
    cols = frame_count
    rows_count = 1
  end

  local sheet_w = cols * fw + (cols - 1) * padding
  local sheet_h = rows_count * fh + (rows_count - 1) * padding

  local sheet = Image(sheet_w, sheet_h, sprite.colorMode)
  sheet:clear()

  for i = 0, frame_count - 1 do
    local frame_img = Image(sprite.spec)
    frame_img:drawSprite(sprite, from_frame + i)
    local col = i % cols
    local row = math.floor(i / cols)
    local dx = col * (fw + padding)
    local dy = row * (fh + padding)
    for y = 0, fh - 1 do
      for x = 0, fw - 1 do
        sheet:putPixel(dx + x, dy + y, frame_img:getPixel(x, y))
      end
    end
  end

  sheet:saveAs(path)

  return base.success({
    path = path,
    sheet_type = sheet_type_str,
    columns = cols,
    rows = rows_count,
    frame_count = frame_count,
    sheet_width = sheet_w,
    sheet_height = sheet_h,
  })
end

function export_cmds.export_gif(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local scale = base.optional_number(params, "scale", 1)

  if scale ~= 1 then
    local copy = Sprite(sprite)
    app.command.SpriteSize {
      ui = false,
      width = copy.width * scale,
      height = copy.height * scale,
      method = "nearest",
    }
    copy:saveCopyAs(path)
    copy:close()
  else
    sprite:saveCopyAs(path)
  end

  return base.success({ path = path, frames = #sprite.frames })
end

function export_cmds.export_tileset(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, e1 = base.require_string(params, "layer")
  if e1 then return e1 end
  local path, e2 = base.require_string(params, "path")
  if e2 then return e2 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end
  if not layer.isTilemap then
    return base.error(-32001, "Layer is not a tilemap: " .. layer_name)
  end

  local tileset = layer.tileset
  if not tileset then
    return base.error(-32001, "No tileset found")
  end

  local tw = tileset.grid.tileSize.width
  local th = tileset.grid.tileSize.height
  local count = #tileset

  local out_img = Image(tw * count, th, sprite.colorMode)
  out_img:clear()

  for i = 0, count - 1 do
    local tile = tileset:getTile(i)
    if tile then
      for y = 0, th - 1 do
        for x = 0, tw - 1 do
          out_img:putPixel(i * tw + x, y, tile:getPixel(x, y))
        end
      end
    end
  end

  out_img:saveAs(path)

  return base.success({
    path = path,
    tile_count = count,
    tile_width = tw,
    tile_height = th,
    image_width = tw * count,
    image_height = th,
  })
end

function export_cmds.export_layers(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local output_dir, e1 = base.require_string(params, "output_dir")
  if e1 then return e1 end

  local format = base.optional_string(params, "format", "png")
  local visible_only = base.optional_bool(params, "visible_only", false)

  local exported = {}
  local original_visibility = {}

  for _, layer in ipairs(sprite.layers) do
    original_visibility[layer.name] = layer.isVisible
  end

  for _, layer in ipairs(sprite.layers) do
    if layer.isGroup then goto continue end
    if visible_only and not layer.isVisible then goto continue end

    for _, l in ipairs(sprite.layers) do
      l.isVisible = (l == layer)
    end

    local ext = format == "aseprite" and ".aseprite" or ("." .. format)
    local file_path = output_dir .. "/" .. layer.name .. ext
    sprite:saveCopyAs(file_path)
    exported[#exported + 1] = { layer = layer.name, path = file_path }

    ::continue::
  end

  for _, layer in ipairs(sprite.layers) do
    if original_visibility[layer.name] ~= nil then
      layer.isVisible = original_visibility[layer.name]
    end
  end

  return base.success({ exported = exported, count = #exported })
end

function export_cmds.export_tags_as_sheets(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local output_dir, e1 = base.require_string(params, "output_dir")
  if e1 then return e1 end

  local sheet_type_str = base.optional_string(params, "sheet_type", "horizontal")
  local scale = base.optional_number(params, "scale", 1)
  local export_json = base.optional_bool(params, "json", false)

  local exported = {}
  local fw = sprite.width
  local fh = sprite.height

  for _, tag in ipairs(sprite.tags) do
    local from = tag.fromFrame.frameNumber
    local to = tag.toFrame.frameNumber
    local fc = to - from + 1

    local cols = (sheet_type_str == "vertical") and 1 or fc
    local rows = (sheet_type_str == "vertical") and fc or 1
    local sw = cols * fw
    local sh = rows * fh

    local sheet = Image(sw, sh, sprite.colorMode)
    sheet:clear()
    for i = 0, fc - 1 do
      local img = Image(sprite.spec)
      img:drawSprite(sprite, from + i)
      local dx = (sheet_type_str == "vertical") and 0 or (i * fw)
      local dy = (sheet_type_str == "vertical") and (i * fh) or 0
      for y = 0, fh - 1 do
        for x = 0, fw - 1 do
          sheet:putPixel(dx + x, dy + y, img:getPixel(x, y))
        end
      end
    end

    local png_path = output_dir .. "/" .. tag.name .. ".png"
    sheet:saveAs(png_path)
    exported[#exported + 1] = {
      tag = tag.name,
      path = png_path,
      frames = fc,
    }
  end

  return base.success({ exported = exported, count = #exported })
end

----------------------------------------------------------------------
-- Godot Commands
----------------------------------------------------------------------
local godot_cmds = {}

-- Helper: build animation data from tags
local function build_animation_data(sprite, sheet_type, columns)
  local frame_count = #sprite.frames
  local fw = sprite.width
  local fh = sprite.height

  local function frame_region(idx)
    local col, row
    if sheet_type == "horizontal" then
      col = idx
      row = 0
    elseif sheet_type == "vertical" then
      col = 0
      row = idx
    elseif sheet_type == "rows" or sheet_type == "columns" then
      local cols = columns or frame_count
      col = idx % cols
      row = math.floor(idx / cols)
    else
      col = idx
      row = 0
    end
    return { x = col * fw, y = row * fh, w = fw, h = fh }
  end

  local animations = {}

  if #sprite.tags > 0 then
    for _, tag in ipairs(sprite.tags) do
      local frames = {}
      for i = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do
        frames[#frames + 1] = {
          index = i - 1,
          region = frame_region(i - 1),
          duration_ms = math.floor(sprite.frames[i].duration * 1000),
        }
      end
      animations[#animations + 1] = {
        name = tag.name,
        frames = frames,
        loop = tag.repeats == 0,
        direction = tostring(tag.aniDir),
      }
    end
  else
    local frames = {}
    for i = 1, frame_count do
      frames[i] = {
        index = i - 1,
        region = frame_region(i - 1),
        duration_ms = math.floor(sprite.frames[i].duration * 1000),
      }
    end
    animations[1] = {
      name = "default",
      frames = frames,
      loop = true,
      direction = "forward",
    }
  end

  return {
    sprite_width = fw,
    sprite_height = fh,
    frame_count = frame_count,
    sheet_width = (sheet_type == "vertical") and fw or (fw * (columns or frame_count)),
    sheet_height = (sheet_type == "horizontal") and fh or (fh * math.ceil(frame_count / (columns or frame_count))),
    animations = animations,
  }
end

-- Helper: generate SpriteFrames .tres content
local function generate_tres(texture_res_path, anim_data)
  local lines = {}
  lines[#lines + 1] = '[gd_resource type="SpriteFrames" load_steps=2 format=3]'
  lines[#lines + 1] = ''
  lines[#lines + 1] = string.format('[ext_resource type="Texture2D" path="%s" id="1"]', texture_res_path)
  lines[#lines + 1] = ''

  local anim_entries = {}
  for _, anim in ipairs(anim_data.animations) do
    local frames_arr = {}
    for _, f in ipairs(anim.frames) do
      local r = f.region
      local atlas = string.format(
        '{"texture": ExtResource("1"), "region": Rect2(%d, %d, %d, %d), "duration": %.3f}',
        r.x, r.y, r.w, r.h,
        f.duration_ms / 1000.0
      )
      frames_arr[#frames_arr + 1] = atlas
    end

    local entry = string.format(
      '{"name": "%s", "speed": 1.0, "loop": %s, "frames": [%s]}',
      anim.name,
      anim.loop and "true" or "false",
      table.concat(frames_arr, ", ")
    )
    anim_entries[#anim_entries + 1] = entry
  end

  lines[#lines + 1] = '[resource]'
  lines[#lines + 1] = 'animations = [' .. table.concat(anim_entries, ", ") .. ']'

  return table.concat(lines, "\n")
end

function godot_cmds.export_for_godot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local output_dir, e1 = base.require_string(params, "output_dir")
  if e1 then return e1 end

  local name = base.optional_string(params, "name", nil)
  if not name then
    name = sprite.filename:match("([^/\\]+)%.%w+$") or "sprite"
  end

  local sheet_type_str = base.optional_string(params, "sheet_type", "horizontal")
  local scale = base.optional_number(params, "scale", 1)
  local trim = base.optional_bool(params, "trim", false)

  local sheet_types = {
    horizontal = SpriteSheetType.HORIZONTAL,
    vertical = SpriteSheetType.VERTICAL,
    rows = SpriteSheetType.ROWS,
    columns = SpriteSheetType.COLUMNS,
  }

  local png_path = output_dir .. "/" .. name .. ".png"
  local json_path = output_dir .. "/" .. name .. ".json"

  local fw = sprite.width
  local fh = sprite.height
  local fc = #sprite.frames

  local sheet_w, sheet_h
  if sheet_type_str == "vertical" then
    sheet_w = fw
    sheet_h = fh * fc
  else
    sheet_w = fw * fc
    sheet_h = fh
  end

  local sheet = Image(sheet_w, sheet_h, sprite.colorMode)
  sheet:clear()
  for i = 1, fc do
    local frame_img = Image(sprite.spec)
    frame_img:drawSprite(sprite, i)
    local dx, dy
    if sheet_type_str == "vertical" then
      dx = 0
      dy = (i - 1) * fh
    else
      dx = (i - 1) * fw
      dy = 0
    end
    for y = 0, fh - 1 do
      for x = 0, fw - 1 do
        sheet:putPixel(dx + x, dy + y, frame_img:getPixel(x, y))
      end
    end
  end
  sheet:saveAs(png_path)

  local anim_data = build_animation_data(sprite, sheet_type_str, nil)

  local res_path = "res://" .. name .. ".png"
  local tres_content = generate_tres(res_path, anim_data)
  local tres_path = output_dir .. "/" .. name .. ".tres"

  local f = io.open(tres_path, "w")
  if f then
    f:write(tres_content)
    f:close()
  end

  return base.success({
    png_path = png_path,
    json_path = json_path,
    tres_path = tres_path,
    animations = #anim_data.animations,
    total_frames = anim_data.frame_count,
  })
end

function godot_cmds.export_atlas_texture(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local output_dir, e1 = base.require_string(params, "output_dir")
  if e1 then return e1 end
  local texture_path, e2 = base.require_string(params, "texture_path")
  if e2 then return e2 end

  local exported = {}
  for _, slice in ipairs(sprite.slices) do
    local b = slice.bounds
    local content = string.format(
      '[gd_resource type="AtlasTexture" load_steps=2 format=3]\n\n' ..
      '[ext_resource type="Texture2D" path="%s" id="1"]\n\n' ..
      '[resource]\n' ..
      'atlas = ExtResource("1")\n' ..
      'region = Rect2(%d, %d, %d, %d)\n',
      texture_path, b.x, b.y, b.width, b.height
    )
    local tres_path = output_dir .. "/" .. slice.name .. ".tres"
    local f = io.open(tres_path, "w")
    if f then
      f:write(content)
      f:close()
      exported[#exported + 1] = { name = slice.name, path = tres_path }
    end
  end

  return base.success({ exported = exported, count = #exported })
end

function godot_cmds.export_9patch_for_godot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local slice_name, e1 = base.require_string(params, "slice_name")
  if e1 then return e1 end
  local output_dir, e2 = base.require_string(params, "output_dir")
  if e2 then return e2 end
  local texture_path, e3 = base.require_string(params, "texture_path")
  if e3 then return e3 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == slice_name then target = slice; break end
  end
  if not target then
    return base.error(-32001, "Slice not found: " .. slice_name)
  end

  if not target.center then
    return base.error(-32001, "Slice has no 9-patch center data: " .. slice_name)
  end

  local b = target.bounds
  local c = target.center

  local margin_left = c.x
  local margin_top = c.y
  local margin_right = b.width - (c.x + c.width)
  local margin_bottom = b.height - (c.y + c.height)

  local content = string.format(
    '# 9-patch data for %s\n' ..
    '# Use with NinePatchRect node in Godot\n' ..
    '# texture = "%s"\n' ..
    '# region = Rect2(%d, %d, %d, %d)\n' ..
    '# patch_margin_left = %d\n' ..
    '# patch_margin_top = %d\n' ..
    '# patch_margin_right = %d\n' ..
    '# patch_margin_bottom = %d\n',
    slice_name, texture_path,
    b.x, b.y, b.width, b.height,
    margin_left, margin_top, margin_right, margin_bottom
  )

  local info_path = output_dir .. "/" .. slice_name .. "_9patch.txt"
  local f = io.open(info_path, "w")
  if f then
    f:write(content)
    f:close()
  end

  return base.success({
    slice = slice_name,
    region = { x = b.x, y = b.y, width = b.width, height = b.height },
    margins = {
      left = margin_left,
      top = margin_top,
      right = margin_right,
      bottom = margin_bottom,
    },
    info_path = info_path,
  })
end

function godot_cmds.export_tileset_for_godot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local layer_name, e1 = base.require_string(params, "layer")
  if e1 then return e1 end
  local output_dir, e2 = base.require_string(params, "output_dir")
  if e2 then return e2 end

  local layer = base.find_layer(sprite, layer_name)
  if not layer then return base.error_layer_not_found(layer_name) end
  if not layer.isTilemap then
    return base.error(-32001, "Layer is not a tilemap: " .. layer_name)
  end

  local tileset = layer.tileset
  local tw = base.optional_number(params, "tile_size", tileset.grid.tileSize.width)
  local th = tileset.grid.tileSize.height
  local count = #tileset

  local img_path = output_dir .. "/tileset.png"
  local cols = math.ceil(math.sqrt(count))
  local rows = math.ceil(count / cols)
  local out_img = Image(tw * cols, th * rows, sprite.colorMode)
  out_img:clear()

  for i = 0, count - 1 do
    local tile = tileset:getTile(i)
    if tile then
      local col = i % cols
      local row = math.floor(i / cols)
      for y = 0, th - 1 do
        for x = 0, tw - 1 do
          out_img:putPixel(col * tw + x, row * th + y, tile:getPixel(x, y))
        end
      end
    end
  end
  out_img:saveAs(img_path)

  local tres_path = output_dir .. "/tileset.tres"
  local tres_content = string.format(
    '[gd_resource type="TileSet" load_steps=2 format=3]\n\n' ..
    '[ext_resource type="Texture2D" path="res://tileset.png" id="1"]\n\n' ..
    '[resource]\n' ..
    'tile_size = Vector2i(%d, %d)\n',
    tw, th
  )

  local f = io.open(tres_path, "w")
  if f then
    f:write(tres_content)
    f:close()
  end

  return base.success({
    image_path = img_path,
    tres_path = tres_path,
    tile_count = count,
    tile_width = tw,
    tile_height = th,
  })
end

function godot_cmds.get_animation_data(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local sheet_type = base.optional_string(params, "sheet_type", "horizontal")
  local columns = base.optional_number(params, "columns", nil)

  local data = build_animation_data(sprite, sheet_type, columns)
  return base.success(data)
end

function godot_cmds.generate_spriteframes_tres(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local texture_path, e1 = base.require_string(params, "texture_path")
  if e1 then return e1 end
  local output_path, e2 = base.require_string(params, "output_path")
  if e2 then return e2 end

  local sheet_type = base.optional_string(params, "sheet_type", "horizontal")
  local columns = base.optional_number(params, "columns", nil)

  local anim_data = build_animation_data(sprite, sheet_type, columns)
  local tres_content = generate_tres(texture_path, anim_data)

  local f = io.open(output_path, "w")
  if not f then
    return base.error(-32603, "Failed to write .tres file: " .. output_path)
  end
  f:write(tres_content)
  f:close()

  return base.success({
    output_path = output_path,
    animations = #anim_data.animations,
  })
end

function godot_cmds.sync_to_godot_project(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local godot_path, e1 = base.require_string(params, "godot_project_path")
  if e1 then return e1 end

  local target_dir = base.optional_string(params, "target_dir", "assets/sprites")
  local name = base.optional_string(params, "name", nil)
  if not name then
    name = sprite.filename:match("([^/\\]+)%.%w+$") or "sprite"
  end
  local scale = base.optional_number(params, "scale", 1)

  local full_dir = godot_path .. "/" .. target_dir

  os.execute('mkdir "' .. full_dir .. '" 2>nul')

  local result = godot_cmds.export_for_godot({
    output_dir = full_dir,
    name = name,
    scale = scale,
  })

  if result.result then
    local res_texture = "res://" .. target_dir .. "/" .. name .. ".png"
    local anim_data = build_animation_data(sprite, "horizontal", nil)
    local tres_content = generate_tres(res_texture, anim_data)
    local tres_path = full_dir .. "/" .. name .. ".tres"
    local f = io.open(tres_path, "w")
    if f then
      f:write(tres_content)
      f:close()
    end
    result.result.tres_texture_path = res_texture
  end

  return result
end

function godot_cmds.batch_export_for_godot(params)
  local godot_path, e1 = base.require_string(params, "godot_project_path")
  if e1 then return e1 end

  local target_dir = base.optional_string(params, "target_dir", "assets/sprites")
  local scale = base.optional_number(params, "scale", 1)
  local full_dir = godot_path .. "/" .. target_dir

  os.execute('mkdir "' .. full_dir .. '" 2>nul')

  local exported = {}
  for _, sprite in ipairs(app.sprites) do
    app.sprite = sprite
    local name = sprite.filename:match("([^/\\]+)%.%w+$") or "sprite"
    local result = godot_cmds.export_for_godot({
      output_dir = full_dir,
      name = name,
      scale = scale,
    })
    exported[#exported + 1] = {
      sprite = sprite.filename,
      name = name,
      success = result.result ~= nil,
    }
  end

  return base.success({ exported = exported, count = #exported })
end

----------------------------------------------------------------------
-- Analysis Commands
----------------------------------------------------------------------
local analysis_cmds = {}

function analysis_cmds.get_color_stats(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local scope = base.optional_string(params, "scope", "sprite")
  local palette = sprite.palettes[1]
  local cm = sprite.colorMode
  local color_counts = {}
  local total_pixels = 0

  local function count_image(img)
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local pv = img:getPixel(x, y)
        local c = color_util.pixel_to_color(pv, cm, palette)
        if c.alpha > 0 then
          local hex = color_util.to_hex(c, false)
          color_counts[hex] = (color_counts[hex] or 0) + 1
          total_pixels = total_pixels + 1
        end
      end
    end
  end

  if scope == "sprite" then
    for _, layer in ipairs(sprite.layers) do
      if not layer.isGroup then
        for _, frame in ipairs(sprite.frames) do
          local cel = layer:cel(frame.frameNumber)
          if cel then count_image(cel.image) end
        end
      end
    end
  elseif scope == "layer" then
    local layer = app.layer
    if layer and not layer.isGroup then
      for _, frame in ipairs(sprite.frames) do
        local cel = layer:cel(frame.frameNumber)
        if cel then count_image(cel.image) end
      end
    end
  else
    local cel = app.cel
    if cel then count_image(cel.image) end
  end

  local sorted = {}
  for hex, count in pairs(color_counts) do
    sorted[#sorted + 1] = { color = hex, count = count, percent = (count / math.max(1, total_pixels)) * 100 }
  end
  table.sort(sorted, function(a, b) return a.count > b.count end)

  local top = {}
  for i = 1, math.min(20, #sorted) do
    top[i] = sorted[i]
  end

  return base.success({
    unique_colors = #sorted,
    total_pixels = total_pixels,
    top_colors = top,
    scope = scope,
  })
end

function analysis_cmds.compare_frames(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local fa, e1 = base.require_number(params, "frame_a")
  if e1 then return e1 end
  local fb, e2 = base.require_number(params, "frame_b")
  if e2 then return e2 end

  if fa < 1 or fa > #sprite.frames or fb < 1 or fb > #sprite.frames then
    return base.error_invalid_params("Frame number out of range")
  end

  local img_a = Image(sprite.spec)
  local img_b = Image(sprite.spec)
  img_a:drawSprite(sprite, fa)
  img_b:drawSprite(sprite, fb)

  local diff_count = 0
  local total = sprite.width * sprite.height

  for y = 0, sprite.height - 1 do
    for x = 0, sprite.width - 1 do
      if img_a:getPixel(x, y) ~= img_b:getPixel(x, y) then
        diff_count = diff_count + 1
      end
    end
  end

  return base.success({
    frame_a = fa,
    frame_b = fb,
    different_pixels = diff_count,
    total_pixels = total,
    difference_percent = (diff_count / total) * 100,
    identical = diff_count == 0,
  })
end

function analysis_cmds.compare_screenshots(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local fa, e1 = base.require_number(params, "frame_a")
  if e1 then return e1 end
  local fb, e2 = base.require_number(params, "frame_b")
  if e2 then return e2 end

  if fa < 1 or fa > #sprite.frames or fb < 1 or fb > #sprite.frames then
    return base.error_invalid_params("Frame number out of range")
  end

  local img_a = Image(sprite.spec)
  local img_b = Image(sprite.spec)
  img_a:drawSprite(sprite, fa)
  img_b:drawSprite(sprite, fb)

  local diff_img = Image(sprite.width, sprite.height, ColorMode.RGB)
  diff_img:clear()
  local cm = sprite.colorMode
  local palette = sprite.palettes[1]
  local diff_count = 0

  for y = 0, sprite.height - 1 do
    for x = 0, sprite.width - 1 do
      local pv_a = img_a:getPixel(x, y)
      local pv_b = img_b:getPixel(x, y)
      if pv_a ~= pv_b then
        diff_count = diff_count + 1
        local c_a = color_util.pixel_to_color(pv_a, cm, palette)
        local c_b = color_util.pixel_to_color(pv_b, cm, palette)
        if c_a.alpha == 0 then
          diff_img:putPixel(x, y, app.pixelColor.rgba(0, 100, 255, 255))
        elseif c_b.alpha == 0 then
          diff_img:putPixel(x, y, app.pixelColor.rgba(0, 255, 100, 255))
        else
          diff_img:putPixel(x, y, app.pixelColor.rgba(255, 50, 50, 255))
        end
      end
    end
  end

  local tmp = app.fs.tempPath .. app.fs.pathSeparator .. "mcp_diff.png"
  diff_img:saveAs(tmp)
  local f = io.open(tmp, "rb")
  if not f then return base.error(-32603, "Failed to save diff image") end
  local data = f:read("*a")
  f:close()
  os.remove(tmp)

  local b64 = _G.MCP_BASE64
  return base.success({
    diff_image = b64.encode(data),
    frame_a = fa,
    frame_b = fb,
    different_pixels = diff_count,
    total_pixels = sprite.width * sprite.height,
    difference_percent = (diff_count / (sprite.width * sprite.height)) * 100,
  })
end

function analysis_cmds.find_unused_colors(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  if sprite.colorMode ~= ColorMode.INDEXED then
    return base.error(-32001, "find_unused_colors only works with indexed color mode sprites")
  end

  local palette = sprite.palettes[1]
  local used = {}

  for _, layer in ipairs(sprite.layers) do
    if not layer.isGroup then
      for _, frame in ipairs(sprite.frames) do
        local cel = layer:cel(frame.frameNumber)
        if cel then
          for y = 0, cel.image.height - 1 do
            for x = 0, cel.image.width - 1 do
              used[cel.image:getPixel(x, y)] = true
            end
          end
        end
      end
    end
  end

  local unused = {}
  for i = 0, #palette - 1 do
    if not used[i] then
      unused[#unused + 1] = {
        index = i,
        color = color_util.to_hex(palette:getColor(i)),
      }
    end
  end

  return base.success({
    unused_colors = unused,
    unused_count = #unused,
    palette_size = #palette,
  })
end

function analysis_cmds.get_sprite_bounds(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local palette = sprite.palettes[1]
  local cm = sprite.colorMode

  local min_x, min_y = sprite.width, sprite.height
  local max_x, max_y = -1, -1

  local layer_name = base.optional_string(params, "layer", nil)
  local frame_num = base.optional_number(params, "frame", nil)

  local function scan_image(img, ox, oy)
    for y = 0, img.height - 1 do
      for x = 0, img.width - 1 do
        local pv = img:getPixel(x, y)
        local c = color_util.pixel_to_color(pv, cm, palette)
        if c.alpha > 0 then
          local gx, gy = ox + x, oy + y
          if gx < min_x then min_x = gx end
          if gy < min_y then min_y = gy end
          if gx > max_x then max_x = gx end
          if gy > max_y then max_y = gy end
        end
      end
    end
  end

  local layers = {}
  if layer_name then
    local l = base.find_layer(sprite, layer_name)
    if l then layers[1] = l end
  else
    for _, l in ipairs(sprite.layers) do
      if not l.isGroup and l.isVisible then
        layers[#layers + 1] = l
      end
    end
  end

  local frames = {}
  if frame_num then
    frames[1] = sprite.frames[frame_num]
  else
    frames = sprite.frames
  end

  for _, layer in ipairs(layers) do
    for _, frame in ipairs(frames) do
      local cel = layer:cel(frame.frameNumber)
      if cel then
        scan_image(cel.image, cel.position.x, cel.position.y)
      end
    end
  end

  if max_x < 0 then
    return base.success({ empty = true })
  end

  return base.success({
    x = min_x,
    y = min_y,
    width = max_x - min_x + 1,
    height = max_y - min_y + 1,
    empty = false,
  })
end

function analysis_cmds.validate_animation(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local issues = {}

  for i, frame in ipairs(sprite.frames) do
    local has_content = false
    for _, layer in ipairs(sprite.layers) do
      if not layer.isGroup and layer.isVisible then
        local cel = layer:cel(frame.frameNumber)
        if cel then has_content = true; break end
      end
    end
    if not has_content then
      issues[#issues + 1] = {
        type = "empty_frame",
        frame = i,
        message = string.format("Frame %d has no visible content", i),
      }
    end
  end

  for _, tag in ipairs(sprite.tags) do
    local durations = {}
    for i = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do
      local d = sprite.frames[i].duration
      durations[d] = (durations[d] or 0) + 1
    end
    local unique = 0
    for _ in pairs(durations) do unique = unique + 1 end
    if unique > 1 then
      issues[#issues + 1] = {
        type = "inconsistent_duration",
        tag = tag.name,
        message = string.format("Tag '%s' has %d different frame durations", tag.name, unique),
      }
    end
  end

  if #sprite.tags > 0 then
    local covered = {}
    for _, tag in ipairs(sprite.tags) do
      for i = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do
        covered[i] = true
      end
    end
    for i = 1, #sprite.frames do
      if not covered[i] then
        issues[#issues + 1] = {
          type = "orphan_frame",
          frame = i,
          message = string.format("Frame %d is not covered by any animation tag", i),
        }
      end
    end
  end

  return base.success({
    valid = #issues == 0,
    issue_count = #issues,
    issues = issues,
  })
end

----------------------------------------------------------------------
-- Editor Commands
----------------------------------------------------------------------
local editor_cmds = {}

function editor_cmds.execute_script(params)
  local code, err = base.require_string(params, "code")
  if err then return err end

  local fn, load_err = load(code, "mcp_script", "t")
  if not fn then
    return base.error(-32603, "Lua compile error: " .. tostring(load_err))
  end

  local ok, result = pcall(fn)
  if not ok then
    return base.error(-32603, "Lua runtime error: " .. tostring(result))
  end

  if result ~= nil then
    if type(result) == "table" then
      return base.success(result)
    else
      return base.success({ result = tostring(result) })
    end
  end

  return base.success({ executed = true })
end

function editor_cmds.undo(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local steps = base.optional_number(params, "steps", 1)
  for i = 1, steps do
    app.command.Undo()
  end

  return base.success({ undone = steps })
end

function editor_cmds.redo(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local steps = base.optional_number(params, "steps", 1)
  for i = 1, steps do
    app.command.Redo()
  end

  return base.success({ redone = steps })
end

----------------------------------------------------------------------
-- Template Commands
----------------------------------------------------------------------
local template_cmds = {}

function template_cmds.create_character_template(params)
  local size = base.optional_number(params, "size", 32)
  local frames = base.optional_number(params, "frames", 4)
  local animations = params.animations

  local sprite = Sprite(size, size, ColorMode.RGB)
  if not sprite then
    return base.error(-32603, "Failed to create sprite")
  end

  local anim_defs
  if animations and #animations > 0 then
    anim_defs = {}
    for i = 1, #animations do
      anim_defs[i] = { name = animations[i].name or ("anim_" .. i), frames = animations[i].frames or 4 }
    end
  else
    anim_defs = {
      { name = "idle", frames = 4 },
      { name = "walk", frames = 6 },
      { name = "attack", frames = 4 },
    }
  end

  local total_frames = 0
  for _, ad in ipairs(anim_defs) do
    total_frames = total_frames + ad.frames
  end

  app.transaction("Create Character Template", function()
    sprite.layers[1].name = "body"

    local outline_layer = sprite:newLayer()
    outline_layer.name = "outline"
    outline_layer.stackIndex = 1

    local effects_layer = sprite:newLayer()
    effects_layer.name = "effects"

    local shadow_layer = sprite:newLayer()
    shadow_layer.name = "shadow"
    shadow_layer.opacity = 128
    shadow_layer.stackIndex = 1

    for i = 2, total_frames do
      sprite:newFrame(sprite.frames[1])
      for _, layer in ipairs(sprite.layers) do
        if not layer.isGroup then
          local cel = layer:cel(i)
          if cel then sprite:deleteCel(cel) end
        end
      end
    end

    local frame_offset = 1
    for _, ad in ipairs(anim_defs) do
      local tag = sprite:newTag(frame_offset, frame_offset + ad.frames - 1)
      tag.name = ad.name
      frame_offset = frame_offset + ad.frames
    end

    for i = 1, #sprite.frames do
      sprite.frames[i].duration = 0.1
    end
  end)

  local tag_info = {}
  for i, tag in ipairs(sprite.tags) do
    tag_info[i] = {
      name = tag.name,
      from_frame = tag.fromFrame.frameNumber,
      to_frame = tag.toFrame.frameNumber,
    }
  end

  return base.success({
    size = size,
    total_frames = total_frames,
    layers = { "shadow", "outline", "body", "effects" },
    animations = tag_info,
  })
end

function template_cmds.create_tileset_template(params)
  local tile_size = base.optional_number(params, "tile_size", 16)
  local columns = base.optional_number(params, "columns", 8)
  local rows = base.optional_number(params, "rows", 8)

  local width = tile_size * columns
  local height = tile_size * rows

  local sprite = Sprite(width, height, ColorMode.RGB)
  if not sprite then
    return base.error(-32603, "Failed to create sprite")
  end

  app.transaction("Create Tileset Template", function()
    sprite.layers[1].name = "tiles"
    sprite.gridBounds = Rectangle(0, 0, tile_size, tile_size)

    local grid_layer = sprite:newLayer()
    grid_layer.name = "grid"
    grid_layer.opacity = 60

    local grid_color = app.pixelColor.rgba(255, 255, 255, 80)
    local cel = grid_layer:cel(1)
    if not cel then
      local img = Image(width, height, ColorMode.RGB)
      img:clear()
      cel = sprite:newCel(grid_layer, 1, img, Point(0, 0))
    end

    local img = cel.image
    for col = 1, columns - 1 do
      local x = col * tile_size
      for y = 0, height - 1 do
        img:putPixel(x, y, grid_color)
      end
    end
    for row = 1, rows - 1 do
      local y = row * tile_size
      for x = 0, width - 1 do
        img:putPixel(x, y, grid_color)
      end
    end
  end)

  return base.success({
    tile_size = tile_size,
    columns = columns,
    rows = rows,
    width = width,
    height = height,
    layers = { "tiles", "grid" },
  })
end

----------------------------------------------------------------------
-- Register all commands into handlers table
----------------------------------------------------------------------
local function load_commands()
  -- Sprite commands
  handlers["create_sprite"] = sprite_cmds.create_sprite
  handlers["open_sprite"] = sprite_cmds.open_sprite
  handlers["save_sprite"] = sprite_cmds.save_sprite
  handlers["close_sprite"] = sprite_cmds.close_sprite
  handlers["get_sprite_info"] = sprite_cmds.get_sprite_info
  handlers["list_open_sprites"] = sprite_cmds.list_open_sprites
  handlers["set_active_sprite"] = sprite_cmds.set_active_sprite
  handlers["resize_sprite"] = sprite_cmds.resize_sprite
  handlers["crop_sprite"] = sprite_cmds.crop_sprite
  handlers["flatten_sprite"] = sprite_cmds.flatten_sprite
  handlers["get_sprite_screenshot"] = sprite_cmds.get_sprite_screenshot
  handlers["set_sprite_grid"] = sprite_cmds.set_sprite_grid

  -- Layer commands
  handlers["get_layers"] = layer_cmds.get_layers
  handlers["add_layer"] = layer_cmds.add_layer
  handlers["delete_layer"] = layer_cmds.delete_layer
  handlers["rename_layer"] = layer_cmds.rename_layer
  handlers["set_layer_visibility"] = layer_cmds.set_layer_visibility
  handlers["set_layer_opacity"] = layer_cmds.set_layer_opacity
  handlers["set_layer_blend_mode"] = layer_cmds.set_layer_blend_mode
  handlers["reorder_layer"] = layer_cmds.reorder_layer
  handlers["duplicate_layer"] = layer_cmds.duplicate_layer
  handlers["merge_layer_down"] = layer_cmds.merge_layer_down

  -- Frame commands
  handlers["get_frames"] = frame_cmds.get_frames
  handlers["add_frame"] = frame_cmds.add_frame
  handlers["delete_frame"] = frame_cmds.delete_frame
  handlers["set_frame_duration"] = frame_cmds.set_frame_duration
  handlers["set_frame_range_duration"] = frame_cmds.set_frame_range_duration
  handlers["set_active_frame"] = frame_cmds.set_active_frame
  handlers["duplicate_frame"] = frame_cmds.duplicate_frame
  handlers["reverse_frames"] = frame_cmds.reverse_frames

  -- Cel commands
  handlers["get_cel"] = cel_cmds.get_cel
  handlers["set_cel_position"] = cel_cmds.set_cel_position
  handlers["set_cel_opacity"] = cel_cmds.set_cel_opacity
  handlers["clear_cel"] = cel_cmds.clear_cel
  handlers["link_cels"] = cel_cmds.link_cels

  -- Drawing commands
  handlers["put_pixel"] = drawing_cmds.put_pixel
  handlers["put_pixels"] = drawing_cmds.put_pixels
  handlers["get_pixel"] = drawing_cmds.get_pixel
  handlers["get_image_data"] = drawing_cmds.get_image_data
  handlers["set_image_data"] = drawing_cmds.set_image_data
  handlers["draw_line"] = drawing_cmds.draw_line
  handlers["draw_rect"] = drawing_cmds.draw_rect
  handlers["draw_ellipse"] = drawing_cmds.draw_ellipse
  handlers["flood_fill"] = drawing_cmds.flood_fill
  handlers["draw_brush_stroke"] = drawing_cmds.draw_brush_stroke
  handlers["clear_image"] = drawing_cmds.clear_image
  handlers["replace_color"] = drawing_cmds.replace_color
  handlers["outline"] = drawing_cmds.outline

  -- Selection commands
  handlers["select_rect"] = selection_cmds.select_rect
  handlers["select_ellipse"] = selection_cmds.select_ellipse
  handlers["select_all"] = selection_cmds.select_all
  handlers["deselect"] = selection_cmds.deselect
  handlers["select_by_color"] = selection_cmds.select_by_color
  handlers["get_selection"] = selection_cmds.get_selection
  handlers["invert_selection"] = selection_cmds.invert_selection

  -- Palette commands
  handlers["get_palette"] = palette_cmds.get_palette
  handlers["set_palette_color"] = palette_cmds.set_palette_color
  handlers["set_palette"] = palette_cmds.set_palette
  handlers["add_palette_color"] = palette_cmds.add_palette_color
  handlers["resize_palette"] = palette_cmds.resize_palette
  handlers["load_palette"] = palette_cmds.load_palette
  handlers["save_palette"] = palette_cmds.save_palette
  handlers["set_fg_color"] = palette_cmds.set_fg_color
  handlers["set_bg_color"] = palette_cmds.set_bg_color
  handlers["generate_palette_from_sprite"] = palette_cmds.generate_palette_from_sprite
  handlers["sort_palette"] = palette_cmds.sort_palette
  handlers["import_palette_from_image"] = palette_cmds.import_palette_from_image

  -- Tag commands
  handlers["get_tags"] = tag_cmds.get_tags
  handlers["create_tag"] = tag_cmds.create_tag
  handlers["delete_tag"] = tag_cmds.delete_tag
  handlers["rename_tag"] = tag_cmds.rename_tag
  handlers["set_tag_color"] = tag_cmds.set_tag_color
  handlers["set_tag_range"] = tag_cmds.set_tag_range

  -- Slice commands
  handlers["get_slices"] = slice_cmds.get_slices
  handlers["create_slice"] = slice_cmds.create_slice
  handlers["delete_slice"] = slice_cmds.delete_slice
  handlers["set_slice_9patch"] = slice_cmds.set_slice_9patch
  handlers["set_slice_pivot"] = slice_cmds.set_slice_pivot

  -- Tilemap commands
  handlers["create_tilemap_layer"] = tilemap_cmds.create_tilemap_layer
  handlers["get_tileset"] = tilemap_cmds.get_tileset
  handlers["set_tile"] = tilemap_cmds.set_tile
  handlers["get_tile"] = tilemap_cmds.get_tile
  handlers["get_tilemap_info"] = tilemap_cmds.get_tilemap_info

  -- Export commands
  handlers["export_png"] = export_cmds.export_png
  handlers["export_sprite_sheet"] = export_cmds.export_sprite_sheet
  handlers["export_gif"] = export_cmds.export_gif
  handlers["export_tileset"] = export_cmds.export_tileset
  handlers["export_layers"] = export_cmds.export_layers
  handlers["export_tags_as_sheets"] = export_cmds.export_tags_as_sheets

  -- Godot commands
  handlers["export_for_godot"] = godot_cmds.export_for_godot
  handlers["export_atlas_texture"] = godot_cmds.export_atlas_texture
  handlers["export_9patch_for_godot"] = godot_cmds.export_9patch_for_godot
  handlers["export_tileset_for_godot"] = godot_cmds.export_tileset_for_godot
  handlers["get_animation_data"] = godot_cmds.get_animation_data
  handlers["generate_spriteframes_tres"] = godot_cmds.generate_spriteframes_tres
  handlers["sync_to_godot_project"] = godot_cmds.sync_to_godot_project
  handlers["batch_export_for_godot"] = godot_cmds.batch_export_for_godot

  -- Analysis commands
  handlers["get_color_stats"] = analysis_cmds.get_color_stats
  handlers["compare_frames"] = analysis_cmds.compare_frames
  handlers["compare_screenshots"] = analysis_cmds.compare_screenshots
  handlers["find_unused_colors"] = analysis_cmds.find_unused_colors
  handlers["get_sprite_bounds"] = analysis_cmds.get_sprite_bounds
  handlers["validate_animation"] = analysis_cmds.validate_animation

  -- Editor commands
  handlers["execute_script"] = editor_cmds.execute_script
  handlers["undo"] = editor_cmds.undo
  handlers["redo"] = editor_cmds.redo

  -- Template commands
  handlers["create_character_template"] = template_cmds.create_character_template
  handlers["create_tileset_template"] = template_cmds.create_tileset_template

  local total = 0
  for _ in pairs(handlers) do total = total + 1 end
  print("[MCP] Total commands registered: " .. total)
end

----------------------------------------------------------------------
-- Helper
----------------------------------------------------------------------
local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

----------------------------------------------------------------------
-- JSON-RPC dispatch
----------------------------------------------------------------------
local function dispatch(method, params)
  if method == "ping" then
    return { method = "pong" }
  end

  if method == "get_version" then
    return { result = { version = VERSION, tool_count = count_keys(handlers) } }
  end

  local handler = handlers[method]
  if not handler then
    return {
      error = {
        code = -32601,
        message = "Method not found: " .. tostring(method),
      }
    }
  end

  local ok, result = pcall(handler, params or {})
  if not ok then
    return {
      error = {
        code = -32603,
        message = "Internal error: " .. tostring(result),
      }
    }
  end

  return result
end

----------------------------------------------------------------------
-- WebSocket message handler
----------------------------------------------------------------------
local function on_message(msg_data)
  local ok, request = pcall(json.decode, msg_data)
  if not ok or not request then
    print("[MCP] Failed to parse JSON: " .. tostring(msg_data):sub(1, 100))
    return
  end

  local method = request.method
  local params = request.params or {}
  local id = request.id

  local response = dispatch(method, params)

  if id then
    response.jsonrpc = "2.0"
    response.id = id

    local ok2, encoded = pcall(json.encode, response)
    if ok2 and ws then
      ws:sendText(encoded)
    else
      print("[MCP] Failed to encode response: " .. tostring(encoded))
    end
  elseif response and response.method == "pong" then
    local ok2, encoded = pcall(json.encode, { jsonrpc = "2.0", method = "pong" })
    if ok2 and ws then
      ws:sendText(encoded)
    end
  end
end

----------------------------------------------------------------------
-- WebSocket connection
----------------------------------------------------------------------
local function connect()
  if ws then
    pcall(function() ws:close() end)
    ws = nil
  end

  local url = "ws://127.0.0.1:" .. port
  print("[MCP] Connecting to " .. url .. "...")

  ws = WebSocket {
    url = url,
    deflate = false,
    minreconnectwait = 2,
    maxreconnectwait = 5,
    onreceive = function(mt, data, err)
      if mt == WebSocketMessageType.OPEN then
        connected = true
        print("[MCP] Connected to MCP server")
        if reconnect_timer then
          reconnect_timer:stop()
          reconnect_timer = nil
        end
      elseif mt == WebSocketMessageType.TEXT then
        on_message(data)
      elseif mt == WebSocketMessageType.CLOSE then
        connected = false
        print("[MCP] Disconnected from MCP server")
        start_reconnect()
      elseif mt == WebSocketMessageType.ERROR then
        connected = false
        print("[MCP] WebSocket error: " .. tostring(err))
        start_reconnect()
      end
    end
  }
  ws:connect()
  print("[MCP] WebSocket connect() called")
end

----------------------------------------------------------------------
-- Reconnection using Timer
----------------------------------------------------------------------
function start_reconnect()
  if reconnect_timer then return end

  print("[MCP] Will attempt reconnection every " .. RECONNECT_INTERVAL_MS .. "ms")

  reconnect_timer = Timer {
    interval = RECONNECT_INTERVAL_MS / 1000.0,
    ontick = function()
      if not connected and not ws then
        connect()
      elseif connected then
        if reconnect_timer then
          reconnect_timer:stop()
          reconnect_timer = nil
        end
      end
    end
  }
  reconnect_timer:start()
end

----------------------------------------------------------------------
-- Plugin lifecycle
----------------------------------------------------------------------
function init(plugin)
  print("[MCP] Aseprite MCP Pro v" .. VERSION .. " initializing...")

  if plugin.preferences and plugin.preferences.port then
    port = plugin.preferences.port
  end

  load_commands()

  connect()

  plugin:newCommand {
    id = "mcp_reconnect",
    title = "MCP Pro: Reconnect",
    group = "help_about",
    onclick = function()
      print("[MCP] Manual reconnect requested")
      connect()
    end,
  }

  plugin:newCommand {
    id = "mcp_status",
    title = "MCP Pro: Status",
    group = "help_about",
    onclick = function()
      local status = connected and "Connected" or "Disconnected"
      app.alert {
        title = "Aseprite MCP Pro",
        text = {
          "Version: " .. VERSION,
          "Status: " .. status,
          "Port: " .. port,
          "Commands: " .. count_keys(handlers),
        },
      }
    end,
  }

  plugin:newCommand {
    id = "mcp_settings",
    title = "MCP Pro: Settings",
    group = "help_about",
    onclick = function()
      local dlg = Dialog("MCP Pro Settings")
      dlg:number { id = "port", label = "Server Port:", text = tostring(port) }
      dlg:button { id = "ok", text = "Save" }
      dlg:button { id = "cancel", text = "Cancel" }
      dlg:show()

      if dlg.data.ok then
        port = math.floor(dlg.data.port)
        plugin.preferences.port = port
        print("[MCP] Port changed to " .. port .. ". Reconnecting...")
        connect()
      end
    end,
  }
end

function exit(plugin)
  print("[MCP] Aseprite MCP Pro shutting down...")
  if reconnect_timer then
    reconnect_timer:stop()
    reconnect_timer = nil
  end
  if ws then
    pcall(function() ws:close() end)
    ws = nil
  end
  connected = false
end
