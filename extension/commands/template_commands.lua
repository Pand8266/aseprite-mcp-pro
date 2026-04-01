local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    create_character_template = M.create_character_template,
    create_tileset_template = M.create_tileset_template,
  }
end

function M.create_character_template(params)
  local size = base.optional_number(params, "size", 32)
  local frames = base.optional_number(params, "frames", 4)
  local animations = params.animations  -- can be nil

  local sprite = Sprite(size, size, ColorMode.RGB)
  if not sprite then
    return base.error(-32603, "Failed to create sprite")
  end

  -- Default animation setup: idle(4), walk(6), attack(4)
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

  -- Calculate total frames needed
  local total_frames = 0
  for _, ad in ipairs(anim_defs) do
    total_frames = total_frames + ad.frames
  end

  -- Create layers
  app.transaction("Create Character Template", function()
    -- Rename default layer
    sprite.layers[1].name = "body"

    -- Add additional layers
    local outline_layer = sprite:newLayer()
    outline_layer.name = "outline"
    outline_layer.stackIndex = 1

    local effects_layer = sprite:newLayer()
    effects_layer.name = "effects"

    local shadow_layer = sprite:newLayer()
    shadow_layer.name = "shadow"
    shadow_layer.opacity = 128
    shadow_layer.stackIndex = 1

    -- Add frames (we already have 1)
    for i = 2, total_frames do
      sprite:newFrame(sprite.frames[1])
      -- Clear content of new frames
      for _, layer in ipairs(sprite.layers) do
        if not layer.isGroup then
          local cel = layer:cel(i)
          if cel then sprite:deleteCel(cel) end
        end
      end
    end

    -- Create animation tags
    local frame_offset = 1
    for _, ad in ipairs(anim_defs) do
      local tag = sprite:newTag(frame_offset, frame_offset + ad.frames - 1)
      tag.name = ad.name
      frame_offset = frame_offset + ad.frames
    end

    -- Set all frame durations to 100ms
    for i = 1, #sprite.frames do
      sprite.frames[i].duration = 0.1
    end
  end)

  -- Build response
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

function M.create_tileset_template(params)
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

    -- Draw grid lines on a separate layer
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

return M
