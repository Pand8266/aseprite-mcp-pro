local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    get_palette = M.get_palette,
    set_palette_color = M.set_palette_color,
    set_palette = M.set_palette,
    add_palette_color = M.add_palette_color,
    resize_palette = M.resize_palette,
    load_palette = M.load_palette,
    save_palette = M.save_palette,
    set_fg_color = M.set_fg_color,
    set_bg_color = M.set_bg_color,
    generate_palette_from_sprite = M.generate_palette_from_sprite,
  }
end

function M.get_palette(params)
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

function M.set_palette_color(params)
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

function M.set_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local colors = params.colors
  if not colors or type(colors) ~= "table" then
    return base.error_invalid_params("Missing required parameter: colors (array of hex strings)")
  end

  app.transaction("Set Palette", function()
    local palette = sprite.palettes[1]
    palette:resize(#colors)
    for i, hex in ipairs(colors) do
      palette:setColor(i - 1, color_util.from_hex(hex))
    end
  end)

  return base.success({ size = #colors })
end

function M.add_palette_color(params)
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

function M.resize_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local size, e1 = base.require_number(params, "size")
  if e1 then return e1 end

  app.transaction("Resize Palette", function()
    sprite.palettes[1]:resize(math.floor(size))
  end)

  return base.success({ size = #sprite.palettes[1] })
end

function M.load_palette(params)
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

function M.save_palette(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local path, e1 = base.require_string(params, "path")
  if e1 then return e1 end

  sprite.palettes[1]:saveAs(path)

  return base.success({ path = path, size = #sprite.palettes[1] })
end

function M.set_fg_color(params)
  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  app.fgColor = color_util.from_hex(color_hex)

  return base.success({ color = color_hex })
end

function M.set_bg_color(params)
  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  app.bgColor = color_util.from_hex(color_hex)

  return base.success({ color = color_hex })
end

function M.generate_palette_from_sprite(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local max_colors = base.optional_number(params, "max_colors", 256)

  -- Collect all unique colors
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

  -- Sort by frequency
  local sorted = {}
  for hex, count in pairs(color_counts) do
    sorted[#sorted + 1] = { hex = hex, count = count }
  end
  table.sort(sorted, function(a, b) return a.count > b.count end)

  -- Build new palette
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

return M
