local base = require("commands.base")
local M = {}

function M.get_commands()
  return {
    create_tilemap_layer = M.create_tilemap_layer,
    get_tileset = M.get_tileset,
    set_tile = M.set_tile,
    get_tile = M.get_tile,
    get_tilemap_info = M.get_tilemap_info,
  }
end

function M.create_tilemap_layer(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local tile_width, e1 = base.require_number(params, "tile_width")
  if e1 then return e1 end
  local tile_height, e2 = base.require_number(params, "tile_height")
  if e2 then return e2 end

  local name = base.optional_string(params, "name", nil)

  -- Set grid before creating tilemap layer
  sprite.gridBounds = Rectangle(0, 0, tile_width, tile_height)

  local layer
  app.transaction("Create Tilemap Layer", function()
    layer = sprite:newLayer()
    -- Convert to tilemap via command
    app.layer = layer
    app.command.NewLayer { tilemap = true }
    layer = app.layer  -- re-grab after command
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

function M.get_tileset(params)
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

function M.set_tile(params)
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

function M.get_tile(params)
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

function M.get_tilemap_info(params)
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

return M
