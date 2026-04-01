local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    get_color_stats = M.get_color_stats,
    compare_frames = M.compare_frames,
    compare_screenshots = M.compare_screenshots,
    find_unused_colors = M.find_unused_colors,
    get_sprite_bounds = M.get_sprite_bounds,
    validate_animation = M.validate_animation,
  }
end

function M.get_color_stats(params)
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

  -- Sort by frequency
  local sorted = {}
  for hex, count in pairs(color_counts) do
    sorted[#sorted + 1] = { color = hex, count = count, percent = (count / math.max(1, total_pixels)) * 100 }
  end
  table.sort(sorted, function(a, b) return a.count > b.count end)

  -- Top 20
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

function M.compare_frames(params)
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

function M.compare_screenshots(params)
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

  -- Create diff image: red=changed, green=only in A, blue=only in B
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

  -- Save diff as base64 PNG
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

function M.find_unused_colors(params)
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

function M.get_sprite_bounds(params)
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

function M.validate_animation(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local issues = {}

  -- Check for empty frames (no visible content)
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

  -- Check for inconsistent durations within tags
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

  -- Check frames not covered by any tag
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

return M
