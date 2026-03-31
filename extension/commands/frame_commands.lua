local base = require("commands.base")
local M = {}

function M.get_commands()
  return {
    get_frames = M.get_frames,
    add_frame = M.add_frame,
    delete_frame = M.delete_frame,
    set_frame_duration = M.set_frame_duration,
    set_frame_range_duration = M.set_frame_range_duration,
    set_active_frame = M.set_active_frame,
    duplicate_frame = M.duplicate_frame,
    reverse_frames = M.reverse_frames,
  }
end

function M.get_frames(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frames = {}
  for i, frame in ipairs(sprite.frames) do
    frames[i] = {
      number = frame.frameNumber,
      duration_ms = math.floor(frame.duration * 1000),
    }
  end

  return base.success({
    frames = frames,
    count = #sprite.frames,
    active_frame = app.frame and app.frame.frameNumber or 1,
  })
end

function M.add_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local after = base.optional_number(params, "after", nil)
  local copy = base.optional_bool(params, "copy", false)

  local new_frame
  app.transaction("Add Frame", function()
    if after then
      new_frame = sprite:newFrame(sprite.frames[after])
    else
      new_frame = sprite:newFrame(app.frame)
    end

    if not copy and new_frame then
      -- Clear the new frame content if not copying
      for _, layer in ipairs(sprite.layers) do
        if not layer.isGroup then
          local cel = sprite:cel(layer, new_frame)
          if cel then
            sprite:deleteCel(cel)
          end
        end
      end
    end
  end)

  return base.success({
    frame = new_frame and new_frame.frameNumber or 0,
    total_frames = #sprite.frames,
  })
end

function M.delete_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num, err2 = base.require_number(params, "frame")
  if err2 then return err2 end

  if frame_num < 1 or frame_num > #sprite.frames then
    return base.error_invalid_params(
      string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
  end

  if #sprite.frames <= 1 then
    return base.error(-32603, "Cannot delete the last frame")
  end

  app.transaction("Delete Frame", function()
    sprite:deleteFrame(sprite.frames[frame_num])
  end)

  return base.success({ deleted = frame_num, total_frames = #sprite.frames })
end

function M.set_frame_duration(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num, err2 = base.require_number(params, "frame")
  if err2 then return err2 end
  local duration_ms, err3 = base.require_number(params, "duration_ms")
  if err3 then return err3 end

  if frame_num < 1 or frame_num > #sprite.frames then
    return base.error_invalid_params(
      string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
  end

  app.transaction("Set Frame Duration", function()
    sprite.frames[frame_num].duration = duration_ms / 1000.0
  end)

  return base.success({
    frame = frame_num,
    duration_ms = duration_ms,
  })
end

function M.set_frame_range_duration(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local from, err2 = base.require_number(params, "from_frame")
  if err2 then return err2 end
  local to, err3 = base.require_number(params, "to_frame")
  if err3 then return err3 end
  local duration_ms, err4 = base.require_number(params, "duration_ms")
  if err4 then return err4 end

  from = math.max(1, math.floor(from))
  to = math.min(#sprite.frames, math.floor(to))

  app.transaction("Set Frame Range Duration", function()
    for i = from, to do
      sprite.frames[i].duration = duration_ms / 1000.0
    end
  end)

  return base.success({
    from_frame = from,
    to_frame = to,
    duration_ms = duration_ms,
    frames_updated = to - from + 1,
  })
end

function M.set_active_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num, err2 = base.require_number(params, "frame")
  if err2 then return err2 end

  if frame_num < 1 or frame_num > #sprite.frames then
    return base.error_invalid_params(
      string.format("Frame %d out of range (1-%d)", frame_num, #sprite.frames))
  end

  app.frame = sprite.frames[frame_num]

  return base.success({ active_frame = frame_num })
end

function M.duplicate_frame(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local frame_num = base.optional_number(params, "frame", nil)
  local source_frame = frame_num and sprite.frames[frame_num] or app.frame

  local new_frame
  app.transaction("Duplicate Frame", function()
    new_frame = sprite:newFrame(source_frame)
  end)

  return base.success({
    source_frame = source_frame.frameNumber,
    new_frame = new_frame and new_frame.frameNumber or 0,
    total_frames = #sprite.frames,
  })
end

function M.reverse_frames(params)
  local sprite, err = base.get_sprite()
  if err then return err end

  local from, err2 = base.require_number(params, "from_frame")
  if err2 then return err2 end
  local to, err3 = base.require_number(params, "to_frame")
  if err3 then return err3 end

  app.range.frames = {}
  for i = from, to do
    app.range.frames[#app.range.frames + 1] = sprite.frames[i]
  end
  app.command.ReverseFrames()

  return base.success({
    from_frame = from,
    to_frame = to,
    reversed = to - from + 1,
  })
end

return M
