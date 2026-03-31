local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    select_rect = M.select_rect,
    select_ellipse = M.select_ellipse,
    select_all = M.select_all,
    deselect = M.deselect,
    select_by_color = M.select_by_color,
    get_selection = M.get_selection,
    invert_selection = M.invert_selection,
  }
end

local function selection_mode_value(mode_str)
  if mode_str == "add" then return SelectionMode.ADD end
  if mode_str == "subtract" then return SelectionMode.SUBTRACT end
  if mode_str == "intersect" then return SelectionMode.INTERSECT end
  return SelectionMode.REPLACE
end

function M.select_rect(params)
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

  local mode = base.optional_string(params, "mode", "replace")
  local sel = sprite.selection

  sel:select(Rectangle(x, y, w, h))

  return base.success({
    bounds = { x = sel.bounds.x, y = sel.bounds.y,
               width = sel.bounds.width, height = sel.bounds.height },
  })
end

function M.select_ellipse(params)
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

  -- Use app.command for ellipse selection
  app.command.SelectEllipse {
    ui = false,
    bounds = Rectangle(x, y, w, h),
  }

  local sel = sprite.selection
  return base.success({
    bounds = { x = sel.bounds.x, y = sel.bounds.y,
               width = sel.bounds.width, height = sel.bounds.height },
  })
end

function M.select_all(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  sprite.selection:selectAll()

  return base.success({
    bounds = { x = 0, y = 0, width = sprite.width, height = sprite.height },
  })
end

function M.deselect(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  sprite.selection:deselect()

  return base.success({ deselected = true })
end

function M.select_by_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local color_hex, e1 = base.require_string(params, "color")
  if e1 then return e1 end

  local tolerance = base.optional_number(params, "tolerance", 0)
  local color = color_util.from_hex(color_hex)

  app.fgColor = color
  app.command.MaskByColor {
    ui = false,
    tolerance = tolerance,
  }

  local sel = sprite.selection
  return base.success({
    is_empty = sel.isEmpty,
    bounds = not sel.isEmpty and {
      x = sel.bounds.x, y = sel.bounds.y,
      width = sel.bounds.width, height = sel.bounds.height,
    } or nil,
  })
end

function M.get_selection(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local sel = sprite.selection

  return base.success({
    is_empty = sel.isEmpty,
    bounds = not sel.isEmpty and {
      x = sel.bounds.x, y = sel.bounds.y,
      width = sel.bounds.width, height = sel.bounds.height,
    } or nil,
  })
end

function M.invert_selection(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  app.command.InvertMask()

  local sel = sprite.selection
  return base.success({
    is_empty = sel.isEmpty,
    bounds = not sel.isEmpty and {
      x = sel.bounds.x, y = sel.bounds.y,
      width = sel.bounds.width, height = sel.bounds.height,
    } or nil,
  })
end

return M
