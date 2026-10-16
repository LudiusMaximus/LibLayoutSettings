-- Copying one layout's look onto another: which layouts are offered as a source,
-- what a copy brings across and what it leaves alone, that it reverts like any
-- other change, copying onto the addon's own settings, the action row that offers
-- it, and a malformed action row being refused at registration. Also the dialog
-- the action row is in: opened first in combat, and how tall it grows.

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(here .. "/stubs.lua")
local Stub, Trigger = STUB.Stub, STUB.Trigger

--------------------------------------------------------------------------------
-- A stubbed edit mode manager with four layouts
--------------------------------------------------------------------------------

EditModeManagerFrame = {
  layoutInfo = {
    activeLayout = 2,
    layouts = {
      { layoutName = "Modern",  layoutType = 0, systems = {} },
      { layoutName = "Travel",  layoutType = 1, systems = {} },
      { layoutName = "Raiding", layoutType = 1, systems = {} },
      { layoutName = "Mine",    layoutType = 2, systems = {} },
    },
  },
  hasActiveChanges = false,
}

function EditModeManagerFrame:GetActiveLayoutInfo()
  return self.layoutInfo.layouts[self.layoutInfo.activeLayout]
end
function EditModeManagerFrame:SetHasActiveChanges(v) self.hasActiveChanges = v and true or false end
function EditModeManagerFrame:CheckForSystemActiveChanges() self:SetHasActiveChanges(false) end
-- Applies the saved layouts, which clears every unsaved change.
function EditModeManagerFrame:UpdateLayoutInfo() self:SetHasActiveChanges(false) end
function EditModeManagerFrame:RevertAllChanges() self:UpdateLayoutInfo() end
function EditModeManagerFrame:SelectSystem() end
function EditModeManagerFrame:ClearSelectedSystem() end
function EditModeManagerFrame:SaveLayouts() Trigger("EditMode.SavedLayouts") end
function EditModeManagerFrame:MakeNewLayout() end
function EditModeManagerFrame:RenameLayout(i, name) self.layoutInfo.layouts[i].layoutName = name end
function EditModeManagerFrame:DeleteLayout(i) table.remove(self.layoutInfo.layouts, i) end
function EditModeManagerFrame:SelectLayout(i)
  self.layoutInfo.activeLayout = i
  self:UpdateLayoutInfo()
end

UnitName = function() return "Tester" end
GetRealmName = function() return "Realm" end

--------------------------------------------------------------------------------

local LLS = STUB.LoadLibrary()

local barFrame = Stub()
function barFrame:IsMouseEnabled() return true end
function barFrame:EnableMouse() end
function barFrame:GetFrameStrata() return "MEDIUM" end

-- Travel is active. Raiding and Mine already hold a look. Modern, a preset, holds
-- one too, left over from before presets were refused.
local storage = {
  ["0:Modern"] = {
    position = { point = "LEFT", relativePoint = "LEFT", x = 5, y = 0 },
    settings = { width = 222, spark = false, barcolor = { r = 1, g = 1, b = 0 } },
  },
  ["1:Travel"] = {
    position = { point = "BOTTOM", relativePoint = "TOP", x = 0, y = -170 },
    settings = { width = 300, spark = true, barcolor = { r = 1, g = 0, b = 0 } },
  },
  ["1:Raiding"] = {
    position = { point = "TOP", relativePoint = "TOP", x = 40, y = -8 },
    settings = { width = 555, spark = false, barcolor = { r = 0, g = 1, b = 0 } },
  },
  ["2:Tester - Realm:Mine"] = {
    position = { point = "CENTER", relativePoint = "CENTER", x = 1, y = 2 },
    settings = { width = 111, spark = true, barcolor = { r = 0, g = 0, b = 1 } },
  },
}

-- The addon's own settings, and a layout's overrides on top of them, which is
-- what the bar wears.
local own = {
  p = "BOTTOM", rp = "TOP", x = 0, y = -170,
  width = 300, spark = true, barcolor = { r = 1, g = 0, b = 0 },
}
local over = {}
local live = setmetatable({}, {
  __index = function(_, k) local v = over[k]; if v == nil then v = own[k] end; return v end,
  __newindex = function(_, k, v) over[k] = v end,
})
local function EditOwn(key, value) own[key] = value; over[key] = nil end

local copied = {}

LLS:RegisterFrame("Bar", {
  GetFrame = function() return barFrame end,
  displayName = "TestBar",
  storage = storage,
  settings = {
    { key = "width", name = "Width", type = "slider", minValue = 40, maxValue = 1000, stepSize = 5 },
    { key = "spark", name = "Spark", type = "checkbox" },
    { key = "barcolor", name = "Bar Color", type = "color" },
    { type = "separator" },
    { type = "revert" },
    { type = "actions", name = "Copy From", placeholder = "Choose...",
      tooltip = "Take the whole look from somewhere else.",
      actions = function()
        local sources = {}
        for _, layout in ipairs(LLS:GetStoredLayouts("Bar")) do
          sources[#sources + 1] = {
            text = layout.name,
            OnClick = function() LLS:CopyFrom("Bar", layout.key) end,
          }
        end
        sources[#sources + 1] = { separator = true }
        sources[#sources + 1] = {
          text = "Settings shared by all characters",
          OnClick = function() copied[#copied + 1] = "shared" end,
        }
        return sources
      end },
  },
  GetSetting = function(key) return live[key] end,
  SetSetting = function(key, value) live[key] = value end,
  EditSetting = EditOwn,
  GetPosition = function() return live.p, live.rp, live.x, live.y end,
  SetPosition = function(p, rp, x, y) live.p, live.rp, live.x, live.y = p, rp, x, y end,
  EditPosition = function(p, rp, x, y) EditOwn("p", p); EditOwn("rp", rp); EditOwn("x", x); EditOwn("y", y) end,
  RestoreOwnSettings = function() for key in pairs(over) do over[key] = nil end end,
  GetDefaultPosition = function() return "BOTTOM", "TOP", 0, -170 end,
})

local H = LLS.handlers
local info = LLS.registrations.Bar

local failures = 0
local function Check(label, condition)
  if not condition then
    failures = failures + 1
    print("  FAIL: " .. label)
  else
    print("  ok:   " .. label)
  end
end

--------------------------------------------------------------------------------

print("== which layouts are offered as a source ==")
local function names()
  local out = {}
  for _, l in ipairs(LLS:GetStoredLayouts("Bar")) do out[#out + 1] = l.name end
  table.sort(out)
  return table.concat(out, ",")
end

Check("the active layout is not offered to itself", names() == "Mine,Raiding")

EditModeManagerFrame:SelectLayout(3)   -- Raiding
H.OnLayoutsUpdated()
Check("switching layouts switches which one is left out", names() == "Mine,Travel")
EditModeManagerFrame:SelectLayout(2)   -- back to Travel
H.OnLayoutsUpdated()

-- A preset is never given anything, so whatever an older version stored for one
-- is dropped on registration and never offered.
Check("a leftover preset entry is dropped", storage["0:Modern"] == nil)
Check("so a preset is not offered", not names():find("Modern"))

-- An entry whose layout the player does not have is unreachable, which is what
-- another character's character layout looks like from here.
storage["2:Someone Else - Realm:Mine"] = { position = {}, settings = {} }
Check("another character's layout is not offered", names() == "Mine,Raiding")
storage["2:Someone Else - Realm:Mine"] = nil

-- And a layout the player has but which holds nothing is not offered either.
storage["2:Tester - Realm:Mine"] = nil
Check("a layout holding nothing is not offered", names() == "Raiding")
storage["2:Tester - Realm:Mine"] = {
  position = { point = "CENTER", relativePoint = "CENTER", x = 1, y = 2 },
  settings = { width = 111, spark = true, barcolor = { r = 0, g = 0, b = 1 } },
}

print("== copying one layout onto another ==")
H.OnEditModeEnter()
Check("Travel owns the bar", LLS:IsManaged("Bar"))
EditModeManagerFrame.hasActiveChanges = false

LLS:CopyFrom("Bar", "1:Raiding")
Check("the width came across", live.width == 555)
Check("and the checkbox", live.spark == false)
Check("and the colour", live.barcolor.r == 0 and live.barcolor.g == 1)
Check("and the position", live.p == "TOP" and live.x == 40 and live.y == -8)
Check("it counts as a change to save", EditModeManagerFrame.hasActiveChanges)
Check("so there is something to revert", LLS:HasChanges("Bar"))

-- The copy must not alias the source, or editing one layout would edit the other.
live.barcolor.g = 0.5
Check("the source colour is untouched", storage["1:Raiding"].settings.barcolor.g == 1)
info.pending.settings.width = 999
Check("the source width is untouched", storage["1:Raiding"].settings.width == 555)
-- The library only ever replaces a position rather than editing it in place, so
-- sharing the table would go unnoticed until something did edit it.
info.pending.position.x = 77
Check("the source position is untouched", storage["1:Raiding"].position.x == 40)

print("== a copy is a change like any other ==")
EditModeManagerFrame:RevertAllChanges()
STUB.RunTimers()
Check("reverting undoes the copy", live.width == 300)
Check("and puts the position back", live.p == "BOTTOM" and live.y == -170)
Check("with nothing left to revert", not LLS:HasChanges("Bar"))

print("== copying while no layout owns the bar goes to the own settings ==")
LLS:SetManaged("Bar", false)
LLS:CopyFrom("Bar", "1:Raiding")
Check("the bar wears the copy", live.width == 555 and live.p == "TOP")
Check("held back until Save", own.width == 300 and own.p == "BOTTOM" and LLS:HasChanges("Bar"))
EditModeManagerFrame:RevertAllChanges()
STUB.RunTimers()
Check("reverting drops it, and Travel owns the bar again",
  own.width == 300 and live.width == 300 and LLS:IsManaged("Bar"))

print("== a source that does not exist is ignored ==")
live.width = 300
LLS:CopyFrom("Bar", "1:NoSuchLayout")
Check("nothing happens", live.width == 300)
LLS:CopyFrom("Bar", nil)
Check("and nil is survivable", live.width == 300)

print("== a dialog first opened in combat ==")
STUB.inCombat = true
local opened = pcall(LLS.SelectFrame, LLS, "Bar")
STUB.inCombat = false
Check("opens without an error", opened and LLS.dialog and LLS.dialog:IsShown())
Check("and leaves the keyboard alone", STUB.slot(LLS.dialog).propagate == nil)
LLS.dialog:GetScript("OnEvent")(LLS.dialog, "PLAYER_REGEN_ENABLED")
Check("until the fight is over", STUB.slot(LLS.dialog).propagate == true)
LLS:ClearSelection()

print("== the action row ==")
LLS:SelectFrame("Bar")
local row = LLS.dialog.rows.actions[1]
Check("an action row was drawn", row ~= nil)
Check("the button shows the placeholder", row.Dropdown:GetDefaultText() == "Choose...")
Check("it is enabled, because there is something to pick", row.Dropdown:IsEnabled())

print("== the dialog fits on the screen ==")
local dialog = LLS.dialog
local fullHeight = dialog:GetHeight()
Check("as tall as its rows on a large screen, and a little more", fullHeight == dialog.libCanvas:GetHeight() + 48 + 20 + 3)
-- Selecting the frame that is already selected redraws nothing, so let go first.
UIParent:SetHeight(fullHeight)
LLS:ClearSelection()
LLS:SelectFrame("Bar")
Check("no taller than 90% of a smaller one", dialog:GetHeight() == math.floor(fullHeight * 0.9))
Check("the rows scrolling in what is left", dialog.libCanvas:GetHeight() > dialog:GetHeight() - 48 - 20)
-- Rows that would overrun 90% of the screen by only a little are shown whole.
UIParent:SetHeight(math.ceil((fullHeight - 3) / 0.93))
LLS:ClearSelection()
LLS:SelectFrame("Bar")
Check("but whole when they only just overrun it", dialog:GetHeight() == fullHeight)
UIParent:SetHeight(1080)
LLS:ClearSelection()
LLS:SelectFrame("Bar")
-- A control hanging below its row leaves something to scroll, as measured in the
-- game, which the dialog grows by and keeps.
STUB.slot(dialog.libScroll).scripts.OnScrollRangeChanged(dialog.libScroll, 0, 3.5)
Check("rows reaching further than laid out grow the dialog", dialog:GetHeight() == fullHeight + 3.5)
LLS:ClearSelection()
LLS:SelectFrame("Bar")
Check("and it stays grown when drawn again", dialog:GetHeight() == fullHeight + 3.5)
dialog.libOverhang = nil
LLS:ClearSelection()
LLS:SelectFrame("Bar")

-- Open the menu the way the dropdown would.
local entries = {}
local menu = {
  CreateButton = function(_, text, onClick)
    entries[#entries + 1] = { text = text, onClick = onClick }
    return Stub()
  end,
  CreateDivider = function()
    entries[#entries + 1] = { divider = true }
    return Stub()
  end,
}
row.Dropdown:GetGenerator()(row.Dropdown, menu)

Check("every source is listed", #entries == 4)
Check("the layouts come first", entries[1].text == "Raiding" and entries[2].text == "Mine")
Check("then a divider", entries[3].divider == true)
Check("then the profiles", entries[4].text == "Settings shared by all characters")

live.width = 300
entries[1].onClick()
Check("picking a layout copies it", live.width == 555)

entries[4].onClick()
Check("picking a profile reaches the addon", copied[1] == "shared")

print("== the row greys out when there is nothing to copy ==")
-- Strip every other layout and let the addon offer nothing.
info.settings[#info.settings].actions = function() return {} end
H.OnEditModeExit()
H.OnEditModeEnter()
LLS:SelectFrame("Bar")
row = LLS.dialog.rows.actions[1]
Check("no sources, no dropdown", row.Dropdown:IsEnabled() == false)
H.OnEditModeExit()

print("== a malformed action row is refused ==")
local ok = pcall(LLS.RegisterFrame, LLS, "Bad", {
  GetFrame = function() return Stub() end,
  displayName = "Bad",
  storage = {},
  settings = { { type = "actions", name = "No actions" } },
  GetSetting = function() end,
  SetSetting = function() end,
  EditSetting = function() end,
  GetPosition = function() return "CENTER", "CENTER", 0, 0 end,
  SetPosition = function() end,
  EditPosition = function() end,
  RestoreOwnSettings = function() end,
})
Check("an action row with no actions is refused", not ok)

print("")
print(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED"))

os.exit(failures == 0 and 0 or 1)
