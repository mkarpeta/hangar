--- === Hangar ===
---
--- Hangar: a Cmd+Tab-style overview of your AeroSpace workspaces: every workspace as a tile
--- with its name, a thumbnail of how it looked when you last left it, and its apps.
---
--- Press the trigger (default ⌥Space), keep the modifier held, pick a workspace with the
--- arrow keys or its key (1, 2, …), release the modifier to go there. Esc cancels.
---
--- Download: https://github.com/mkarpeta/hangar

local obj = {}
obj.__index = obj

obj.name = "Hangar"
obj.version = "0.1.0"
obj.author = "Maciej Karpeta"
obj.homepage = "https://github.com/mkarpeta/hangar"
obj.license = "MIT - https://opensource.org/licenses/MIT"

obj.spoonPath = hs.spoons.scriptPath()

local HOME = os.getenv("HOME")
local T = hs.eventtap.event.types

--- Hangar.defaults
--- Variable
--- Default configuration. Pass a table with any subset of these keys to `:start()`.
obj.defaults = {
  -- Shortcut that opens the overview. Releasing all of `mods` goes to the selected workspace.
  -- key: the key pressed with `mods` (false = no key shortcut, e.g. hold-only).
  -- hold: seconds; also open when `mods` alone are held this long (nil = off). Pressing any
  --       key or clicking before then cancels, so quick chords like mods+1 never show it.
  trigger      = { mods = { "alt" }, key = "space", hold = nil },
  -- Text shown for the modifier in the key hints (default: built from trigger.mods, e.g. "⌥").
  keyLabel     = nil,
  -- Path to the aerospace CLI. nil = auto-detect (/opt/homebrew/bin, /usr/local/bin, PATH).
  aerospace    = nil,
  -- Workspaces to show, in order, e.g. { "1", "2", "3" }. nil = whatever
  -- `aerospace list-workspaces --all` returns (persistent + non-empty workspaces).
  workspaces   = nil,
  -- Display names, e.g. { ["1"] = "Mail", ["2"] = "Code" }. Missing ones show "Workspace N".
  names        = {},
  columns      = 5,
  maxWidth     = 1180,        -- max panel width in points
  header       = true,        -- top bar: title + current workspace
  footer       = true,        -- bottom bar: key hints
  theme        = "auto",      -- "auto" (follow macOS), "dark" or "light"
  accent       = "#ff6363",   -- selection ring and "current workspace" dot
  strings      = {
    title = "Workspaces", current = "Current", empty = "Empty", noPreview = "No preview",
    workspace = "Workspace", select = "Select", go = "Go", release = "release",
    jump = "Jump", cancel = "Cancel",
  },
  thumbnails   = {
    enabled   = true,
    delay     = 0.45,         -- seconds after a workspace change before the screenshot
    maxSize   = 720,          -- px, longest side
    quality   = 70,           -- JPEG quality
    -- Points to crop from the right edge on screens whose name contains the key,
    -- e.g. { ["X34"] = 880 } to leave out a sidebar.
    cropRight = {},
  },
  -- Seconds between polls of the focused workspace. Only needed if you don't add the
  -- exec-on-workspace-change hook to aerospace.toml (see README). nil = off.
  pollInterval = nil,
  cacheDir     = HOME .. "/.cache/hangar",
  urlEvent     = "hangar",              -- hammerspoon://hangar?ws=<name>
}

----------------------------------------------------------------------------- utils

local function merge(base, over)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(over or {}) do
    if type(v) == "table" and type(out[k]) == "table" and #v == 0 and next(v) ~= nil then
      out[k] = merge(out[k], v)   -- nested option table: merge keys
    else
      out[k] = v                  -- scalars and lists: replace
    end
  end
  return out
end

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local MOD_SYMBOLS = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘", fn = "fn" }
local MOD_ORDER = { "ctrl", "alt", "shift", "cmd", "fn" }

local function modsLabel(mods)
  local set, out = {}, ""
  for _, m in ipairs(mods) do set[m] = true end
  for _, m in ipairs(MOD_ORDER) do if set[m] then out = out .. MOD_SYMBOLS[m] end end
  return out
end

local function findAerospace(explicit)
  if explicit then return explicit end
  for _, p in ipairs({ "/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace" }) do
    if hs.fs.attributes(p) then return p end
  end
  local out = hs.execute("command -v aerospace", true)
  out = trim(out)
  return out ~= "" and out or "aerospace"
end

----------------------------------------------------------------------------- state

function obj:init()
  self.cfg = nil
  self.visible = false
  self.currentWs = nil
  self.selectedWs = nil
  self.wsList = {}
  self.thumbGen, self.sentGen = {}, {}
  self.iconCache, self.sentIcons = {}, {}
  self.panelW, self.panelH = 1200, 520
  return self
end

function obj:_aero(args)
  local out, ok = hs.execute(string.format("%q %s", self.aerospace, args))
  return ok and out or ""
end

function obj:_thumbPath(ws)
  return self.cfg.cacheDir .. "/thumb-" .. ws:gsub("[^%w%-_]", "_") .. ".jpg"
end

----------------------------------------------------------------------------- data

function obj:_collect()
  local focused = trim(self:_aero("list-workspaces --focused"))

  local list = self.cfg.workspaces
  if not list then
    list = {}
    for ws in self:_aero("list-workspaces --all"):gmatch("[^\n]+") do table.insert(list, trim(ws)) end
  end

  local wins = {}
  local out = self:_aero("list-windows --all --format '%{workspace}|%{app-bundle-id}|%{app-name}'")
  for line in out:gmatch("[^\n]+") do
    local ws, bid, app = line:match("^([^|]*)|([^|]*)|(.*)$")
    if ws and ws ~= "" then
      wins[ws] = wins[ws] or {}
      table.insert(wins[ws], { bid = bid, app = app })
    end
  end
  return focused, list, wins
end

function obj:_icon(bid)
  if self.iconCache[bid] == nil then
    local img = bid ~= "" and hs.image.imageFromAppBundle(bid) or nil
    self.iconCache[bid] = img and img:setSize({ w = 64, h = 64 }):encodeAsURLString(true, "PNG") or false
  end
  return self.iconCache[bid] or nil
end

function obj:_thumbData(ws)
  local f = io.open(self:_thumbPath(ws), "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return "data:image/jpeg;base64," .. hs.base64.encode(data)
end

----------------------------------------------------------------------------- layout

function obj:_captureRect(scr)
  local f = scr:fullFrame()
  local w = f.w
  local name = scr:name() or ""
  for pattern, px in pairs(self.cfg.thumbnails.cropRight or {}) do
    if name:find(pattern, 1, true) then w = f.w - px end
  end
  return { x = f.x, y = f.y, w = w, h = f.h }
end

function obj:_layout()
  local scr = hs.screen.mainScreen()
  local sf = scr:frame()
  local cr = self:_captureRect(scr)
  local cols = math.max(1, self.cfg.columns)
  local inner = math.min(self.cfg.maxWidth, sf.w - 120)
  local tileW = math.floor((inner - 20 - (cols - 1) * 6) / cols)
  local thumbH = math.floor((tileW - 18) * cr.h / cr.w)
  return scr, tileW, thumbH
end

function obj:_place(scr)
  local sf = scr:frame()
  self.webview:frame({
    x = sf.x + math.floor((sf.w - self.panelW) / 2),
    y = sf.y + math.floor((sf.h - self.panelH) / 2.4),
    w = self.panelW, h = self.panelH,
  })
end

----------------------------------------------------------------------------- render

function obj:_render()
  local focused, list, wins = self:_collect()
  if focused ~= "" then self.currentWs = focused end
  self.wsList = list
  if not self.selectedWs then self.selectedWs = self.currentWs end
  local scr, tileW, thumbH = self:_layout()
  local cfg = self.cfg

  local payload = {
    focused = self.currentWs, selected = self.selectedWs, order = list,
    tileW = tileW, thumbH = thumbH, columns = cfg.columns,
    ui = {
      header = cfg.header, footer = cfg.footer, theme = cfg.theme, accent = cfg.accent,
      keyLabel = cfg.keyLabel or modsLabel(cfg.trigger.mods), strings = cfg.strings,
    },
    workspaces = {}, thumbs = {}, icons = {},
  }

  for _, ws in ipairs(list) do
    local apps, seen, count = {}, {}, 0
    for _, w in ipairs(wins[ws] or {}) do
      count = count + 1
      if not seen[w.bid] then
        seen[w.bid] = true
        table.insert(apps, { bid = w.bid, name = w.app })
        if not self.sentIcons[w.bid] then
          local icon = self:_icon(w.bid)
          if icon then payload.icons[w.bid] = icon; self.sentIcons[w.bid] = true end
        end
      end
    end
    payload.workspaces[ws] = { name = cfg.names[ws] or "", apps = apps, windows = count }

    if self.thumbGen[ws] and self.sentGen[ws] ~= self.thumbGen[ws] then
      local data = self:_thumbData(ws)
      if data then payload.thumbs[ws] = data; self.sentGen[ws] = self.thumbGen[ws] end
    end
  end

  self.webview:evaluateJavaScript("render(" .. hs.json.encode(payload) .. ")")
  return scr
end

----------------------------------------------------------------------------- thumbnails

function obj:capture(ws)
  ws = ws or self.currentWs
  local th = self.cfg.thumbnails
  if not th.enabled or self.visible or not ws or ws == "" then return end
  local cr = self:_captureRect(hs.screen.mainScreen())
  local out = self:_thumbPath(ws)
  local tmp = out .. ".tmp.jpg"
  local rect = string.format("%d,%d,%d,%d", cr.x, cr.y, cr.w, cr.h)

  hs.task.new("/usr/sbin/screencapture", function(rc)
    if rc ~= 0 then os.remove(tmp); return end
    hs.task.new("/usr/bin/sips", function(rc2)
      -- Keep it only if we were still on that workspace when the shot was taken.
      if rc2 == 0 and self.currentWs == ws then
        os.rename(tmp, out)
        self.thumbGen[ws] = (self.thumbGen[ws] or 0) + 1
        if self.visible then self:_render() end
      else
        os.remove(tmp)
      end
    end, { "-Z", tostring(th.maxSize), "-s", "formatOptions", tostring(th.quality), tmp }):start()
  end, { "-x", "-t", "jpg", "-R", rect, tmp }):start()
end

function obj:_scheduleCapture(delay)
  if self.captureTimer then self.captureTimer:stop() end
  local ws = self.currentWs
  self.captureTimer = hs.timer.doAfter(delay or self.cfg.thumbnails.delay, function()
    if self.currentWs == ws and not self.visible then self:capture(ws) end
  end)
end

----------------------------------------------------------------------------- show / hide

--- Hangar:show()
--- Method
--- Shows the overview.
function obj:show()
  if self.visible then return end
  self.selectedWs = nil
  local scr = self:_render()
  self:_place(scr)
  self.webview:show()
  self.visible = true
end

--- Hangar:hide([commit])
--- Method
--- Hides the overview. With `commit = true`, switches to the selected workspace.
function obj:hide(commit)
  if not self.visible then return end
  self.webview:hide()
  self.visible = false
  if commit and self.selectedWs and self.selectedWs ~= self.currentWs then
    self:_aero("workspace " .. string.format("%q", self.selectedWs))
  end
  self:_scheduleCapture(0.25) -- refresh the workspace you ended up on
end

--- Hangar:toggle()
--- Method
--- Shows the overview, or hides it and goes to the selected workspace.
function obj:toggle()
  if self.visible then self:hide(true) else self:show() end
end

function obj:_select(ws)
  self.selectedWs = ws
  self.webview:evaluateJavaScript("select(" .. hs.json.encode({ ws }) .. "[0])")
end

function obj:_move(dir)
  local list, n = self.wsList, #self.wsList
  if n == 0 then return end
  local i = 1
  for k, ws in ipairs(list) do if ws == self.selectedWs then i = k end end
  local cols = math.max(1, self.cfg.columns)
  local step = ({ left = -1, right = 1, up = -cols, down = cols })[dir]
  i = ((i - 1 + step) % n) + 1
  self:_select(list[i])
end

----------------------------------------------------------------------------- events

function obj:_onWorkspaceChanged(ws)
  if not ws or ws == "" or ws == self.currentWs then
    if self.visible then self:_render() end
    return
  end
  self.currentWs = ws
  if self.visible then
    self.selectedWs = ws
    self:_render()
  else
    self:_scheduleCapture()
  end
end

local ARROWS = { [123] = "left", [124] = "right", [125] = "down", [126] = "up" }
local RETURN_KEYS = { [36] = true, [76] = true }
local ESCAPE = 53

function obj:_anyTriggerModHeld(flags)
  for _, m in ipairs(self.cfg.trigger.mods) do
    if flags[m] then return true end
  end
  return false
end

-- While the overview is up:
--   all trigger modifiers released / Return → go to the selected workspace
--   arrows → move the selection
--   a workspace's key (1, 2, …) → go there right away, keep the overview open
--   Esc → close without switching
-- Handled keys are swallowed so AeroSpace bindings on the same chords don't also fire.
--
-- "Any trigger modifier still held" rather than "all of them" keeps this working with
-- remappers such as HyperKey, which turn Caps Lock into ⌘ and add ⌃⌥⇧ only later.
local MOD_KEYS = { "cmd", "alt", "ctrl", "shift", "fn" }

-- True when exactly the trigger modifiers are down (no extra ones).
function obj:_onlyTriggerMods(flags)
  local want = {}
  for _, m in ipairs(self.cfg.trigger.mods) do want[m] = true end
  for _, m in ipairs(MOD_KEYS) do
    if (flags[m] and true or false) ~= (want[m] or false) then return false end
  end
  return #self.cfg.trigger.mods > 0
end

function obj:_cancelHold()
  if self.holdTimer then self.holdTimer:stop(); self.holdTimer = nil end
end

-- Hold-to-open: trigger modifiers held alone for `trigger.hold` seconds.
function obj:_watchHold(e)
  local t = e:getType()
  if t == T.flagsChanged then
    if self:_onlyTriggerMods(e:getFlags()) then
      if not self.holdTimer then
        self.holdTimer = hs.timer.doAfter(self.cfg.trigger.hold, function()
          self.holdTimer = nil
          if self:_onlyTriggerMods(hs.eventtap.checkKeyboardModifiers()) then self:show() end
        end)
      end
    else
      self:_cancelHold()
    end
  else
    self:_cancelHold() -- a key or a click: it's a chord, not a hold
  end
end

function obj:_onEvent(e)
  if not self.visible then
    if self.cfg.trigger.hold then self:_watchHold(e) end
    return false
  end
  local t = e:getType()

  if t == T.flagsChanged then
    if #self.cfg.trigger.mods > 0 and not self:_anyTriggerModHeld(e:getFlags()) then
      self:hide(true)
    end
    return false
  end

  if t ~= T.keyDown then return false end

  local code = e:getKeyCode()
  if ARROWS[code] then self:_move(ARROWS[code]); return true end
  if RETURN_KEYS[code] then self:hide(true); return true end
  if code == ESCAPE then self:hide(false); return true end

  local char = hs.keycodes.map[code]
  if char and char ~= (self.cfg.trigger.key or "") then
    for _, ws in ipairs(self.wsList) do
      if ws:lower() == char:lower() then
        self.selectedWs = ws
        self:_aero("workspace " .. string.format("%q", ws))
        return true
      end
    end
  end
  return false
end

----------------------------------------------------------------------------- setup

function obj:_buildWebview()
  local uc = hs.webview.usercontent.new("hangar")
  uc:setCallback(function(msg)
    local body = msg.body or {}
    if body.type == "size" and body.w and body.h then
      self.panelW, self.panelH = body.w, body.h
      if self.visible then self:_place(hs.screen.mainScreen()) end
    elseif body.type == "switch" and body.ws then
      self.selectedWs = body.ws
      self:hide(true)
    end
  end)

  local f = io.open(self.spoonPath .. "/overlay.html", "r")
  local html = f and f:read("*a") or "<p>overlay.html missing</p>"
  if f then f:close() end

  self.webview = hs.webview.new({ x = 0, y = 0, w = self.panelW, h = self.panelH },
                                { developerExtrasEnabled = false }, uc)
    :windowStyle({ "borderless" })
    :transparent(true)
    :allowTextEntry(false)
    :shadow(false)
    :level(hs.drawing.windowLevels.popUpMenu)
    :behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle", "fullScreenAuxiliary" })
    :html(html)
end

--- Hangar:start([config])
--- Method
--- Starts the overview. `config` overrides any of `Hangar.defaults`.
function obj:start(config)
  self:stop()
  self.cfg = merge(self.defaults, config)
  self.aerospace = findAerospace(self.cfg.aerospace)

  hs.fs.mkdir(self.cfg.cacheDir:match("^(.*)/[^/]+$"))
  hs.fs.mkdir(self.cfg.cacheDir)
  self:_buildWebview()

  -- Thumbnails from earlier sessions are still useful.
  for file in hs.fs.dir(self.cfg.cacheDir) do
    local ws = file:match("^thumb%-(.+)%.jpg$")
    if ws then self.thumbGen[ws] = 1 end
  end

  self.currentWs = trim(self:_aero("list-workspaces --focused"))

  hs.urlevent.bind(self.cfg.urlEvent, function(_, params) self:_onWorkspaceChanged(params.ws) end)

  if self.cfg.pollInterval then
    self.pollTimer = hs.timer.doEvery(self.cfg.pollInterval, function()
      local ws = trim(self:_aero("list-workspaces --focused"))
      if ws ~= "" and ws ~= self.currentWs then self:_onWorkspaceChanged(ws) end
    end)
  end

  if self.cfg.trigger.key then
    self.hotkey = hs.hotkey.bind(self.cfg.trigger.mods, self.cfg.trigger.key, function() self:toggle() end)
  end

  self.tap = hs.eventtap.new({ T.flagsChanged, T.keyDown, T.leftMouseDown, T.rightMouseDown },
                             function(e) return self:_onEvent(e) end)
  self.tap:start()
  -- macOS disables event taps that are too slow; keep it alive.
  self.tapWatchdog = hs.timer.doEvery(5, function()
    if self.tap and not self.tap:isEnabled() then self.tap:start() end
  end)
  return self
end

--- Hangar:stop()
--- Method
--- Stops the overview and removes its hotkey, event tap and timers.
function obj:stop()
  if self.hotkey then self.hotkey:delete(); self.hotkey = nil end
  if self.tap then self.tap:stop(); self.tap = nil end
  for _, k in ipairs({ "tapWatchdog", "pollTimer", "captureTimer", "holdTimer" }) do
    if self[k] then self[k]:stop(); self[k] = nil end
  end
  if self.cfg then hs.urlevent.bind(self.cfg.urlEvent, nil) end
  if self.webview then self.webview:delete(); self.webview = nil end
  self.visible = false
  return self
end

--- Hangar:state()
--- Method
--- Returns { visible, current, selected } — handy for debugging from the console.
function obj:state()
  return { visible = self.visible, current = self.currentWs, selected = self.selectedWs }
end

return obj
