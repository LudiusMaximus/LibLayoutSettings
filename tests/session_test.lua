-- The edit mode session against Blizzard's real call sequences: saving,
-- cancelling, Revert All, reverting one frame, giving the frame to a layout and
-- taking it away as changes like any other, editing the addon's own settings
-- while no layout owns the frame, presets being read only, saving only those on a
-- preset without a new layout, a new layout made by saving on a preset,
-- importing, renaming, deleting, the parked look, switching layouts, the panel
-- checkbox only showing and hiding the frame, and the dialog's layout specific
-- row.
--
-- The edit mode manager below copies the order in which Blizzard_EditMode calls
-- things, because the library's correctness depends on that order: MakeNewLayout
-- reverts before it creates, inserts in the middle of the list and saves on the
-- way, and RevertAllChanges refreshes the layouts synchronously.

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(here .. "/stubs.lua")
local Stub, Trigger, RunTimers, slot = STUB.Stub, STUB.Trigger, STUB.RunTimers, STUB.slot

--------------------------------------------------------------------------------
-- Edit mode manager, modelled on Blizzard_EditMode/Shared/EditModeManager.lua
--------------------------------------------------------------------------------

-- One of Blizzard's own systems, whose unsaved change the test switches on.
local systemChanged = false

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
  registeredSystemFrames = { { HasActiveChanges = function() return systemChanged end } },
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
function M:CheckForSystemActiveChanges()
  local changed = false
  for _, systemFrame in ipairs(self.registeredSystemFrames) do
    if systemFrame:HasActiveChanges() then changed = true end
  end
  self:SetHasActiveChanges(changed)
end
local clearedSystems = 0
function M:ClearSelectedSystem() clearedSystems = clearedSystems + 1 end
-- Blizzard's settings dialog, attached to a system while one is selected.
EditModeSystemSettingsDialog = {}
function M:SelectSystem() end
-- Applies the saved layouts, which clears every unsaved change.
function M:UpdateLayoutInfo() self:SetHasActiveChanges(false) end

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

-- Save, and the dialog Blizzard shows on leaving with unsaved changes, whose Exit
-- button is counted rather than leaving.
M.SaveChangesButton = Stub()
local proceeded = 0
EditModeUnsavedChangesDialog = Stub()
EditModeUnsavedChangesDialog.SaveAndProceedButton = Stub()
EditModeUnsavedChangesDialog.ProceedButton = Stub()
function EditModeUnsavedChangesDialog.ProceedButton:Click() proceeded = proceeded + 1 end

local function EnterEditMode() Trigger("EditMode.Enter") end
local function ClickRevertAll()
  M.RevertAllChangesButton:GetScript("OnClick")(M.RevertAllChangesButton)
  NextFrame()
end
local function ExitAndSave() M:SaveLayouts(); Trigger("EditMode.Exit") end
local function ExitAndDiscard() M:RevertAllChanges(); Trigger("EditMode.Exit") end
local function Switch(i) M:SelectLayout(i); NextFrame() end
local function SwitchTo(name)
  for i, l in ipairs(M.layoutInfo.layouts) do
    if l.layoutName == name then Switch(i) return end
  end
end

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
-- What the user's own settings menu does with a change while no layout owns the
-- bar, which is how the library hands them over on Save.
local function EditOwn(key, value) own[key] = value; over[key] = nil end

local storage = {}
local barFrame = Stub()
function barFrame:IsMouseEnabled() return true end
function barFrame:EnableMouse() end
function barFrame:GetFrameStrata() return "MEDIUM" end

local previewing = false

LLS:RegisterFrame("Bar", {
  GetFrame = function() return barFrame end,
  displayName = "Bar",
  storage = storage,
  settings = {
    { type = "layoutSpecific", name = "Layout Specific" },
    { key = "width", name = "Width", type = "slider", minValue = 40, maxValue = 1000 },
    { key = "color", name = "Color", type = "dropdown", options = {} },
    { type = "revert" },
  },
  RestoreOwnSettings = ResetBar,
  GetSetting = function(key) return bar[key] end,
  SetSetting = function(key, value) bar[key] = value end,
  EditSetting = EditOwn,
  GetPosition = function() return bar.p, bar.rp, bar.x, bar.y end,
  SetPosition = function(p, rp, x, y) bar.p, bar.rp, bar.x, bar.y = p, rp, x, y end,
  EditPosition = function(p, rp, x, y) EditOwn("p", p); EditOwn("rp", rp); EditOwn("x", x); EditOwn("y", y) end,
  OnPreview = function(shown) previewing = shown end,
})

local info = LLS.registrations.Bar

-- A change exactly as the dialog makes it: onto the bar and into the pending entry.
local function Edit(key, value)
  bar[key] = value
  LLS:Capture("Bar")
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
Check("giving A the bar is a change to save", M.hasActiveChanges and LLS:HasChanges("Bar"))
Check("kept back until Save", storage["1:A"] == nil)
Edit("width", 555)
ExitAndSave()
Check("A keeps the bar and the width", storage["1:A"] and not storage["1:A"].inactive
  and storage["1:A"].settings.width == 555)
Check("and the user's own width is untouched", own.width == 300)
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

print("== giving the bar up is a change too ==")
M.hasActiveChanges = false
LLS:SetManaged("Bar", false)
Check("the bar wears the user's own settings", bar.width == 300 and not LLS:IsManaged("Bar"))
Check("and the save button lights", M.hasActiveChanges)
Check("but A owns it until Save", not storage["1:A"].inactive)
ClickRevertAll()
Check("Revert All gives it back to A", LLS:IsManaged("Bar") and bar.width == 555)
Check("with nothing left to save", not M.hasActiveChanges)
Edit("width", 560)
LLS:SetManaged("Bar", false)
Check("an edit made before giving it up is still a change", LLS:HasChanges("Bar"))
ExitAndSave()
Check("saved, A keeps its look parked, the edit included", storage["1:A"].inactive
  and storage["1:A"].settings.width == 560)
Check("and the bar wears the user's own settings", bar.width == 300 and next(over) == nil)
EnterEditMode()                            -- a session that finds A parked
LLS:SetManaged("Bar", true)
Check("taking it back brings the parked look back", bar.width == 560)
ExitAndDiscard()
Check("which leaving without saving undoes", not LLS:IsManaged("Bar") and bar.width == 300
  and storage["1:A"].inactive and next(over) == nil)
EnterEditMode()
LLS:SetManaged("Bar", true)
Edit("width", 555)
ExitAndSave()
Check("saved, A owns the bar again", not storage["1:A"].inactive and bar.width == 555)

print("== giving a layout that owned nothing the bar, then discarding ==")
Switch(3)                                  -- B
Check("B shows the bar's own settings", bar.width == 300)
EnterEditMode()
LLS:SetManaged("Bar", true)
Check("B owns the bar for the session", LLS:IsManaged("Bar") and storage["1:B"] == nil)
Check("which its revert button can undo", LLS:HasChanges("Bar"))
Edit("width", 999)
ExitAndDiscard()
Check("the edit and the tick are both gone", bar.width == 300 and storage["1:B"] == nil
  and not LLS:IsManaged("Bar"))
Check("with no override left pinned", next(over) == nil)
LLS:SetManaged("Bar", true)                -- from the settings menu
Check("from the settings menu it takes effect at once", storage["1:B"] and not storage["1:B"].inactive)
LLS:SetManaged("Bar", false)
-- The real test of "handed back": no override is left behind, so a later change
-- to the user's own settings shows through.
Check("unticked, no override is left pinned", next(over) == nil)
own.width = 350
Check("so a later change of the user's own shows", bar.width == 350)
own.width = 300

print("== while no layout owns the bar, edit mode edits the user's own settings ==")
EnterEditMode()                            -- on B, which has its look parked
LLS:SelectFrame("Bar")
Check("the bar can be selected", LLS.selected == info)
Edit("width", 420)
Check("it shows the change", bar.width == 420)
Check("held back until Save", own.width == 300 and M.hasActiveChanges and LLS:HasChanges("Bar"))
Check("and B is given nothing", storage["1:B"].inactive)
ExitAndDiscard()
Check("leaving without saving drops it", bar.width == 300 and own.width == 300 and next(over) == nil)
EnterEditMode()
Edit("width", 420)
Edit("x", 15)
LLS:RevertFrame("Bar")
Check("reverting the frame drops it too", bar.width == 300 and bar.x == 0 and not LLS:HasChanges("Bar"))
Edit("width", 420)
Edit("x", 15)
ExitAndSave()
Check("Save hands it to the user's own settings", own.width == 420 and own.x == 15)
Check("with no override left pinned", next(over) == nil)
Check("and nothing stored for B", storage["1:B"].inactive and storage["1:B"].settings.width == 300)
own.width, own.x = 300, 0

print("== a preset is read only outside edit mode ==")
Switch(1)                                  -- Modern
Check("nothing can be given to it", not LLS:CanManage())
Check("and the addon can tell why", LLS:IsPresetActive())
LLS:SetManaged("Bar", true)                -- from the settings menu
Check("so ticking is refused", storage["0:Modern"] == nil and not LLS:IsManaged("Bar"))

print("== on a preset, giving it the bar takes a new layout ==")
EnterEditMode()
Check("in edit mode it can be ticked", LLS:CanManage())
LLS:SetManaged("Bar", true)
Check("as a change to save", M.hasActiveChanges and LLS:IsManaged("Bar"))
Check("which writes nothing to the preset", storage["0:Modern"] == nil)
Edit("width", 432)
ClickRevertAll()
Check("Revert All drops the edit and the tick", bar.width == 300 and not LLS:IsManaged("Bar"))
ExitAndDiscard()
Check("and leaving leaves nothing behind", storage["0:Modern"] == nil and next(over) == nil)

print("== on a preset, the user's own settings alone are saved without a new layout ==")
EnterEditMode()
local saveCover, saveExitCover = LLS.saveCover, LLS.saveExitCover
Check("Save is not covered while there is nothing to save", saveCover and not saveCover:IsShown())
Edit("width", 404)
Check("it is once the user's own settings are all that changed",
  saveCover:IsShown() and saveExitCover:IsShown())
systemChanged = true
M:CheckForSystemActiveChanges()
Check("but not while one of Blizzard's systems has a change too", not saveCover:IsShown())
systemChanged = false
M:CheckForSystemActiveChanges()
Check("and is again once that is gone", saveCover:IsShown())
LLS:SetManaged("Bar", true)
Check("nor while the preset is being given the bar", not saveCover:IsShown())
LLS:SetManaged("Bar", false)
Check("taking it away again at once is as if it never happened",
  bar.width == 404 and saveCover:IsShown() and storage["0:Modern"] == nil)
local layoutCount = #M.layoutInfo.layouts
saveCover:GetScript("OnClick")()
Check("pressing Save hands them to the user's own settings", own.width == 404 and next(over) == nil)
Check("without making a layout", #M.layoutInfo.layouts == layoutCount and storage["0:Modern"] == nil)
Check("and leaves nothing to save", not M.hasActiveChanges and not saveCover:IsShown())
Edit("width", 405)
EditModeUnsavedChangesDialog:Show()
saveExitCover:GetScript("OnClick")()
Check("Save and Exit saves them too", own.width == 405)
Check("then presses Exit", proceeded == 1)
Edit("width", 406)
STUB.inCombat = true
saveExitCover:GetScript("OnClick")()
STUB.inCombat = false
Check("in combat it saves", own.width == 406)
Check("and leaves the dialog for the player to leave", proceeded == 1)
ExitAndDiscard()
Check("leaving takes the covers away", not saveCover:IsShown() and not saveExitCover:IsShown())
own.width = 300

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
SwitchTo("A3")
Check("on A3", bar.width == 620)
LLS:SetManaged("Bar", false)               -- out of edit mode, from the settings menu
Check("parked, not dropped", storage["1:A3"] and storage["1:A3"].inactive)
Check("the bar wears its own settings", bar.width == 300)
LLS:SetManaged("Bar", true)
Check("ticking again brings the look back", bar.width == 620 and not storage["1:A3"].inactive)

print("== switching layouts ==")
SwitchTo("B")
Check("a layout owning nothing shows the own settings", bar.width == 300)
SwitchTo("A3")
Check("and back again shows the layout's", bar.width == 620)

print("== the same layout applied again mid session ==")
EnterEditMode()
Edit("width", 630)
Check("an edit lights Save", M.hasActiveChanges)
M:UpdateLayoutInfo()                       -- a spec change, say
NextFrame()
Check("drops the edits waiting for Save, as Blizzard drops its own",
  bar.width == 620 and not LLS:HasChanges("Bar") and not M.hasActiveChanges)
Trigger("EditMode.Exit")

print("== the panel checkbox only shows and hides the bar ==")
EnterEditMode()
Check("shown in edit mode to begin with", LLS:IsShownInEditMode("Bar") and previewing)
M.hasActiveChanges = false
LLS:SetShownInEditMode("Bar", false)
Check("hiding it takes its preview away", not previewing)
Check("is no change to save", not M.hasActiveChanges)
Check("and leaves A3 owning it", LLS:IsManaged("Bar") and bar.width == 620)
LLS:SelectFrame("Bar")
Check("a hidden bar cannot be selected", LLS.selected == nil)
LLS:SetShownInEditMode("Bar", true)
LLS:SelectFrame("Bar")
Check("shown again, it can", LLS.selected == info and previewing)
LLS:SetShownInEditMode("Bar", false)
Check("and hiding it puts its dialog away", LLS.selected == nil)
LLS:SetShownInEditMode("Bar", true)
Trigger("EditMode.Exit")

print("== the dialog's layout specific row ==")
EnterEditMode()
LLS:SelectFrame("Bar")
Check("is ticked while A3 owns the bar", LLS.dialog.rows.layoutSpecific[1].checked)
LLS.dialog.rows.layoutSpecific[1]:OnCheckButtonClick()
Check("unticking hands the bar back", not LLS:IsManaged("Bar") and bar.width == 300)
Check("with the dialog staying open on it", LLS.selected == info)
Check("and the redrawn row shows it", LLS.dialog.rows.layoutSpecific[1].checked == false)
LLS.dialog.rows.layoutSpecific[1]:OnCheckButtonClick()
Check("ticking again brings A3's look back", LLS:IsManaged("Bar") and bar.width == 620)
Check("with nothing left to save", not M.hasActiveChanges and not LLS:HasChanges("Bar"))
ExitAndDiscard()

print("== the dialog's arrow keys ==")
EnterEditMode()
LLS:SelectFrame("Bar")
local dialog = LLS.dialog
local y = bar.y
dialog:GetScript("OnKeyDown")(dialog, "UP")
Check("an arrow key nudges the bar", bar.y == y + 1)
Check("and is not passed on", slot(dialog).propagate == false)
dialog:GetScript("OnKeyUp")(dialog, "UP")
Check("until it is let go", slot(dialog).propagate == true)
dialog:GetScript("OnKeyDown")(dialog, "A")
Check("any other key is passed on", slot(dialog).propagate == true)
STUB.inCombat = true
local ok = pcall(dialog:GetScript("OnKeyDown"), dialog, "UP")
Check("in combat a key is left alone, without an error", ok and bar.y == y + 1)
ok = pcall(dialog:GetScript("OnKeyUp"), dialog, "UP")
Check("letting go of it too", ok and slot(dialog).propagate == true)
STUB.inCombat = false
ExitAndDiscard()

print("== selecting the bar in combat ==")
EnterEditMode()
clearedSystems = 0
LLS:SelectFrame("Bar")
Check("out of combat Blizzard is asked to put its selection away", clearedSystems == 1 and LLS.selected == info)
LLS:ClearSelection()
STUB.inCombat = true
clearedSystems = 0
LLS:SelectFrame("Bar")
Check("in combat it is not asked, which would touch protected frames",
  clearedSystems == 0 and LLS.selected == info)
LLS:ClearSelection()
EditModeSystemSettingsDialog.attachedToSystem = {}
LLS:SelectFrame("Bar")
Check("and while one of Blizzard's systems is selected, the bar is not", LLS.selected == nil)
EditModeSystemSettingsDialog.attachedToSystem = nil
STUB.inCombat = false
ExitAndDiscard()

print("== a layout given the bar takes the edits made for it ==")
SwitchTo("Mine")
EnterEditMode()
Edit("width", 333)
LLS:SetManaged("Bar", true)
Check("the bar keeps what it was wearing", bar.width == 333 and LLS:IsManaged("Bar"))
Edit("width", 334)
LLS:SetManaged("Bar", false)
Check("changed since, taking it away parks Mine's look", bar.width == 300 and LLS:HasChanges("Bar"))
LLS:SetManaged("Bar", true)
Check("which giving it back brings back", bar.width == 334)
ExitAndSave()
Check("Mine has it, keyed with name and realm", storage["2:Tester - Realm:Mine"]
  and storage["2:Tester - Realm:Mine"].settings.width == 334)
Check("and the user's own settings do not", own.width == 300)

print("== a new layout made on a preset hands the user's edits to their settings ==")
SwitchTo("Modern")
EnterEditMode()
Edit("width", 410)
systemChanged = true                       -- so Save has to make a layout
M:CheckForSystemActiveChanges()
M:MakeNewLayout({}, 1, "Layout 3", false)
NextFrame()
systemChanged = false
Check("the user's own settings take the edit", own.width == 410 and bar.width == 410)
Check("and the new layout owns nothing", storage["1:Layout 3"] == nil)
Trigger("EditMode.Exit")
Check("with no override left pinned", next(over) == nil)

print("")
print(string.format("%d checks, %s", count,
  failures == 0 and "ALL PASSED" or (failures .. " FAILED")))

os.exit(failures == 0 and 0 or 1)
