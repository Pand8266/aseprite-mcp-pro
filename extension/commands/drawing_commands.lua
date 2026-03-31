local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    put_pixel = M.put_pixel,
    put_pixels = M.put_pixels,
    get_pixel = M.get_pixel,
    get_image_data = M.get_image_data,
    set_image_data = M.set_image_data,
    draw_line = M.draw_line,
    draw_rect = M.draw_rect,
    draw_ellipse = M.draw_ellipse,
    flood_fill = M.flood_fill,
    draw_brush_stroke = M.draw_brush_stroke,
    clear_image = M.clear_image,
    replace_color = M.replace_color,
    outline = M.outline,
  }
end

-- Helper: get target cel's image
local function get_target_image(sprite, params)
  local layer, err = base.get_target_layer(sprite, params)
  if err then return nil, nil, nil, err end
  local frame, err2 = base.get_target_frame(sprite, params)
  if err2 then return nil, nil, nil, err2 end

  local cel = layer:cel(frame.frameNumber)
  if not cel then
    -- Create a new empty cel
    local img = Image(sprite.spec)
    img:clear()
    cel = sprite:newCel(layer, frame, img, Point(0, 0))
  end
  return cel, layer, frame, nil
end

function M.put_pixel(params)
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

  -- Adjust for cel position offset
  local lx = x - cel.position.x
  local ly = y - cel.position.y

  app.transaction("Put Pixel", function()
    if lx >= 0 and ly >= 0 and lx < cel.image.width and ly < cel.image.height then
      cel.image:putPixel(lx, ly, pixel_val)
    end
  end)

  return base.success({ x = x, y = y, color = color_hex })
end

function M.put_pixels(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local pixels = params.pixels
  if not pixels or type(pixels) ~= "table" then
    return base.error_invalid_params("Missing required parameter: pixels (array)")
  end

  local cel, _, _, err2 = get_target_image(sprite, params)
  if err2 then return err2 end

  local palette = sprite.palettes[1]
  local cm = sprite.colorMode
  local img = cel.image
  local ox, oy = cel.position.x, cel.position.y

  app.transaction("Put Pixels", function()
    for _, p in ipairs(pixels) do
      if p.x and p.y and p.color then
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

function M.get_pixel(params)
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

function M.get_image_data(params)
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
    -- base64_png
    local tmp = os.tmpname() .. ".png"
    cel.image:saveAs(tmp)
    local f = io.open(tmp, "rb")
    if not f then return base.error(-32603, "Failed to save image data") end
    local data = f:read("*a")
    f:close()
    os.remove(tmp)

    local b64 = require("utils.base64")
    return base.success({
      image = b64.encode(data),
      width = cel.image.width,
      height = cel.image.height,
      offset_x = cel.position.x,
      offset_y = cel.position.y,
    })
  end
end

function M.set_image_data(params)
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
    local b64 = require("utils.base64")
    local decoded = b64.decode(data)
    local tmp = os.tmpname() .. ".png"
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

function M.draw_line(params)
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

function M.draw_rect(params)
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

function M.draw_ellipse(params)
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

function M.flood_fill(params)
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

function M.draw_brush_stroke(params)
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
  for _, p in ipairs(points_data) do
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

function M.clear_image(params)
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

function M.replace_color(params)
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

function M.outline(params)
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
      -- For outside outline, we may need to expand the image
      -- Simple approach: check each transparent pixel adjacent to non-transparent
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
      -- Inside outline: non-transparent pixels adjacent to transparent
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

return M
