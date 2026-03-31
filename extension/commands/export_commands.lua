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
  local scale = base.optional_number(params, "scale", 1)

  if frame_num then
    -- Single frame
    if frame_num < 1 or frame_num > #sprite.frames then
      return base.error_invalid_params("Frame out of range")
    end
    -- Use saveCopyAs for single frame export isn't direct, use ExportSpriteSheet with single frame
    app.command.ExportSpriteSheet {
      ui = false,
      type = SpriteSheetType.HORIZONTAL,
      fromFrame = sprite.frames[frame_num],
      toFrame = sprite.frames[frame_num],
      textureFilename = path,
      scale = scale,
    }
  else
    -- All frames - if single frame sprite, just save copy
    if #sprite.frames == 1 then
      sprite:saveCopyAs(path)
    else
      -- Export each frame with {frame} in filename
      for i, frame in ipairs(sprite.frames) do
        local frame_path = path:gsub("{frame}", string.format("%03d", i))
        app.frame = frame
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
  local sheet_types = {
    horizontal = SpriteSheetType.HORIZONTAL,
    vertical = SpriteSheetType.VERTICAL,
    rows = SpriteSheetType.ROWS,
    columns = SpriteSheetType.COLUMNS,
    packed = SpriteSheetType.PACKED,
  }
  local sheet_type = sheet_types[sheet_type_str] or SpriteSheetType.HORIZONTAL

  local cmd_params = {
    ui = false,
    type = sheet_type,
    textureFilename = path,
    trim = base.optional_bool(params, "trim", false),
  }

  local json_path = base.optional_string(params, "json_path", nil)
  if json_path then cmd_params.dataFilename = json_path end

  local columns = base.optional_number(params, "columns", nil)
  if columns then cmd_params.columns = math.floor(columns) end

  local rows = base.optional_number(params, "rows", nil)
  if rows then cmd_params.rows = math.floor(rows) end

  local padding = base.optional_number(params, "padding", nil)
  if padding then cmd_params.borderPadding = math.floor(padding) end

  local inner_padding = base.optional_number(params, "inner_padding", nil)
  if inner_padding then cmd_params.innerPadding = math.floor(inner_padding) end

  local scale = base.optional_number(params, "scale", nil)
  if scale then cmd_params.scale = scale end

  local tag_name = base.optional_string(params, "tag", nil)
  if tag_name then
    local tag = base.find_tag(sprite, tag_name)
    if tag then
      cmd_params.fromFrame = tag.fromFrame
      cmd_params.toFrame = tag.toFrame
    end
  end

  app.command.ExportSpriteSheet(cmd_params)

  return base.success({
    path = path,
    json_path = json_path,
    sheet_type = sheet_type_str,
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

  local sheet_types = {
    horizontal = SpriteSheetType.HORIZONTAL,
    vertical = SpriteSheetType.VERTICAL,
    rows = SpriteSheetType.ROWS,
    columns = SpriteSheetType.COLUMNS,
  }
  local sheet_type = sheet_types[sheet_type_str] or SpriteSheetType.HORIZONTAL

  local exported = {}
  for _, tag in ipairs(sprite.tags) do
    local png_path = output_dir .. "/" .. tag.name .. ".png"
    local cmd_params = {
      ui = false,
      type = sheet_type,
      textureFilename = png_path,
      fromFrame = tag.fromFrame,
      toFrame = tag.toFrame,
    }
    if scale ~= 1 then cmd_params.scale = scale end
    if export_json then
      cmd_params.dataFilename = output_dir .. "/" .. tag.name .. ".json"
    end

    app.command.ExportSpriteSheet(cmd_params)
    exported[#exported + 1] = {
      tag = tag.name,
      path = png_path,
      frames = tag.frames,
    }
  end

  return base.success({ exported = exported, count = #exported })
end

return M
