local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    get_slices = M.get_slices,
    create_slice = M.create_slice,
    delete_slice = M.delete_slice,
    set_slice_9patch = M.set_slice_9patch,
    set_slice_pivot = M.set_slice_pivot,
  }
end

function M.get_slices(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local slices = {}
  for i, slice in ipairs(sprite.slices) do
    local info = {
      name = slice.name,
      bounds = {
        x = slice.bounds.x,
        y = slice.bounds.y,
        width = slice.bounds.width,
        height = slice.bounds.height,
      },
      color = color_util.to_hex(slice.color),
    }
    if slice.center then
      info.center = {
        x = slice.center.x,
        y = slice.center.y,
        width = slice.center.width,
        height = slice.center.height,
      }
    end
    if slice.pivot then
      info.pivot = { x = slice.pivot.x, y = slice.pivot.y }
    end
    slices[i] = info
  end

  return base.success({ slices = slices, count = #sprite.slices })
end

function M.create_slice(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local x, e2 = base.require_number(params, "x")
  if e2 then return e2 end
  local y, e3 = base.require_number(params, "y")
  if e3 then return e3 end
  local w, e4 = base.require_number(params, "width")
  if e4 then return e4 end
  local h, e5 = base.require_number(params, "height")
  if e5 then return e5 end

  local slice
  app.transaction("Create Slice", function()
    slice = sprite:newSlice(Rectangle(x, y, w, h))
    slice.name = name

    local color_hex = base.optional_string(params, "color", nil)
    if color_hex then
      slice.color = color_util.from_hex(color_hex)
    end
  end)

  return base.success({
    name = name,
    bounds = { x = x, y = y, width = w, height = h },
  })
end

function M.delete_slice(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == name then
      target = slice
      break
    end
  end

  if not target then
    return base.error(-32001, "Slice not found: " .. name)
  end

  app.transaction("Delete Slice", function()
    sprite:deleteSlice(target)
  end)

  return base.success({ deleted = name })
end

function M.set_slice_9patch(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local cx, e2 = base.require_number(params, "center_x")
  if e2 then return e2 end
  local cy, e3 = base.require_number(params, "center_y")
  if e3 then return e3 end
  local cw, e4 = base.require_number(params, "center_width")
  if e4 then return e4 end
  local ch, e5 = base.require_number(params, "center_height")
  if e5 then return e5 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == name then target = slice; break end
  end
  if not target then
    return base.error(-32001, "Slice not found: " .. name)
  end

  app.transaction("Set 9-Patch", function()
    target.center = Rectangle(cx, cy, cw, ch)
  end)

  return base.success({
    name = name,
    center = { x = cx, y = cy, width = cw, height = ch },
  })
end

function M.set_slice_pivot(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local px, e2 = base.require_number(params, "pivot_x")
  if e2 then return e2 end
  local py, e3 = base.require_number(params, "pivot_y")
  if e3 then return e3 end

  local target = nil
  for _, slice in ipairs(sprite.slices) do
    if slice.name == name then target = slice; break end
  end
  if not target then
    return base.error(-32001, "Slice not found: " .. name)
  end

  app.transaction("Set Slice Pivot", function()
    target.pivot = Point(px, py)
  end)

  return base.success({ name = name, pivot = { x = px, y = py } })
end

return M
