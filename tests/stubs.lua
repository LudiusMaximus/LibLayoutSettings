-- A stubbed World of Warcraft client, just enough of one to load LibLayoutSettings
-- outside the game. Every test starts with dofile on this file.
--
-- Frames record the handful of things the tests read back (scripts, enabled
-- state, text, sizes, mouse state, children, menu generators). Everything else on
-- a frame is a table that answers to any call. Runs on Lua 5.1 and later.

local unpack = table.unpack or unpack

-- This folder, and the library one level up, wherever the repository is checked out.
local here = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or ".")

--------------------------------------------------------------------------------
-- Stubs
--------------------------------------------------------------------------------

local frameState = setmetatable({}, { __mode = "k" })
local function slot(self)
  local s = frameState[self]
  if not s then s = { scripts = {} }; frameState[self] = s end
  return s
end

local recorders = {
  SetScript = function(self, name, fn) slot(self).scripts[name] = fn end,
  GetScript = function(self, name) return slot(self).scripts[name] end,
  HookScript = function(self, name, fn)
    local scripts = slot(self).scripts
    local previous = scripts[name]
    scripts[name] = previous and function(...) previous(...) fn(...) end or fn
  end,
  SetEnabled = function(self, v) slot(self).enabled = v and true or false end,
  IsEnabled = function(self)
    local e = slot(self).enabled
    if e == nil then return true end
    return e
  end,
  SetText = function(self, v) slot(self).text = v end,
  GetText = function(self) return slot(self).text end,
  GetUnboundedStringWidth = function(self) return #(slot(self).text or "") * 7 end,
  SetDefaultText = function(self, v) slot(self).defaultText = v end,
  GetDefaultText = function(self) return slot(self).defaultText end,
  SetWidth = function(self, v) slot(self).width = v end,
  GetWidth = function(self) return slot(self).width end,
  SetHeight = function(self, v) slot(self).height = v end,
  GetHeight = function(self) return slot(self).height end,
  SetSize = function(self, w, h) slot(self).width, slot(self).height = w, h end,
  EnableMouse = function(self, v) slot(self).mouseEnabled = v ~= false end,
  IsMouseEnabled = function(self) return slot(self).mouseEnabled == true end,
  IsMouseOver = function(self) return slot(self).mouseOver == true end,
  GetChildren = function(self) return unpack(slot(self).children or {}) end,
  -- Shown only once Show is called, and Show and Hide run the scripts a real
  -- frame would. Parents are not followed, so visible means shown.
  Show = function(self)
    local s = slot(self)
    if not s.shown then
      s.shown = true
      if s.scripts.OnShow then s.scripts.OnShow(self) end
    end
  end,
  Hide = function(self)
    local s = slot(self)
    if s.shown then
      s.shown = false
      if s.scripts.OnHide then s.scripts.OnHide(self) end
    end
  end,
  IsShown = function(self) return slot(self).shown == true end,
  IsVisible = function(self) return slot(self).shown == true end,
  -- The slider's change callback, kept so the test can move the slider.
  RegisterCallback = function(self, _, fn) slot(self).callback = fn end,
  -- The menu generator, kept so the test can open the dropdown.
  SetupMenu = function(self, generator) slot(self).generator = generator end,
  GetGenerator = function(self) return slot(self).generator end,
}

local StubMT
StubMT = {
  __index = function(t, k)
    local recorder = recorders[k]
    if recorder then return recorder end
    -- The library's own fields on a frame are nil until it sets them, as on a
    -- real frame, and the library tells a dialog from a page by them.
    if type(k) == "string" and k:sub(1, 3) == "lib" then return nil end
    local v = setmetatable({}, StubMT)
    rawset(t, k, v)
    return v
  end,
  __call = function() return nil end,
}
local function Stub() return setmetatable({}, StubMT) end

CreateFrame = function(_, _, parent)
  local frame = Stub()
  if parent then
    local parentSlot = slot(parent)
    parentSlot.children = parentSlot.children or {}
    table.insert(parentSlot.children, frame)
  end
  return frame
end

UIParent = Stub()
ColorPickerFrame = Stub()
PlaySound = function() end
SOUNDKIT = Stub()
ADDONS = "AddOns"
CreateMinimalSliderFormatter = function() return function(v) return v end end
MinimalSliderWithSteppersMixin = { Label = { Right = 2 }, Event = { OnValueChanged = "OnValueChanged" } }
EditModeSystemSelectionMixin = {}
HUD_EDIT_MODE_REVERT_CHANGES = "Revert Changes"
HUD_EDIT_MODE_RESET_POSITION = "Reset Position"
function IsShiftKeyDown() return false end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local tip = { shown = false }
local FakeTooltip = {}
function FakeTooltip:SetOwner(frame) tip.owner = frame end
function FakeTooltip:GetOwner() return tip.owner end
function FakeTooltip:IsShown() return tip.shown end
function FakeTooltip:ClearAllPoints() end
function FakeTooltip:SetPoint() end
function FakeTooltip:Show() tip.shown = true end
function FakeTooltip:Hide() tip.shown = false end
function GetAppropriateTooltip() return FakeTooltip end
function GameTooltip_SetTitle(_, t) tip.title = t end
function GameTooltip_AddNormalLine(_, t) tip.text = t end

Enum = { EditModeLayoutType = { Preset = 0, Account = 1, Character = 2, Override = 3 } }

function CopyTable(t)
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = type(v) == "table" and CopyTable(v) or v
  end
  return copy
end

local timers = {}
C_Timer = { After = function(_, fn) table.insert(timers, fn) end }

function hooksecurefunc(tbl, name, post)
  local original = tbl[name]
  tbl[name] = function(...)
    local a, b, c, d = original(...)
    post(...)
    return a, b, c, d
  end
end

local callbacks = {}
local function Trigger(event)
  for _, fn in ipairs(callbacks[event] or {}) do fn() end
end

EventRegistry = {
  RegisterCallback = function(_, event, fn) callbacks[event] = callbacks[event] or {}; table.insert(callbacks[event], fn) end,
  TriggerEvent = function(_, event) Trigger(event) end,
}

LibStub = {
  libs = {},
  NewLibrary = function(self, major, minor)
    local existing = self.libs[major]
    if existing and existing.minor >= minor then return nil end
    local lib = existing and existing.lib or {}
    self.libs[major] = { lib = lib, minor = minor }
    return lib
  end,
  GetLibrary = function(self, major) return self.libs[major] and self.libs[major].lib end,
}
setmetatable(LibStub, { __call = function(self, major) return self:GetLibrary(major) end })

--------------------------------------------------------------------------------

-- Shared with every test file that loads this one.
STUB = { Stub = Stub, slot = slot, tip = tip, timers = timers, Trigger = Trigger, here = here }

-- Loads the library itself, from the repository this file is part of.
function STUB.LoadLibrary()
  assert(loadfile(here .. "/../LibLayoutSettings.lua"))()
  return LibStub("LibLayoutSettings-1.0")
end
function STUB.RunTimers()
  local pending = {}
  for i, fn in ipairs(timers) do pending[i] = fn end
  for i = #timers, 1, -1 do timers[i] = nil end
  for _, fn in ipairs(pending) do fn() end
end
