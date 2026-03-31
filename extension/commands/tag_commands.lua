local base = require("commands.base")
local color_util = require("utils.color")
local M = {}

function M.get_commands()
  return {
    get_tags = M.get_tags,
    create_tag = M.create_tag,
    delete_tag = M.delete_tag,
    rename_tag = M.rename_tag,
    set_tag_color = M.set_tag_color,
    set_tag_range = M.set_tag_range,
  }
end

function M.get_tags(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local tags = {}
  for i, tag in ipairs(sprite.tags) do
    tags[i] = {
      name = tag.name,
      from_frame = tag.fromFrame.frameNumber,
      to_frame = tag.toFrame.frameNumber,
      frame_count = tag.frames,
      ani_dir = tostring(tag.aniDir),
      repeat_count = tag.repeats,
      color = color_util.to_hex(tag.color),
    }
  end

  return base.success({ tags = tags, count = #sprite.tags })
end

function M.create_tag(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local from_frame, e2 = base.require_number(params, "from_frame")
  if e2 then return e2 end
  local to_frame, e3 = base.require_number(params, "to_frame")
  if e3 then return e3 end

  if from_frame < 1 or from_frame > #sprite.frames then
    return base.error_invalid_params("from_frame out of range")
  end
  if to_frame < from_frame or to_frame > #sprite.frames then
    return base.error_invalid_params("to_frame out of range")
  end

  local tag
  app.transaction("Create Tag", function()
    tag = sprite:newTag(from_frame, to_frame)
    tag.name = name

    local color_hex = base.optional_string(params, "color", nil)
    if color_hex then
      tag.color = color_util.from_hex(color_hex)
    end

    local ani_dir = base.optional_string(params, "ani_dir", nil)
    if ani_dir then
      local dirs = {
        forward = AniDir.FORWARD,
        reverse = AniDir.REVERSE,
        ping_pong = AniDir.PING_PONG,
        ping_pong_reverse = AniDir.PING_PONG_REVERSE,
      }
      if dirs[ani_dir] then tag.aniDir = dirs[ani_dir] end
    end

    local repeat_count = base.optional_number(params, "repeat", nil)
    if repeat_count then
      tag.repeats = math.floor(repeat_count)
    end
  end)

  return base.success({
    name = name,
    from_frame = from_frame,
    to_frame = to_frame,
  })
end

function M.delete_tag(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Delete Tag", function()
    sprite:deleteTag(tag)
  end)

  return base.success({ deleted = name })
end

function M.rename_tag(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local new_name, e2 = base.require_string(params, "new_name")
  if e2 then return e2 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Rename Tag", function()
    tag.name = new_name
  end)

  return base.success({ old_name = name, new_name = new_name })
end

function M.set_tag_color(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local color_hex, e2 = base.require_string(params, "color")
  if e2 then return e2 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Set Tag Color", function()
    tag.color = color_util.from_hex(color_hex)
  end)

  return base.success({ name = name, color = color_hex })
end

function M.set_tag_range(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local name, e1 = base.require_string(params, "name")
  if e1 then return e1 end
  local from_frame, e2 = base.require_number(params, "from_frame")
  if e2 then return e2 end
  local to_frame, e3 = base.require_number(params, "to_frame")
  if e3 then return e3 end

  local tag = base.find_tag(sprite, name)
  if not tag then return base.error_tag_not_found(name) end

  app.transaction("Set Tag Range", function()
    tag.fromFrame = sprite.frames[from_frame]
    tag.toFrame = sprite.frames[to_frame]
  end)

  return base.success({ name = name, from_frame = from_frame, to_frame = to_frame })
end

return M
