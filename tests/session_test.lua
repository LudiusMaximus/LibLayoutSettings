-- The edit mode session against Blizzard's real call sequences: saving,
-- cancelling, Revert All, reverting one frame, ticking not being a change,
-- presets being read only, a new layout made by saving on a preset, importing,
-- renaming, deleting, the parked look and switching layouts.
--
-- The edit mode manager below copies the order in which Blizzard_EditMode calls
-- things, because the library's correctness depends on that order: MakeNewLayout
-- reverts before it creates, inserts in the middle of the list and saves on the
-- way, and RevertAllChanges refreshes the layouts synchronously.

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(here .. "/stubs.lua")
local Stub, Trigger, RunTimers = STUB.Stub, STUB.Trigger, STUB.RunTimers

--------------------------------------------------------------------------------
-- Edit mode manager, modelled on Blizzard_EditMode/Shared/EditModeManager.lua
--------------------------------------------------------------------------------

local M = {
  layoutInfo = {
    activeLayout = 2,
    layouts = {
      { layoutName = "Modern", layoutType = 0 },
      { layoutName = "A",      layoutType = 1 },
      { layoutName = "B",      layoutType = 1 },
      { layoutName = "Mine",   layoutType = 2 },
    },
  },
  hasActiveChanges = false,
}
EditModeManagerFrame = M

-- Things C_EditMode does on the C side arrive later, as an event.
local queued = {}
local function NextFrame()
  local run = queued
  queued = {}
  for _, fn in ipairs(run) do fn() end
  RunTimers()
end

function M:GetActiveLayoutInfo()
  return self.layoutInfo and self.layoutInfo.layouts[self.layoutInfo.activeLayout]
end
function M:SetHasActiveChanges(v) self.hasActiveChanges = v and true or false end
function M:CheckForSystemActiveChanges() self:SetHasActiveChanges(false) end
function M:ClearSelectedSystem() end
function M:SelectSystem() end
function M:UpdateLayoutInfo() end

function M:SaveLayouts()
  self.hasActiveChanges = false
  Trigger("EditMode.SavedLayouts")
end

-- Clears the selection, then re-applies the stored layouts synchronously.
function M:RevertAllChanges()
  self:ClearSelectedSystem()
  self:UpdateLayoutInfo()
end

-- Reverts first, inserts in the middle of the list, saves, and has the layout
-- activated later by the client.
function M:MakeNewLayout(newLayoutInfo, layoutType, layoutName, isLayoutImported)
  self:RevertAllChanges()
  newLayoutInfo.layoutType = layoutType
  newLayoutInfo.layoutName = layoutName
  local index = 3            -- after the preset and the first account layout
  table.insert(self.layoutInfo.layouts, index, newLayoutInfo)
  -- Blizzard keeps activeLayout pointing at the same layout across the insert.
  if self.layoutInfo.activeLayout >= index then
    self.layoutInfo.activeLayout = self.layoutInfo.activeLayout + 1
  end
  self:SaveLayouts()
  queued[#queued + 1] = function()
    self.layoutInfo.activeLayout = index
    self:UpdateLayoutInfo()
  end
end

function M:RenameLayout(layoutIndex, layoutName)
  local layout = self.layoutInfo.layouts[layoutIndex]
  if layout and layout.layoutType ~= 0 then
    layout.layoutName = layoutName
    self:SaveLayouts()
  end
end

function M:DeleteLayout(layoutIndex)
  local layout = self.layoutInfo.layouts[layoutIndex]
  if layout and layout.layoutType ~= 0 then
    table.remove(self.layoutInfo.layouts, layoutIndex)
    if self.layoutInfo.activeLayout > layoutIndex then
      self.layoutInfo.activeLayout = self.layoutInfo.activeLayout - 1
    end
    self:SaveLayouts()
  end
end

function M:SelectLayout(layoutIndex)
  if layoutIndex ~= self.layoutInfo.activeLayout then
    self:ClearSelectedSystem()
    queued[#queued + 1] = function()
      self.layoutInfo.activeLayout = layoutIndex
      self:UpdateLayoutInfo()
    end
  end
end

-- Blizzard hands the Revert All Changes button a closure over RevertAllChanges
-- when it loads, so the button calls the original and never a hook on it.
M.RevertAllChangesButton = Stub()
do
  local revert = M.RevertAllChanges
  M.RevertAllChangesButton:SetScript("OnClick", function() revert(M) end)
end

local function EnterEditMode() Trigger("EditMode.Enter") end
local function ClickRevertAll()
  M.RevertAllChangesButton:GetScript("OnClick")(M.RevertAllChangesButton)
  NextFrame()
end
local function ExitAndSave() M:SaveLayouts(); Trigger("EditMode.Exit") end
local function ExitAndDiscard() M:RevertAllChanges(); Trigger("EditMode.Exit") end
local function Switch(i) M:SelectLayout(i); NextFrame() end

UnitName = function() return "Tester" end
GetRealmName = function() return "Realm" end

--------------------------------------------------------------------------------
-- The addon under test: a bar whose own settings are blue, 300 wide.
--------------------------------------------------------------------------------

local LLS = STUB.LoadLibrary()

-- InFlight's own model: the user's settings, a layout's overrides on top, and
-- the bar drawn from overrides falling through to the user's settings. Writing a
-- value is not the same as pinning it as an override, and the tests can tell.
local own = { p = "BOTTOM", rp = "TOP", x = 0, y = -170, width = 300, color = "blue" }
local over = {}
local bar = setmetatable({}, {
  __index = function(_, k) local v = over[k]; if v == nil then v = own[k] end; return v end,
  __newindex = function(_, k, v) over[k] = v end,
})
local function ResetBar() for k in pairs(over) do over[k] = nil end end

local storage = {}
local barFrame = Stub()
function barFrame:IsMouseEnabled() return true end
function barFrame:EnableMouse() end
function barFrame:GetFrameStrata() return "MEDIUM" end

LLS:RegisterFrame("Bar", {
  GetFrame = function() return barFrame end,
  displayName = "Bar",
  storage = storage,
  settings = {
    { key = "width", name = "Width", type = "slider", minValue = 40, maxValue = 1000 },
    { key = "color", name = "Color", type = "dropdown", options = {} },
    { type = "revert" },
  },
  RestoreOwnSettings = ResetBar,
  GetSetting = function(key) return bar[key] end,
  SetSetting = function(key, value) bar[key] = value end,
  GetPosition = function() return bar.p, bar.rp, bar.x, bar.y end,
  SetPosition = function(p, rp, x, y) bar.p, bar.rp, bar.x, bar.y = p, rp, x, y end,
})

local info = LLS.registrations.Bar

-- A change exactly as the dialog makes it: onto the bar and into the pending entry.
local function Edit(key, value)
  bar[key] = value
  LLS:Capture("Bar")
end

local function keys()
  local out = {}
  for k, v in pairs(storage) do out[#out + 1] = k .. (v.inactive and "(parked)" or "") end
  table.sort(out)
  return table.concat(out, " ")
end

local failures, count = 0, 0
local function Check(label, ok)
  count = count + 1
  if ok then print("  ok:   " .. label)
  else failures = failures + 1; print("  FAIL: " .. label) end
end

--------------------------------------------------------------------------------

print("== saving ==")
M:UpdateLayoutInfo()                       -- the layouts arrive after login
EnterEditMode()
LLS:SetManaged("Bar", true)
Edit("width", 555)
Check("the save button lights", M.hasActiveChanges)
ExitAndSave()
Check("A keeps the width", storage["1:A"] and storage["1:A"].settings.width == 555)
EnterEditMode()
Check("and still has it next session", bar.width == 555 and LLS:IsManaged("Bar"))
Trigger("EditMode.Exit")

print("== leaving without saving ==")
EnterEditMode()
Edit("width", 777)
ExitAndDiscard()
Check("the bar goes back to the saved width", bar.width == 555)
Check("and the stored one never changed", storage["1:A"].settings.width == 555)

print("== Revert All, staying in edit mode ==")
EnterEditMode()
Edit("width", 888)
ClickRevertAll()
Check("the bar goes back", bar.width == 555)
Check("nothing left to revert", not LLS:HasChanges("Bar"))
Check("still in edit mode on A", LLS:IsManaged("Bar"))

print("== reverting this frame alone ==")
Edit("color", "green")
Check("there is something to revert", LLS:HasChanges("Bar"))
LLS:RevertFrame("Bar")
Check("the colour goes back", bar.color == "blue")
Check("and there is nothing left", not LLS:HasChanges("Bar"))

print("== ticking is not a change, and no revert undoes it ==")
M.hasActiveChanges = false
LLS:SetManaged("Bar", false)
Check("unticked hands the bar back", bar.width == 300 and not LLS:IsManaged("Bar"))
Check("without lighting the save button", not M.hasActiveChanges)
Check("and is kept at once, parked", storage["1:A"].inactive and storage["1:A"].settings.width == 555)
ClickRevertAll()
Check("Revert All leaves it unticked", not LLS:IsManaged("Bar") and bar.width == 300)
Trigger("EditMode.Exit")
EnterEditMode()                            -- a session that finds A parked
LLS:SetManaged("Bar", true)
Check("ticking again brings the look back", bar.width == 555 and not storage["1:A"].inactive)
Check("still without lighting the save button", not M.hasActiveChanges)
Edit("width", 560)
ClickRevertAll()
Check("Revert All returns to the look the tick brought", bar.width == 555 and LLS:IsManaged("Bar"))
Edit("width", 560)
LLS:SetManaged("Bar", false)
Check("unticking over an edit keeps it a change", M.hasActiveChanges and LLS:HasChanges("Bar"))
ClickRevertAll()
LLS:SetManaged("Bar", true)
Check("which reverting drops", bar.width == 555)
Trigger("EditMode.Exit")

print("== ticking a layout that owned nothing, then discarding ==")
Switch(3)                                  -- B
Check("B shows the bar's own settings", bar.width == 300)
EnterEditMode()
LLS:SetManaged("Bar", true)
Check("B owns the bar at once", storage["1:B"] and not storage["1:B"].inactive)
Check("with nothing for the frame's own revert button to undo", not LLS:HasChanges("Bar"))
Edit("width", 999)
ExitAndDiscard()
Check("the edit is gone", bar.width == 300)
Check("but the tick stays", LLS:IsManaged("Bar") and storage["1:B"].settings.width == 300)
LLS:SetManaged("Bar", false)               -- from the settings menu
-- The real test of "handed back": no override is left behind, so a later change
-- to the user's own settings shows through.
Check("unticked, no override is left pinned", next(over) == nil)
own.width = 350
Check("so a later change of the user's own shows", bar.width == 350)
own.width = 300

print("== a preset is read only outside edit mode ==")
Switch(1)                                  -- Modern
Check("nothing can be given to it", not LLS:CanManage())
Check("and the addon can tell why", LLS:IsPresetActive())
LLS:SetManaged("Bar", true)                -- from the settings menu
Check("so ticking is refused", storage["0:Modern"] == nil and not LLS:IsManaged("Bar"))

print("== on a preset, a tick alone is not a change ==")
EnterEditMode()
Check("in edit mode it can be ticked", LLS:CanManage())
M.hasActiveChanges = false
LLS:SetManaged("Bar", true)
Check("ticking does not light the save button", not M.hasActiveChanges)
Check("nor writes the preset", storage["0:Modern"] == nil)
Edit("width", 432)
Check("an edit does", M.hasActiveChanges)
ClickRevertAll()
Check("Revert All drops the edit", bar.width == 300)
Check("and keeps the tick", LLS:IsManaged("Bar"))
ExitAndDiscard()
Check("leaving drops the tick with the session", not LLS:IsManaged("Bar") and storage["0:Modern"] == nil)
Check("and pins no override", next(over) == nil)

print("== saving under a preset makes a new layout ==")
EnterEditMode()
LLS:SetManaged("Bar", true)
Edit("width", 444)
-- Blizzard saves for a rename or deletion elsewhere as well, and leaves the edits
-- made on a preset unsaved when it does.
M:SaveLayouts()
Check("such a save writes nothing to the preset", storage["0:Modern"] == nil)
Check("and the edit stays pending", LLS:HasChanges("Bar"))
-- Look inside the sequence: Blizzard saves between reverting and creating, and
-- the preset's entry must not take the edits even for that moment.
local midway
local realSave = M.SaveLayouts
M.SaveLayouts = function(self)
  realSave(self)
  midway = storage["0:Modern"]
end
M:MakeNewLayout({}, 1, "Layout 2", false)  -- what Save does on a preset
M.SaveLayouts = realSave
Check("the preset is never written, not even mid-sequence", midway == nil)
NextFrame()
Check("the new layout owns the edit", storage["1:Layout 2"] and storage["1:Layout 2"].settings.width == 444)
Check("the preset owns nothing", storage["0:Modern"] == nil)
Check("the bar wears the new layout's look", bar.width == 444)
Check("and the session moved with it", LLS:IsManaged("Bar"))
Trigger("EditMode.Exit")

print("== a layout inserted in the middle shifts nothing it should not ==")
Switch(2)                                  -- still A, at index 2
Check("A is still A after the insert", bar.width == 555)

print("== an imported layout starts out owning nothing ==")
EnterEditMode()
Edit("width", 333)
M:MakeNewLayout({}, 1, "Imported", true)
NextFrame()
Check("the import owns nothing", storage["1:Imported"] == nil)
Check("and the bar shows its own settings there", bar.width == 300)
Check("A went back to what it had", storage["1:A"].settings.width == 555)
Trigger("EditMode.Exit")

print("== renaming ==")
Switch(2)                                  -- A
local before = keys()
M:RenameLayout(2, "A2")
NextFrame()
Check("the entry moved to the new name", storage["1:A2"] and storage["1:A2"].settings.width == 555)
Check("nothing left under the old one", storage["1:A"] == nil)
Check("and the bar did not change", bar.width == 555)

print("== renaming the active layout mid session ==")
EnterEditMode()
Edit("width", 610)
M:RenameLayout(2, "A3")                    -- Blizzard's rename saves on the way
Check("the pending edit went with it", storage["1:A3"] and storage["1:A3"].settings.width == 610)
Check("no orphan under A2", storage["1:A2"] == nil)
Edit("width", 620)
ExitAndSave()
Check("and later saves land on the new name", storage["1:A3"].settings.width == 620)

print("== deleting, with indices shifting underneath ==")
Switch(3)                                  -- Layout 2 now sits at index 3
NextFrame()
local survivor = storage["1:Layout 2"].settings.width
for i, l in ipairs(M.layoutInfo.layouts) do
  if l.layoutName == "Imported" then M:DeleteLayout(i) break end
end
NextFrame()
Check("the other entries are untouched", storage["1:Layout 2"].settings.width == survivor
  and storage["1:A3"].settings.width == 620)
for i, l in ipairs(M.layoutInfo.layouts) do
  if l.layoutName == "Layout 2" then M:DeleteLayout(i) break end
end
NextFrame()
Check("a deleted layout's entry is gone", storage["1:Layout 2"] == nil)
Check("and A3 survives it", storage["1:A3"].settings.width == 620)

print("== the parked look ==")
for i, l in ipairs(M.layoutInfo.layouts) do if l.layoutName == "A3" then Switch(i) break end end
Check("on A3", bar.width == 620)
LLS:SetManaged("Bar", false)               -- out of edit mode, from the settings menu
Check("parked, not dropped", storage["1:A3"] and storage["1:A3"].inactive)
Check("the bar wears its own settings", bar.width == 300)
LLS:SetManaged("Bar", true)
Check("ticking again brings the look back", bar.width == 620 and not storage["1:A3"].inactive)

print("== switching layouts ==")
for i, l in ipairs(M.layoutInfo.layouts) do if l.layoutName == "B" then Switch(i) break end end
Check("a layout owning nothing shows the own settings", bar.width == 300)
for i, l in ipairs(M.layoutInfo.layouts) do if l.layoutName == "A3" then Switch(i) break end end
Check("and back again shows the layout's", bar.width == 620)

print("== character layouts carry the character ==")
for i, l in ipairs(M.layoutInfo.layouts) do if l.layoutName == "Mine" then Switch(i) break end end
LLS:SetManaged("Bar", true)
Check("keyed with name and realm", storage["2:Tester - Realm:Mine"] ~= nil)

print("")
print(string.format("%d checks, %s", count,
  failures == 0 and "ALL PASSED" or (failures .. " FAILED")))

os.exit(failures == 0 and 0 or 1)
