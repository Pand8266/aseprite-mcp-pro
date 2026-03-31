local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    export_for_godot = M.export_for_godot,
    export_atlas_texture = M.export_atlas_texture,
    export_9patch_for_godot = M.export_9patch_for_godot,
    export_tileset_for_godot = M.export_tileset_for_godot,
    get_animation_data = M.get_animation_data,
    generate_spriteframes_tres = M.generate_spriteframes_tres,
    sync_to_godot_project = M.sync_to_godot_project,
    batch_export_for_godot = M.batch_export_for_godot,
  }
end

-- Helper: build animation data from tags
local function build_animation_data(sprite, sheet_type, columns)
  local frame_count = #sprite.frames
  local fw = sprite.width
  local fh = sprite.height

  -- Calculate frame positions based on sheet layout
  local function frame_region(idx)
    -- idx is 0-based
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
          index = i - 1,  -- 0-based
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
    -- No tags: single "default" animation with all frames
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

  -- Build animations array
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

function M.export_for_godot(params)
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

  -- Export sprite sheet
  local png_path = output_dir .. "/" .. name .. ".png"
  local json_path = output_dir .. "/" .. name .. ".json"

  app.command.ExportSpriteSheet {
    ui = false,
    type = sheet_types[sheet_type_str] or SpriteSheetType.HORIZONTAL,
    textureFilename = png_path,
    dataFilename = json_path,
    trim = trim,
    scale = scale or 1,
  }

  -- Build animation data and generate .tres
  local anim_data = build_animation_data(sprite, sheet_type_str, nil)

  -- Guess the res:// path
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

function M.export_atlas_texture(params)
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

function M.export_9patch_for_godot(params)
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

  -- NinePatchRect margins: left, top, right, bottom
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

function M.export_tileset_for_godot(params)
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

  -- Export tileset image
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

  -- Generate TileSet .tres
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

function M.get_animation_data(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local sheet_type = base.optional_string(params, "sheet_type", "horizontal")
  local columns = base.optional_number(params, "columns", nil)

  local data = build_animation_data(sprite, sheet_type, columns)
  return base.success(data)
end

function M.generate_spriteframes_tres(params)
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

function M.sync_to_godot_project(params)
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

  -- Ensure directory exists
  os.execute('mkdir "' .. full_dir .. '" 2>nul')

  -- Delegate to export_for_godot
  local result = M.export_for_godot({
    output_dir = full_dir,
    name = name,
    scale = scale,
  })

  -- Fix res:// path in the .tres
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

function M.batch_export_for_godot(params)
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
    local result = M.export_for_godot({
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

return M
