-- Geometry utility module for Aseprite MCP Pro
local M = {}

--- Create a Rectangle from params, with defaults
---@param params table {x, y, width, height}
---@return Rectangle
function M.rect_from_params(params)
  return Rectangle(
    params.x or 0,
    params.y or 0,
    params.width or 0,
    params.height or 0
  )
end

--- Create a Point from params
---@param params table {x, y}
---@return Point
function M.point_from_params(params)
  return Point(params.x or 0, params.y or 0)
end

--- Check if a point is within sprite bounds
---@param x number
---@param y number
---@param sprite Sprite
---@return boolean
function M.in_bounds(x, y, sprite)
  return x >= 0 and y >= 0 and x < sprite.width and y < sprite.height
end

--- Clamp a rectangle to sprite bounds
---@param rect Rectangle
---@param sprite Sprite
---@return Rectangle
function M.clamp_rect(rect, sprite)
  local x = math.max(0, rect.x)
  local y = math.max(0, rect.y)
  local x2 = math.min(sprite.width, rect.x + rect.width)
  local y2 = math.min(sprite.height, rect.y + rect.height)
  return Rectangle(x, y, math.max(0, x2 - x), math.max(0, y2 - y))
end

return M
