----------------------------------------------------------------------
-- Aseprite MCP Pro - Plugin Entry Point
-- WebSocket client that connects to the MCP server and dispatches
-- JSON-RPC commands to Lua command handlers.
----------------------------------------------------------------------

-- Set package.path to extension directory so require() finds our modules
local script_path = debug.getinfo(1, "S").source:match("@?(.*[/\\])")
if script_path then
  package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. package.path
end

-- Pre-load utils into global scope so commands can access them at runtime
-- (Aseprite resets package.path between init and command execution)
local _base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_G.MCP_BASE64 = {
  encode = function(data)
    return ((data:gsub(".", function(x)
      local r, b2 = "", x:byte()
      for i = 8, 1, -1 do
        r = r .. (b2 % 2 ^ i - b2 % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
      if #x < 6 then return "" end
      local c = 0
      for i = 1, 6 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
      end
      return _base64_chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
  end,
  decode = function(data)
    data = string.gsub(data, "[^" .. _base64_chars .. "=]", "")
    return (data:gsub(".", function(x)
      if x == "=" then return "" end
      local r, f = "", (_base64_chars:find(x) - 1)
      for i = 6, 1, -1 do
        r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
      if #x ~= 8 then return "" end
      local c = 0
      for i = 1, 8 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
      end
      return string.char(c)
    end))
  end,
}

-- Configuration
local DEFAULT_PORT = 6515
local RECONNECT_INTERVAL_MS = 3000
local VERSION = "1.0.0"

-- State
local ws = nil
local connected = false
local handlers = {}
local reconnect_timer = nil
local port = DEFAULT_PORT

----------------------------------------------------------------------
-- JSON minimal encoder/decoder (Aseprite has json module built-in)
----------------------------------------------------------------------
local json = json  -- Aseprite built-in

----------------------------------------------------------------------
-- Command module loader
----------------------------------------------------------------------
local function load_commands()
  local modules = {
    "commands.sprite_commands",
    "commands.layer_commands",
    "commands.frame_commands",
    "commands.cel_commands",
    "commands.drawing_commands",
    "commands.selection_commands",
    "commands.palette_commands",
    "commands.tag_commands",
    "commands.slice_commands",
    "commands.tilemap_commands",
    "commands.export_commands",
    "commands.godot_commands",
    "commands.analysis_commands",
  }

  for _, mod_name in ipairs(modules) do
    local ok, mod = pcall(require, mod_name)
    if ok and mod.get_commands then
      local cmds = mod.get_commands()
      for name, fn in pairs(cmds) do
        handlers[name] = fn
      end
      print("[MCP] Loaded: " .. mod_name .. " (" .. count_keys(cmds) .. " commands)")
    else
      print("[MCP] Warning: Failed to load " .. mod_name .. ": " .. tostring(mod))
    end
  end

  local total = 0
  for _ in pairs(handlers) do total = total + 1 end
  print("[MCP] Total commands registered: " .. total)
end

function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

----------------------------------------------------------------------
-- JSON-RPC dispatch
----------------------------------------------------------------------
local function dispatch(method, params)
  -- Built-in commands
  if method == "ping" then
    return { method = "pong" }
  end

  if method == "get_version" then
    return { result = { version = VERSION, tool_count = count_keys(handlers) } }
  end

  -- Lookup handler
  local handler = handlers[method]
  if not handler then
    return {
      error = {
        code = -32601,
        message = "Method not found: " .. tostring(method),
      }
    }
  end

  -- Execute with pcall for safety
  local ok, result = pcall(handler, params or {})
  if not ok then
    return {
      error = {
        code = -32603,
        message = "Internal error: " .. tostring(result),
      }
    }
  end

  return result
end

----------------------------------------------------------------------
-- WebSocket message handler
----------------------------------------------------------------------
local function on_message(msg_data)
  local ok, request = pcall(json.decode, msg_data)
  if not ok or not request then
    print("[MCP] Failed to parse JSON: " .. tostring(msg_data):sub(1, 100))
    return
  end

  local method = request.method
  local params = request.params or {}
  local id = request.id

  -- Dispatch
  local response = dispatch(method, params)

  -- Send response if request had an id (not a notification)
  if id then
    response.jsonrpc = "2.0"
    response.id = id

    local ok2, encoded = pcall(json.encode, response)
    if ok2 and ws then
      ws:sendText(encoded)
    else
      print("[MCP] Failed to encode response: " .. tostring(encoded))
    end
  elseif response and response.method == "pong" then
    -- Send pong response
    local ok2, encoded = pcall(json.encode, { jsonrpc = "2.0", method = "pong" })
    if ok2 and ws then
      ws:sendText(encoded)
    end
  end
end

----------------------------------------------------------------------
-- WebSocket connection
----------------------------------------------------------------------
local function connect()
  if ws then
    pcall(function() ws:close() end)
    ws = nil
  end

  local url = "ws://127.0.0.1:" .. port
  print("[MCP] Connecting to " .. url .. "...")

  ws = WebSocket {
    url = url,
    deflate = false,
    minreconnectwait = 2,
    maxreconnectwait = 5,
    onreceive = function(mt, data, err)
      if mt == WebSocketMessageType.OPEN then
        connected = true
        print("[MCP] Connected to MCP server")
        if reconnect_timer then
          reconnect_timer:stop()
          reconnect_timer = nil
        end
      elseif mt == WebSocketMessageType.TEXT then
        on_message(data)
      elseif mt == WebSocketMessageType.CLOSE then
        connected = false
        print("[MCP] Disconnected from MCP server")
        start_reconnect()
      elseif mt == WebSocketMessageType.ERROR then
        connected = false
        print("[MCP] WebSocket error: " .. tostring(err))
        start_reconnect()
      end
    end
  }
  -- Must explicitly call connect() to start the WebSocket connection
  ws:connect()
  print("[MCP] WebSocket connect() called")
end

----------------------------------------------------------------------
-- Reconnection using Dialog timer
----------------------------------------------------------------------
function start_reconnect()
  if reconnect_timer then return end  -- Already running

  print("[MCP] Will attempt reconnection every " .. RECONNECT_INTERVAL_MS .. "ms")

  reconnect_timer = Timer {
    interval = RECONNECT_INTERVAL_MS / 1000.0,
    ontick = function()
      if not connected and not ws then
        connect()
      elseif connected then
        if reconnect_timer then
          reconnect_timer:stop()
          reconnect_timer = nil
        end
      end
    end
  }
  reconnect_timer:start()
end

----------------------------------------------------------------------
-- Plugin lifecycle
----------------------------------------------------------------------
function init(plugin)
  print("[MCP] Aseprite MCP Pro v" .. VERSION .. " initializing...")

  -- Read port from preferences
  if plugin.preferences and plugin.preferences.port then
    port = plugin.preferences.port
  end

  -- Load all command modules
  load_commands()

  -- Attempt initial connection
  connect()

  -- Register menu command for manual reconnect
  plugin:newCommand {
    id = "mcp_reconnect",
    title = "MCP Pro: Reconnect",
    group = "help_about",
    onclick = function()
      print("[MCP] Manual reconnect requested")
      connect()
    end,
  }

  -- Register menu command for connection status
  plugin:newCommand {
    id = "mcp_status",
    title = "MCP Pro: Status",
    group = "help_about",
    onclick = function()
      local status = connected and "Connected" or "Disconnected"
      app.alert {
        title = "Aseprite MCP Pro",
        text = {
          "Version: " .. VERSION,
          "Status: " .. status,
          "Port: " .. port,
          "Commands: " .. count_keys(handlers),
        },
      }
    end,
  }

  -- Register settings command
  plugin:newCommand {
    id = "mcp_settings",
    title = "MCP Pro: Settings",
    group = "help_about",
    onclick = function()
      local dlg = Dialog("MCP Pro Settings")
      dlg:number { id = "port", label = "Server Port:", text = tostring(port) }
      dlg:button { id = "ok", text = "Save" }
      dlg:button { id = "cancel", text = "Cancel" }
      dlg:show()

      if dlg.data.ok then
        port = math.floor(dlg.data.port)
        plugin.preferences.port = port
        print("[MCP] Port changed to " .. port .. ". Reconnecting...")
        connect()
      end
    end,
  }
end

function exit(plugin)
  print("[MCP] Aseprite MCP Pro shutting down...")
  if reconnect_timer then
    reconnect_timer:stop()
    reconnect_timer = nil
  end
  if ws then
    pcall(function() ws:close() end)
    ws = nil
  end
  connected = false
end
