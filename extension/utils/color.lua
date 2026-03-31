-- Color utility module for Aseprite MCP Pro
local M = {}

--- Parse a hex color string to Aseprite Color object
--- Supports: #RGB, #RRGGBB, #RRGGBBAA
---@param hex string Color in hex format
---@return Color
function M.from_hex(hex)
  if not hex then return Color(0, 0, 0, 255) end

  -- Remove # prefix
  hex = hex:gsub("^#", "")

  local r, g, b, a

  if #hex == 3 then
    -- #RGB -> #RRGGBB
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

--- Convert an Aseprite Color to hex string
---@param color Color
---@param include_alpha boolean|nil
---@return string
function M.to_hex(color, include_alpha)
  if include_alpha and color.alpha < 255 then
    return string.format("#%02X%02X%02X%02X",
      color.red, color.green, color.blue, color.alpha)
  end
  return string.format("#%02X%02X%02X",
    color.red, color.green, color.blue)
end

--- Convert pixel value to Color depending on color mode
---@param pixel_value integer
---@param color_mode ColorMode
---@param palette Palette|nil
---@return Color
function M.pixel_to_color(pixel_value, color_mode, palette)
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

--- Convert Color to pixel value for the given color mode
---@param color Color
---@param color_mode ColorMode
---@param palette Palette|nil
---@return integer
function M.color_to_pixel(color, color_mode, palette)
  if color_mode == ColorMode.RGB then
    return app.pixelColor.rgba(color.red, color.green, color.blue, color.alpha)
  elseif color_mode == ColorMode.GRAYSCALE then
    local v = math.floor(0.299 * color.red + 0.587 * color.green + 0.114 * color.blue)
    return app.pixelColor.graya(v, color.alpha)
  elseif color_mode == ColorMode.INDEXED then
    -- Find closest palette index
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

return M
