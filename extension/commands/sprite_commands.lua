local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    create_sprite = M.create_sprite,
    open_sprite = M.open_sprite,
    save_sprite = M.save_sprite,
    close_sprite = M.close_sprite,
    get_sprite_info = M.get_sprite_info,
    list_open_sprites = M.list_open_sprites,
    set_active_sprite = M.set_active_sprite,
    resize_sprite = M.resize_sprite,
    crop_sprite = M.crop_sprite,
    flatten_sprite = M.flatten_sprite,
    get_sprite_screenshot = M.get_sprite_screenshot,
    set_sprite_grid = M.set_sprite_grid,
  }
end

function M.create_sprite(params)
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

function M.open_sprite(params)
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

function M.save_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path = base.optional_string(params, "path", nil)
  if path then
    sprite:saveCopyAs(path)
  else
    app.command.SaveFile()
  end

  return base.success({ filename = sprite.filename })
end

function M.close_sprite(params)
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

function M.get_sprite_info(params)
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

function M.list_open_sprites(params)
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

function M.set_active_sprite(params)
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

function M.resize_sprite(params)
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

function M.crop_sprite(params)
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

function M.flatten_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  app.command.FlattenLayers()

  return base.success({
    layers = #sprite.layers,
  })
end

function M.get_sprite_screenshot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num = base.optional_number(params, "frame", nil)
  if frame_num then
    app.frame = sprite.frames[frame_num]
  end

  -- Save flattened copy to temp file
  local tmp_path = os.tmpname() .. ".png"
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

  -- Base64 encode
  local b64 = require("utils.base64")
  return base.success({
    image = b64.encode(data),
    width = sprite.width,
    height = sprite.height,
    frame = app.frame.frameNumber,
  })
end

function M.set_sprite_grid(params)
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

return M
