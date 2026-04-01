local base = require("commands.base")
local M = {}

function M.get_commands()
  return {
    export_png = M.export_png,
    export_sprite_sheet = M.export_sprite_sheet,
    export_gif = M.export_gif,
    export_tileset = M.export_tileset,
    export_layers = M.export_layers,
    export_tags_as_sheets = M.export_tags_as_sheets,
  }
end

function M.export_png(params)
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

function M.export_sprite_sheet(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local sheet_type_str = base.optional_string(params, "sheet_type", "horizontal")
  local columns = base.optional_number(params, "columns", nil)
  local padding = base.optional_number(params, "padding", 0)
  local tag_name = base.optional_string(params, "tag", nil)

  -- Determine frame range
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

  -- Calculate sheet dimensions
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

function M.export_gif(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  local scale = base.optional_number(params, "scale", 1)

  if scale ~= 1 then
    -- Create a scaled copy
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

function M.export_tileset(params)
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

  -- Arrange tiles in a horizontal strip
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

function M.export_layers(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local output_dir, e1 = base.require_string(params, "output_dir")
  if e1 then return e1 end

  local format = base.optional_string(params, "format", "png")
  local visible_only = base.optional_bool(params, "visible_only", false)

  local exported = {}
  local original_visibility = {}

  -- Save visibility state
  for _, layer in ipairs(sprite.layers) do
    original_visibility[layer.name] = layer.isVisible
  end

  for _, layer in ipairs(sprite.layers) do
    if layer.isGroup then goto continue end
    if visible_only and not layer.isVisible then goto continue end

    -- Hide all other layers
    for _, l in ipairs(sprite.layers) do
      l.isVisible = (l == layer)
    end

    local ext = format == "aseprite" and ".aseprite" or ("." .. format)
    local file_path = output_dir .. "/" .. layer.name .. ext
    sprite:saveCopyAs(file_path)
    exported[#exported + 1] = { layer = layer.name, path = file_path }

    ::continue::
  end

  -- Restore visibility
  for _, layer in ipairs(sprite.layers) do
    if original_visibility[layer.name] ~= nil then
      layer.isVisible = original_visibility[layer.name]
    end
  end

  return base.success({ exported = exported, count = #exported })
end

function M.export_tags_as_sheets(params)
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

return M
