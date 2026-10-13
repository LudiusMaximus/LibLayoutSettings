--[[
LibLayoutSettings

Lets an addon frame take part in Blizzard's HUD edit mode without pretending to be
one of Blizzard's own systems.

Blizzard's layouts are stored client side and every entry in them is typed by the
Enum.EditModeSystem enum, which only knows Blizzard's own systems. A foreign value
cannot survive C_EditMode.SaveLayouts, and EditModeManagerFrame strips unknown
systems out of every saved layout on login anyway. So this library never touches
Blizzard's layout data. It only reads which layout is active and keeps its own per
layout copy of position and settings in the addon's saved variables.

What the library provides:
  - a panel next to the edit mode manager with one checkbox per registered frame,
  - Blizzard's selection glow on the frame while edit mode is active,
  - dragging the frame by that glow, and nudging it with the arrow keys,
  - a settings dialog of slider, checkbox, dropdown, colour, text, button,
    separator, revert, reset position and action rows,
  - copying one layout's stored look onto another,
  - the same rows on a settings page of the addon's own, outside edit mode,
  - save, cancel and revert semantics that match Blizzard's, including creating a
    new layout when saving while a preset layout is active.

  local LLS = LibStub("LibLayoutSettings-1.0")
  LLS:RegisterFrame("MyBar", { frame = myBar, displayName = "My Addon",
    storage = MyAddonDB.editModeLayouts, settings = { ... }, ... })

Ticking a layout's checkbox stores the frame's current position and settings for
that layout, so switching to it later restores them. A layout that does not own
the frame hands it back to the addon's own settings, and unticking keeps the
layout's look parked, so that ticking again brings it back. Like Blizzard's own
checkboxes on that panel, ticking and unticking take effect at once: they are not
a change to save, and no revert undoes them.

README.md is the reference: every registration field, every setting descriptor
field and the public API are described there, and only there, so that the two
cannot drift apart.
]]

local MAJOR, MINOR = "LibLayoutSettings-1.0", 1

assert(LibStub, MAJOR .. " requires LibStub.")

local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Kept across library upgrades.
lib.registrations = lib.registrations or {}
lib.order = lib.order or {}
-- Every frame CreateSettingsFrame has drawn rows into.
lib.pages = lib.pages or {}

local registrations = lib.registrations
local order = lib.order

local floor = math.floor
local max = math.max
local min = math.min
local ceil = math.ceil


-- Every current client ships Blizzard_EditMode, down to Classic Era. On anything
-- that does not, every entry point below turns into a no-op.
local function IsSupported()
  return EditModeManagerFrame ~= nil and EditModeSystemSelectionMixin ~= nil
end


--------------------------------------------------------------------------------
-- Layout identity
--------------------------------------------------------------------------------

local characterTag

-- Layouts are keyed by type and name, never by index. Deleting a layout shifts
-- every index behind it, and an account layout and a character layout can carry
-- the same name. Character layouts also have to carry the character, because two
-- characters may each own one of that name while the storage is account wide.
local function LayoutKey(layout)
  if not layout or not layout.layoutName then
    return nil
  end

  if layout.layoutType == Enum.EditModeLayoutType.Character then
    if not characterTag then
      characterTag = UnitName("player") .. " - " .. GetRealmName()
    end
    return layout.layoutType .. ":" .. characterTag .. ":" .. layout.layoutName
  end

  return layout.layoutType .. ":" .. layout.layoutName
end

local function ActiveLayout()
  if not IsSupported() or not EditModeManagerFrame.GetActiveLayoutInfo then
    return nil
  end
  return EditModeManagerFrame:GetActiveLayoutInfo()
end

-- Override layouts are forced on the player by the content they are in, so they
-- are never a sensible place to store anything.
local function IsWritableLayout(layout)
  return layout ~= nil and layout.layoutType ~= Enum.EditModeLayoutType.Override
end

local function ActiveLayoutKey()
  local layout = ActiveLayout()
  if not IsWritableLayout(layout) then
    return nil
  end
  return LayoutKey(layout)
end

-- Blizzard's preset layouts are read only. Edit mode lets the player change one,
-- but saving it makes a new layout and the preset stays as it was, so a frame may
-- be ticked and edited on a preset during a session and is never stored there.
local function IsPresetLayout(layout)
  return layout ~= nil and layout.layoutType == Enum.EditModeLayoutType.Preset
end

local function IsPresetKey(key)
  return key ~= nil and key:match("^(%d+):") == tostring(Enum.EditModeLayoutType.Preset)
end


--------------------------------------------------------------------------------
-- Reading and writing a registration
--------------------------------------------------------------------------------

-- A setting may be a table, a colour for instance. Those have to be copied on
-- the way in and on the way out, or the layout's entry and the addon's own store
-- end up sharing one table and every layout shows the same value.
local function CopyValue(value)
  if type(value) == "table" then
    return CopyTable(value)
  end
  return value
end

local function SameValue(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not SameValue(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

local function CaptureEntry(info)
  local point, relativePoint, x, y = info.GetPosition()
  local entry = {
    position = { point = point, relativePoint = relativePoint, x = x, y = y },
    settings = {},
  }
  for _, setting in ipairs(info.settings) do
    -- Separators live in the same list but carry no value.
    if setting.key then
      entry.settings[setting.key] = CopyValue(info.GetSetting(setting.key))
    end
  end
  return entry
end

local function ApplyEntry(info, entry)
  if not entry then
    return
  end

  local position = entry.position
  if position and position.point then
    info.SetPosition(position.point, position.relativePoint, position.x, position.y)
  end

  if entry.settings then
    for _, setting in ipairs(info.settings) do
      local value = setting.key and entry.settings[setting.key]
      if value ~= nil then
        info.SetSetting(setting.key, CopyValue(value))
      end
    end
  end

  if info.OnChanged then
    info.OnChanged()
  end
end

-- The entry the user is currently working on. While edit mode is running that is
-- the pending copy, outside of it whatever the active layout has stored.
local function CurrentEntry(info)
  if lib.sessionKey then
    return info.pending
  end
  local key = ActiveLayoutKey()
  return key and info.storage[key] or nil
end

-- A layout keeps a frame's look even while it is not using it, so that unticking
-- the checkbox and ticking it again brings that look back rather than capturing
-- whatever happens to be on screen in between. An entry without the flag is in
-- use, which is what every entry written before this existed is.
local function IsActiveEntry(entry)
  return entry ~= nil and not entry.inactive
end

local function IsManaged(info)
  return IsActiveEntry(CurrentEntry(info))
end

-- Puts a layout's look on the frame, or hands the frame back when that layout has
-- nothing in use for it.
local function ApplyOrRestore(info, entry)
  if IsActiveEntry(entry) then
    ApplyEntry(info, entry)
  elseif info.RestoreOwnSettings then
    info.RestoreOwnSettings()
  end
end

-- Whether this frame's look differs from where the player started editing it.
-- Ticking or unticking the checkbox is not a change (see SetManaged), so it moves
-- the mark along with it rather than counting against it.
--
-- Both sides may be nil, which is a frame no layout owned and still does not.
local function HasChanges(info)
  if not lib.sessionKey then
    return false
  end
  return not SameValue(info.pending, info.revertPoint)
end

-- Where the addon says the frame belongs when nothing has moved it. Optional: a
-- registration without it simply has nothing to reset the position to.
local function DefaultPosition(info)
  if not info.GetDefaultPosition then
    return nil
  end
  local point, relativePoint, x, y = info.GetDefaultPosition()
  if not point then
    return nil
  end
  return point, relativePoint, x or 0, y or 0
end

local function IsInDefaultPosition(info)
  local point, relativePoint, x, y = DefaultPosition(info)
  if not point then
    -- Nothing to compare against, so nothing to put back.
    return true
  end

  local current, currentRelative, currentX, currentY = info.GetPosition()
  return current == point
    and currentRelative == relativePoint
    and floor((currentX or 0) + 0.5) == floor(x + 0.5)
    and floor((currentY or 0) + 0.5) == floor(y + 0.5)
end

-- A settings page measures against how the frame looked when the page was
-- opened, because outside edit mode there is no session to measure against.
local function PageHasChanges(page)
  return page.libSnapshot ~= nil and not SameValue(CaptureEntry(page.libInfo), page.libSnapshot)
end

-- What a revert row on this host has to undo.
local function HostHasChanges(host, info)
  if host.libPage then
    return PageHasChanges(host)
  end
  return HasChanges(info)
end

-- The revert row and the reset position row each enable themselves only while
-- there is something to undo, the way Blizzard's own buttons do. Updated in place
-- rather than by redrawing, because a slider drag would redraw on every frame,
-- and so would holding an arrow key down.
local function RefreshHostButtonStates(host)
  local rows = host and host.rows
  if not rows then
    return
  end

  local pool = rows.revert
  for index = 1, (pool and pool.used or 0) do
    local row = pool[index]
    if row.libInfo then
      row:SetEnabled(HostHasChanges(host, row.libInfo))
    end
  end

  pool = rows.resetPosition
  for index = 1, (pool and pool.used or 0) do
    local row = pool[index]
    if row.libInfo then
      row:SetEnabled(not IsInDefaultPosition(row.libInfo))
    end
  end
end

local function RefreshButtonStates()
  RefreshHostButtonStates(lib.dialog)
  for _, page in ipairs(lib.pages) do
    RefreshHostButtonStates(page)
  end
end


--------------------------------------------------------------------------------
-- Edit mode session
--------------------------------------------------------------------------------
-- Blizzard reverts everything on exit unless the player pressed Save, so edits go
-- into a pending copy first. baseline is what the layout held when the session
-- started, live is how the frame looked, which is what a cancel has to restore.
-- A tick or untick is not an edit, so it moves both along with it (see SetManaged).

-- Set between Blizzard's revert and the frame after it. See ScheduleRevert.
local revertScheduled = false
local revertSnapshot
local ConsumeRevert

local function BeginSession(key)
  lib.sessionKey = key
  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    local stored = key and info.storage[key] or nil
    info.baseline = stored and CopyTable(stored) or nil
    info.pending = stored and CopyTable(stored) or nil
    info.revertPoint = stored and CopyTable(stored) or nil
    info.live = CaptureEntry(info)
  end
  RefreshButtonStates()
end

local function EndSession()
  lib.sessionKey = nil
  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    info.baseline, info.pending, info.revertPoint, info.live = nil, nil, nil, nil
  end
end

local function CommitSession()
  -- A scheduled revert means Blizzard is in the middle of creating a layout from
  -- the one that is active, and it saves on the way. Where these edits belong is
  -- for the MakeNewLayout hook to decide, not for the layout being left behind.
  if revertScheduled then
    return
  end

  -- Blizzard also saves for a rename or a deletion while a preset is active, and
  -- leaves the edits made on the preset unsaved. These stay pending alongside them.
  local key = lib.sessionKey
  if not key or IsPresetKey(key) then
    return
  end
  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    info.storage[key] = info.pending and CopyTable(info.pending) or nil
    info.baseline = info.pending and CopyTable(info.pending) or nil
    info.revertPoint = info.pending and CopyTable(info.pending) or nil
    info.live = CaptureEntry(info)
  end
  lib.dirty = false
  RefreshButtonStates()
end

-- Blizzard's save button only lights up for its own systems, so it has to be told
-- that there is something to save here as well.
local function MarkDirty()
  lib.dirty = true
  if lib.sessionKey and IsSupported() then
    EditModeManagerFrame:SetHasActiveChanges(true)
  end
  RefreshButtonStates()
end

-- Every way the frame can be moved ends here: dragging it, nudging it with an
-- arrow key, and putting it back to where the addon says it belongs.
local function CommitPosition(info, point, relativePoint, x, y)
  info.SetPosition(point, relativePoint, x, y)

  local entry = CurrentEntry(info)
  if entry then
    entry.position = { point = point, relativePoint = relativePoint, x = x, y = y }
  end

  MarkDirty()
end


--------------------------------------------------------------------------------
-- Panel and dialog, built lazily on the first edit mode entry
--------------------------------------------------------------------------------

local RefreshPanel, RefreshOverlays, RefreshDialog, RefreshLayoutIndex, RefreshPages, RefreshHost

-- One row per registered frame, as tall as Blizzard's own manager checkboxes and
-- as wide as the longest name needs, so the panel hugs its contents.
local panelRowHeight = 32
local panelListInset = 22
local panelHeaderHeight = 44
local panelFooterHeight = 16
-- The checkbox and the gap before its label, as EditModeCheckButtonTemplate has them.
local panelCheckWidth = 32 + 5
-- Room right of the longest name, and more once the scroll bar needs it.
local panelRightInset = 20
local panelScrollBarRoom = 33
-- However many addons register, the panel stops growing here and scrolls the
-- rest. Ten rows leaves it shorter than the manager it hangs off, so it cannot
-- reach past the bottom of the screen on any resolution edit mode is usable at.
local panelMaxRows = 10

local function BuildPanel()
  if lib.panel then
    return lib.panel
  end

  -- No sizes are set here. They belong to RefreshPanel, which runs before the
  -- panel is ever shown and sizes it to the rows it is holding.
  local panel = CreateFrame("Frame", nil, UIParent)
  panel:SetFrameStrata("DIALOG")
  panel:SetPoint("TOPLEFT", EditModeManagerFrame, "TOPRIGHT", 12, 0)
  panel:SetClampedToScreen(true)
  panel:EnableMouse(true)
  panel:Hide()

  panel.Border = CreateFrame("Frame", nil, panel, "DialogBorderTranslucentTemplate")

  panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
  panel.Title:SetPoint("TOP", 0, -16)
  panel.Title:SetText(ADDONS or "AddOns")

  -- Built the way the edit mode manager builds its own settings list, so that a
  -- long list scrolls rather than running off the bottom of the screen. The bar
  -- sits outside the rows and only appears when there is something to scroll.
  local list = CreateFrame("ScrollFrame", nil, panel, "ScrollFrameTemplate")
  list:SetPoint("TOPLEFT", panel, "TOPLEFT", panelListInset, -panelHeaderHeight)
  if list.ScrollBar then
    list.ScrollBar:SetHideIfUnscrollable(true)
  end

  list.ScrollChild = CreateFrame("Frame", nil, list)
  list:SetScrollChild(list.ScrollChild)

  panel.List = list
  panel.rows = {}

  lib.panel = panel
  return panel
end

-- The frame may not exist yet when the addon registers, so it can be handed over
-- by a getter that creates it on demand.
local function ResolveFrame(info)
  if info.frame then
    return info.frame
  end
  if info.GetFrame then
    return info.GetFrame()
  end
  return nil
end

local strataBelow = {
  TOOLTIP = "FULLSCREEN_DIALOG",
  FULLSCREEN_DIALOG = "FULLSCREEN",
  FULLSCREEN = "DIALOG",
  DIALOG = "HIGH",
  HIGH = "MEDIUM",
  MEDIUM = "LOW",
  LOW = "BACKGROUND",
  BACKGROUND = "BACKGROUND",
}

local function BuildOverlay(info)
  if info.overlay then
    return info.overlay
  end

  local frame = ResolveFrame(info)
  if not frame then
    return nil
  end

  local overlay = CreateFrame("Frame", nil, frame, "EditModeSystemSelectionTemplate")

  local insets = info.selectionInsets or {}
  overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", -(insets.left or 6), (insets.top or 6))
  overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", (insets.right or 6), -(insets.bottom or 6))

  -- The selection frame asks its system for a name for the label and the tooltip.
  overlay:SetSystem({ GetSystemName = function() return info.displayName end })

  overlay.libStrata = overlay:GetFrameStrata()
  overlay.libLevel = overlay:GetFrameLevel()
  overlay.libToplevel = overlay:IsToplevel()

  -- Blizzard writes the system name across the middle of the frame while it is
  -- selected, which does not suit a frame that carries text of its own. The name
  -- is still on the mouseover tooltip and on the settings dialog.
  if info.showSelectionLabel == false then
    overlay.UpdateLabelVisibility = function(selection)
      if selection.Label then selection.Label:Hide() end
      if selection.HorizontalLabel then selection.HorizontalLabel:Hide() end
      if selection.VerticalLabel then selection.VerticalLabel:Hide() end
    end
  end

  -- Blizzard's scripts route into the edit mode manager's system registry, which
  -- this frame is deliberately not part of.
  overlay:SetScript("OnMouseDown", function()
    lib:SelectFrame(info.key)
  end)

  overlay:SetScript("OnDragStart", function()
    if not IsManaged(info) then
      return
    end
    frame:SetMovable(true)
    frame:StartMoving()
    info.dragging = true
  end)

  overlay:SetScript("OnDragStop", function()
    if not info.dragging then
      return
    end
    info.dragging = nil
    frame:StopMovingOrSizing()

    local point, _, relativePoint, x, y = frame:GetPoint(1)
    CommitPosition(info, point, relativePoint, floor(x + 0.5), floor(y + 0.5))
  end)

  overlay:Hide()

  info.overlay = overlay
  return overlay
end


-- Blizzard's glow is drawn over its system, which suits a frame with nothing to
-- read on it. A frame that carries text wants the glow behind while it is being
-- edited, so that the centre fill is not over what the frame is showing. Only
-- while selected though: highlighted is how a frame says it can be edited, and
-- that reads better on top.
local function SetOverlayBehind(info, overlay, behind)
  local frame = ResolveFrame(info)

  if behind then
    overlay:SetFrameStrata(type(info.selectionBehind) == "string" and info.selectionBehind
      or (frame and strataBelow[frame:GetFrameStrata()]) or "BACKGROUND")
    overlay:SetToplevel(false)

    -- The frame is in front of the glow now and would swallow the clicks meant
    -- for it, so its mouse goes off until it is deselected. That also takes the
    -- addon's own click handling out of the way, which is what editing wants.
    if frame and info.mouseWasEnabled == nil then
      info.mouseWasEnabled = frame:IsMouseEnabled()
      frame:EnableMouse(false)
    end
    return
  end

  if overlay.libStrata then
    overlay:SetFrameStrata(overlay.libStrata)
    overlay:SetFrameLevel(overlay.libLevel)
    overlay:SetToplevel(overlay.libToplevel)
  end

  if info.mouseWasEnabled ~= nil then
    if frame then
      frame:EnableMouse(info.mouseWasEnabled)
    end
    info.mouseWasEnabled = nil
  end
end

-- Outside edit mode there is no session to hold a change, so it goes through the
-- addon the way a change from its own settings UI does, and lands wherever those
-- land. Capture then folds it into a layout that owns the frame. The page the
-- change came from is marked while it runs, so that it is not redrawn under the
-- control being used.
local function EditThroughAddon(info, edit, page)
  if page then
    page.libWriting = true
  end
  edit()
  if info.OnChanged then
    info.OnChanged()
  end
  lib:Capture(info.key)
  if page then
    page.libWriting = false
  end
  RefreshButtonStates()
end

-- The same look, put on through the addon rather than as a layout's override.
local function EditEntry(info, entry)
  local position = entry.position
  if position and position.point then
    info.EditPosition(position.point, position.relativePoint, position.x, position.y)
  end
  if entry.settings then
    for _, setting in ipairs(info.settings) do
      local value = setting.key and entry.settings[setting.key]
      if value ~= nil then
        info.EditSetting(setting.key, CopyValue(value))
      end
    end
  end
end

-- Puts the look back to how it was when the page was opened. Capture redraws the
-- page on the way, so its rows show the result.
local function RevertPage(page)
  EditThroughAddon(page.libInfo, function() EditEntry(page.libInfo, page.libSnapshot) end)
end

local function SetRowValue(host, info, setting, value)
  if host.libPage then
    EditThroughAddon(info, function() info.EditSetting(setting.key, value) end, host)
  else
    info.SetSetting(setting.key, value)

    local entry = CurrentEntry(info)
    if entry then
      -- Copied, or the addon's store and the layout's entry would share one table
      -- and an in place edit on either side would silently change the other.
      entry.settings[setting.key] = CopyValue(value)
    end

    if info.OnChanged then
      info.OnChanged()
    end

    MarkDirty()
  end

  -- Redraws so that any row this one greys out follows immediately. Never set on
  -- a slider, whose value changes on every frame of a drag.
  if setting.refreshOnChange then
    RefreshHost(host)
  end
end


-- Blizzard's edit mode only knows three kinds of row: Enum.EditModeSettingDisplayType
-- is Dropdown, Checkbox and Slider. A colour row has to be built by hand, out of
-- the same pieces Blizzard's own colour swatches use.
local rowTemplates = {
  slider = "EditModeSettingSliderTemplate",
  checkbox = "EditModeSettingCheckboxTemplate",
  dropdown = "EditModeSettingDropdownTemplate",
  -- An action row is a dropdown that does something rather than holding a value,
  -- so it is the same row wearing a different job.
  actions = "EditModeSettingDropdownTemplate",
}

local rowKinds = {
  slider = true,
  checkbox = true,
  dropdown = true,
  color = true,
  text = true,
  separator = true,
  button = true,
  revert = true,
  resetPosition = true,
  actions = true,
}

-- The three that are plain buttons, differing only in what the library puts on
-- them and when it enables them.
local rowIsButton = { button = true, revert = true, resetPosition = true }

-- The control a row of each kind carries, for the wiring that has to reach past
-- the row to the thing sitting on it. Named per kind rather than picked as the
-- first field that happens to exist, so that a row growing a second control
-- later cannot quietly change which one is meant. A button row is its own
-- control and so is absent here.
local rowControl = {
  slider = "Slider",
  checkbox = "Button",
  dropdown = "Dropdown",
  actions = "Dropdown",
  color = "Swatch",
  text = "EditBox",
}

-- Rows that are not one of Blizzard's setting rows have a height of their own.
local rowHeights = { separator = 22, button = 32, revert = 32, resetPosition = 32 }
-- Buttons are left aligned with the setting labels, the way Blizzard anchors its
-- own to the bottom left of its settings block, whatever their width. Only the
-- divider is centred.
local rowCentred = { separator = true }
-- Two rows sharing a line each take half the width one would have had, so that
-- the left one stops before the right one starts. Not cosmetic: a row is mouse
-- enabled for its tooltip, so a left row left at full width lies over the right
-- row's label and answers for it.
local pairedRowWidth = 167
-- Blizzard sets its buttons block 12 below the settings block, and a revert row
-- is where that block starts. Any row can ask for the same with padTop.
local rowPadTop = { revert = 12 }

-- Where a row starts, by column. A row marked sameRow goes in the second column
-- of the row before it rather than on one of its own.
local labelColumnWidth = 100
local controlGap = 5
local columnOffsets = { 26, 198 }
-- Where a swatch and the label after it sit, matched to the checkbox rows.
local swatchInset = 3
local boxedLabelInset = 32
local boxedLabelWidth = 200
-- Narrow enough that a paired row's label ends before the next column's control.
local pairedLabelWidth = 130


-- Tooltips
--------------------------------------------------------------------------------
-- One tooltip per row, never one per widget. A row is a label and the control
-- that belongs to it, and they describe the same setting, so hovering either has
-- to produce the same tooltip in the same place. The row owns it; the control on
-- the row does nothing but say which row the mouse is on.
--
-- It is placed off the right edge of the dialog, level with the row, so that it
-- never covers the control being judged and never moves while the mouse travels
-- along the row. GameTooltip clamps itself to the screen, so a dialog dragged
-- against the right edge gets a tooltip that slides back into view rather than
-- one that disappears.

local tooltipGap = 8

-- The text is described on the setting and read at hover time, so a row can be
-- wired once when it is created and still say the right thing for whatever
-- setting it is showing later. A string, or a function returning one.
local function RowTooltipText(row)
  local setting = row and row.libSetting
  local tooltip = setting and setting.tooltip
  if type(tooltip) == "function" then
    tooltip = tooltip(setting)
  end
  return tooltip
end

-- The row a hovered frame speaks for: the row itself, or the control on it.
local function RowOf(frame)
  return frame and (frame.libRow or frame) or nil
end

local function ShowRowTooltip(frame)
  local row = RowOf(frame)
  local text = RowTooltipText(row)
  if not text then
    return
  end

  local tooltip = GetAppropriateTooltip()

  -- Already up for this row, because the mouse moved from the label onto the
  -- control or back. Left exactly where it is: re-anchoring it here is what made
  -- it jump about as the mouse crossed the row.
  if tooltip:GetOwner() == row and tooltip:IsShown() then
    return
  end

  -- A row the library labels itself, a reset position row for instance, carries
  -- neither a name nor a text of its own, so the button says what it is.
  local setting = row.libSetting
  local title = setting.name or setting.text
    or (row.GetText and row:GetText()) or ""

  tooltip:SetOwner(row, "ANCHOR_NONE")
  tooltip:ClearAllPoints()
  -- Level with the row, from the offset the row was placed at, rather than from
  -- its rect: a row that has just been shown may not have been laid out yet.
  tooltip:SetPoint("TOPLEFT", row.libHost, "TOPRIGHT", tooltipGap, row.libOffsetY or 0)
  GameTooltip_SetTitle(tooltip, title)
  GameTooltip_AddNormalLine(tooltip, text, true)
  tooltip:Show()
end

-- The menu a dropdown row has open, nil while it has none.
local function OpenMenuOf(row)
  return row.Dropdown and row.Dropdown.menu
end

local function HideRowTooltip(frame)
  local row = RowOf(frame)
  if not row then
    return
  end

  -- Leaving the control for the label it belongs to has not left the row, and
  -- the row's own OnEnter will not fire again for a move that never left it - a
  -- control like ColorSwatchTemplate propagates its mouse input, so the row had
  -- the mouse throughout. Only leaving the row puts the tooltip away, and leaving
  -- the dropdown for the menu it opened has not left it either.
  if row.IsMouseOver and row:IsMouseOver() then
    return
  end
  local menu = OpenMenuOf(row)
  if menu and menu:IsMouseOver() then
    return
  end

  local tooltip = GetAppropriateTooltip()
  if tooltip:GetOwner() == row then
    tooltip:Hide()
  end
end

-- A dropdown's menu opens off the row, and once the mouse is in it the row hears
-- nothing more: its OnLeave has fired, or never will if the menu lies over the
-- row's own rect. So while a row's menu is open, the tooltip is kept in step by
-- watching the mouse: up while it is over the row or the menu, away while it is
-- over neither, and back when it returns.
local menuWatcher = CreateFrame("Frame")
menuWatcher:Hide()

menuWatcher:SetScript("OnUpdate", function(self)
  local row = self.libRow
  local menu = row and OpenMenuOf(row)
  if not menu then
    self.libRow = nil
    self:Hide()
  elseif row:IsMouseOver() or menu:IsMouseOver() then
    ShowRowTooltip(row)
  else
    HideRowTooltip(row)
  end
end)

local function WatchMenuOf(row)
  menuWatcher.libRow = row
  menuWatcher:Show()
end

-- Hovering a child does not reach its parent in this UI, so the control is wired
-- as well as the row, purely to report the row it sits on. Blizzard's own
-- templates already use OnEnter for their highlights, hence the hook rather than
-- a plain set.
local function WireTooltip(row, frame, hooked)
  if not frame then
    return
  end
  frame.libRow = row
  frame:EnableMouse(true)
  if hooked then
    frame:HookScript("OnEnter", ShowRowTooltip)
    frame:HookScript("OnLeave", HideRowTooltip)
  else
    frame:SetScript("OnEnter", ShowRowTooltip)
    frame:SetScript("OnLeave", HideRowTooltip)
  end
end

-- And a control is not always the thing under the mouse either. A slider row's
-- control is MinimalSliderWithSteppersTemplate, whose own children - the slider
-- and the two stepper buttons - are what the pointer actually lands on, and they
-- take the mouse without passing it up. Anything on the row that can be hovered
-- has to report the row, however deep it sits.
--
-- Only frames that already take the mouse are wired, and their mouse state is
-- left exactly as it was: switching it on for a frame built not to take it would
-- put that frame in the way of clicks meant for something else.
local function WireDescendants(row, frame)
  for _, child in ipairs({ frame:GetChildren() }) do
    if child.libRow ~= row and child:IsMouseEnabled() then
      child.libRow = row
      child:HookScript("OnEnter", ShowRowTooltip)
      child:HookScript("OnLeave", HideRowTooltip)
    end
    -- Recursed into whether or not it takes the mouse itself, because a frame
    -- that does may sit under one that does not.
    WireDescendants(row, child)
  end
end


-- A mouse enabled row would otherwise be a dead spot for dragging the dialog,
-- and the rows cover most of it.
local function ForwardDrag(dialog, row)
  row:RegisterForDrag("LeftButton")
  row:HookScript("OnDragStart", function() dialog:StartMoving() end)
  row:HookScript("OnDragStop", function() dialog:StopMovingOrSizing() end)
end

-- One pool of rows per kind, for each frame rows are drawn into.
local function NewRowPools()
  local pools = {}
  for kind in pairs(rowKinds) do
    pools[kind] = {}
  end
  return pools
end

-- The host is the frame the row is drawn into: the edit mode dialog, or a
-- settings page from CreateSettingsFrame. A row stays with its host for life.
local function AcquireRow(host, kind)
  local pool = host.rows[kind]
  pool.used = (pool.used or 0) + 1

  local row = pool[pool.used]
  if row then
    return row
  end

  if kind == "text" then
    row = CreateFrame("Frame", nil, host)
    row:SetSize(343, 32)

    row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
    row.Label:SetPoint("LEFT")
    row.Label:SetWidth(labelColumnWidth)
    row.Label:SetJustifyH("LEFT")

    -- Dressed like StaticPopup1EditBox, which is a plain EditBox wearing
    -- TooltipBackdropTemplate. InputBoxTemplate's gold border looks out of place
    -- next to the edit mode's own dark rows. Sized and placed like a dropdown
    -- row, so that the control column lines up down the dialog.
    row.EditBox = CreateFrame("EditBox", nil, row, "TooltipBackdropTemplate")
    row.EditBox:SetSize(225, 25)
    row.EditBox:SetPoint("LEFT", row.Label, "RIGHT", controlGap, 0)
    row.EditBox:SetFontObject(ChatFontNormal)
    row.EditBox:SetTextInsets(6, 6, 2, 2)
    row.EditBox:SetAutoFocus(false)

    row.EditBox:SetScript("OnEditFocusGained", function(editBox)
      editBox.libOriginal = editBox:GetText()
    end)
    row.EditBox:SetScript("OnEnterPressed", function(editBox)
      editBox:ClearFocus()
    end)
    row.EditBox:SetScript("OnEscapePressed", function(editBox)
      editBox:SetText(editBox.libOriginal or "")
      editBox:ClearFocus()
    end)
    -- Every keystroke reaches the addon, so that it can show the change as it is
    -- typed. userInput tells a typed change from SetText putting the value back,
    -- which would otherwise report a change nobody made.
    row.EditBox:SetScript("OnTextChanged", function(editBox, userInput)
      if userInput and editBox.libPreview then
        editBox.libPreview(editBox:GetText())
      end
    end)

    row.EditBox:SetScript("OnEditFocusLost", function(editBox)
      if editBox.libCommit then
        editBox.libCommit(editBox:GetText())
      end
    end)

  elseif kind == "separator" then
    row = CreateFrame("Frame", nil, host)
    row:SetSize(330, 16)
    row.Line = row:CreateTexture(nil, "ARTWORK")
    row.Line:SetTexture([[Interface\FriendsFrame\UI-FriendsFrame-OnlineDivider]])
    row.Line:SetAllPoints()

  elseif rowIsButton[kind] then
    row = CreateFrame("Button", nil, host, "EditModeSystemSettingsDialogButtonTemplate")

  elseif kind == "color" then
    row = CreateFrame("Frame", nil, host)
    row:SetSize(343, 32)

    -- ColorSwatchTemplate is declared as a Frame, but Blizzard's own
    -- SettingsColorSwatchTemplate inherits it into a Button, so this is a shape
    -- the template is meant to take.
    --
    -- Swatch first, label after, like a checkbox row. The two offsets centre the
    -- 16 pixel swatch in the 32 pixel slot a checkbox occupies and start the
    -- label where a checkbox label starts, so the columns line up.
    row.Swatch = CreateFrame("Button", nil, row, "ColorSwatchTemplate")
    row.Swatch:SetPoint("LEFT", row, "LEFT", swatchInset, 0)

    row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
    row.Label:SetPoint("LEFT", row, "LEFT", boxedLabelInset, 0)
    row.Label:SetWidth(boxedLabelWidth)
    row.Label:SetJustifyH("LEFT")
    row.Swatch:SetScript("OnClick", function(swatch)
      if swatch:GetParent().libOpenPicker then
        swatch:GetParent().libOpenPicker()
      end
    end)
  else
    row = CreateFrame("Frame", nil, host, rowTemplates[kind])
  end
  pool[pool.used] = row
  row.libHost = host

  -- Wired once per created row, never per use, because these accumulate.
  if kind ~= "separator" then
    WireTooltip(row, row, rowIsButton[kind] or false)
    if host:IsMovable() then
      ForwardDrag(host, row)
    end
    -- The named control first, which is the one the library builds itself and so
    -- the one whose mouse it may switch on, then everything else on the row.
    WireTooltip(row, rowControl[kind] and row[rowControl[kind]], true)
    WireDescendants(row, row)
  end

  if row.Label then
    row.libLabelWidth = row.Label:GetWidth()
  end
  row.libWidth = row:GetWidth()

  -- Blizzard's row mixins report every change to the global
  -- EditModeSystemSettingsDialog. That call is harmless because that dialog drops
  -- everything while it has no system attached, but the value has to be picked up
  -- here instead.
  if kind == "slider" then
    row.Slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(owner, value)
      if owner.libInit or not owner.libSetting or not owner.libInfo then
        return
      end

      local setting = owner.libSetting
      local stepSize = setting.stepSize or 1
      value = setting.minValue + floor((value - setting.minValue) / stepSize + 0.5) * stepSize

      -- A drag fires this every frame, so only act on an actual step change.
      if owner.libLast == value then
        return
      end
      owner.libLast = value

      SetRowValue(owner.libHost, owner.libInfo, setting, value)
    end, row)

  elseif kind == "checkbox" then
    row.OnCheckButtonClick = function(self)
      PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
      self.checked = not self.checked
      self.Button:SetChecked(self.checked)
      if self.libSetting and self.libInfo then
        SetRowValue(self.libHost, self.libInfo, self.libSetting, self.checked)
      end
    end
  end

  if kind == "dropdown" or kind == "actions" then
    -- The row's tooltip follows the menu while it is open. See menuWatcher.
    row.Dropdown:RegisterCallback(DropdownButtonMixin.Event.OnMenuOpen, function()
      WatchMenuOf(row)
    end, row)
    -- An option being tried on is given up when the menu closes, whether one was
    -- picked or not. See SetupDropdown.
    row.Dropdown:RegisterCallback(DropdownButtonMixin.Event.OnMenuClose, function()
      local setting = row.libSetting
      if setting and setting.OnHover then
        setting.OnHover(nil)
      end
    end, row)
  end

  return row
end

local function SetupSlider(row, info, setting)
  row.Label:SetText(setting.name)

  row.formatters = {
    [MinimalSliderWithSteppersMixin.Label.Right] =
      CreateMinimalSliderFormatter(MinimalSliderWithSteppersMixin.Label.Right, setting.formatter),
  }
  row.Slider:SetWidth(200)

  local stepSize = setting.stepSize or 1
  local steps = (setting.maxValue - setting.minValue) / stepSize
  local value = info.GetSetting(setting.key) or setting.minValue

  row.libInit = true
  row.libLast = value
  row.Slider:Init(value, setting.minValue, setting.maxValue, steps, row.formatters)
  row.libInit = false
end

local function SetupCheckbox(row, info, setting)
  -- The label font and the button's enabled state are SetRowEnabled's business.
  row.Label:SetText(setting.name)
  row.checked = info.GetSetting(setting.key) and true or false
  row.Button:SetChecked(row.checked)
end

local function SetupDropdown(row, info, setting)
  row.Label:SetText(setting.name)

  local options = setting.options
  if type(options) == "function" then
    options = options()
  end

  -- The button shows the selected option's text. A stored value no option
  -- carries any more, a font from an addon that is no longer installed say, is
  -- shown as it stands rather than as nothing at all.
  local current = info.GetSetting(setting.key)
  local currentText = current ~= nil and tostring(current) or ""
  for _, option in ipairs(options) do
    if not option.separator and option.value == current then
      currentText = option.text
      break
    end
  end
  row.Dropdown:SetDefaultText(currentText)

  -- An option is tried on while the mouse rests on it, the way the barber shop
  -- does, and given up when the mouse moves off it. The menu closing gives it up
  -- too, wired once per row in AcquireRow. An entry marked separator draws a
  -- divider instead.
  row.Dropdown:SetupMenu(function(dropdown, rootDescription)
    for _, option in ipairs(options) do
      if option.separator then
        rootDescription:CreateDivider()
      else
        local radio = rootDescription:CreateRadio(option.text,
          function(value)
            return info.GetSetting(setting.key) == value
          end,
          function(value)
            SetRowValue(row.libHost, info, setting, value)
            row.Dropdown:GenerateMenu()
          end,
          option.value)
        if setting.OnHover then
          radio:HookOnEnter(function() setting.OnHover(option.value) end)
          radio:HookOnLeave(function() setting.OnHover(nil) end)
        end
      end
    end
  end)

  -- SetupMenu only generates while the dropdown is already visible, and a rebuilt
  -- dialog would otherwise show the previous selection on its button.
  row.Dropdown:GenerateMenu()
end

-- A dropdown that runs the entry you pick rather than remembering it. Buttons
-- rather than radios, and the button keeps its placeholder however many times it
-- is used, because what was picked happened rather than became true. An entry
-- marked separator draws a divider instead.
local function SetupActions(row, info, setting)
  row.Label:SetText(setting.name)
  row.Dropdown:SetDefaultText(setting.placeholder or setting.name or "")

  local actions = setting.actions
  if type(actions) == "function" then
    actions = actions(info)
  end
  actions = actions or {}

  row.Dropdown:SetupMenu(function(dropdown, rootDescription)
    for _, action in ipairs(actions) do
      if action.separator then
        rootDescription:CreateDivider()
      else
        rootDescription:CreateButton(action.text, function()
          if action.OnClick then
            action.OnClick(info)
          end
        end)
      end
    end
  end)

  row.Dropdown:GenerateMenu()

  -- Nothing to offer, so nothing to open.
  row.libActionCount = #actions
end

local function SetupText(row, info, setting)
  row.Label:SetText(setting.name)

  local editBox = row.EditBox
  editBox:SetMaxLetters(setting.maxLetters or 0)
  editBox:SetText(info.GetSetting(setting.key) or "")
  editBox:SetCursorPosition(0)

  local function Apply(text)
    if text ~= info.GetSetting(setting.key) then
      SetRowValue(row.libHost, info, setting, text)
    end
  end

  -- While typing the text is taken as it stands. Trimming here would mean a
  -- leading space could never be typed, because it would vanish as it was hit.
  editBox.libPreview = Apply

  -- Trimming belongs at the end, when the box is left or the value confirmed.
  editBox.libCommit = function(text)
    local final = setting.trim and strtrim(text) or text
    if final ~= text then
      editBox:SetText(final)
    end
    Apply(final)
  end
end

-- The button a color setting's colorButton puts on Blizzard's colour picker.
-- There is one picker for every addon, so the button is shown only while a picker
-- this library opened asks for it, and goes again as soon as the picker closes or
-- anyone at all sets it up afresh.
local function ColorButton()
  if lib.colorButton then
    return lib.colorButton
  end

  local button = CreateFrame("Button", nil, ColorPickerFrame, "UIPanelButtonTemplate")
  local content = ColorPickerFrame.Content
  if content and content.HexBox then
    -- Halfway between the swatches and the hex box, and looking as wide and as
    -- tall as the box. Measured on the art rather than the frames: the box's
    -- border reaches 5 past it on the left and sits 1.5 inside its top, and the
    -- button's art keeps about 2 clear of its frame all round.
    button:SetPoint("BOTTOMLEFT", content.HexBox, "TOPLEFT", -7.5, 18)
    button:SetPoint("BOTTOMRIGHT", content.HexBox, "TOPRIGHT", 2, 18)
    button:SetHeight(20)
  else
    -- The classic picker has neither, but room under its one swatch.
    button:SetPoint("TOP", ColorSwatch, "BOTTOM", 0, -12)
    button:SetSize(72, 22)
  end
  button:Hide()

  button:SetScript("OnClick", function(self)
    local r, g, b, a = self.libColor.r, self.libColor.g, self.libColor.b, self.libColor.a
    -- Through the picker's own controls, so that its swatch and hex box follow
    -- and Cancel still puts back what was there before.
    if content and content.ColorPicker then
      if ColorPickerFrame.hasOpacity then
        content.ColorPicker:SetColorAlpha(a)
      end
      content.ColorPicker:SetColorRGB(r, g, b)
    else
      if ColorPickerFrame.hasOpacity then
        OpacitySliderFrame:SetValue(a)
      end
      ColorPickerFrame:SetColorRGB(r, g, b)
    end
    -- The picker reports nothing for a colour it is already showing.
    self.libOnPick(r, g, b, a)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
  end)
  button:SetScript("OnEnter", function(self)
    if self.libTooltip then
      local tooltip = GetAppropriateTooltip()
      tooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip_SetTitle(tooltip, self:GetText())
      GameTooltip_AddNormalLine(tooltip, self.libTooltip, true)
      tooltip:Show()
    end
  end)
  button:SetScript("OnLeave", function(self)
    GetAppropriateTooltip():Hide()
  end)

  ColorPickerFrame:HookScript("OnHide", function() button:Hide() end)
  hooksecurefunc(ColorPickerFrame, "SetupColorPickerAndShow", function() button:Hide() end)

  lib.colorButton = button
  return button
end

-- Opens Blizzard's colour picker on picker.color, calling picker.OnPick(r, g, b, a)
-- with every change and with the colour it started from on cancel.
local function ShowColorPicker(picker)
  local color = picker.color or {}
  local hasOpacity = picker.hasOpacity ~= false

  -- Without its opacity slider the picker still reports an opacity, whatever
  -- the slider was last left at, so the colour keeps its own instead.
  local function OnPick(r, g, b, a)
    picker.OnPick(r, g, b, hasOpacity and a or color.a or 1)
  end

  local function Picked()
    local r, g, b = ColorPickerFrame:GetColorRGB()
    OnPick(r, g, b, ColorPickerFrame:GetColorAlpha())
  end

  ColorPickerFrame:SetupColorPickerAndShow({
    r = color.r or 1, g = color.g or 1, b = color.b or 1,
    opacity = color.a or 1,
    hasOpacity = hasOpacity,
    swatchFunc = Picked,
    opacityFunc = Picked,
    cancelFunc = function(previous)
      if previous then
        OnPick(previous.r, previous.g, previous.b, previous.a)
      end
    end,
  })

  local wanted = picker.colorButton
  if wanted then
    -- After setting the picker up, which hides the button.
    local button = ColorButton()
    button:SetText(wanted.text)
    button.libColor = { r = wanted.color.r or 1, g = wanted.color.g or 1,
      b = wanted.color.b or 1, a = wanted.color.a or 1 }
    button.libTooltip = wanted.tooltip
    button.libOnPick = OnPick
    button:Show()
  end
end

local function SetupColor(row, info, setting)
  row.Label:SetText(setting.name)

  local function Show(color)
    row.Swatch:SetColorRGB(color.r or 1, color.g or 1, color.b or 1)
  end

  Show(info.GetSetting(setting.key) or {})

  row.libOpenPicker = function()
    ShowColorPicker({
      color = info.GetSetting(setting.key),
      hasOpacity = setting.hasOpacity,
      colorButton = setting.colorButton,
      -- Handed over as a fresh table every time, so that nothing downstream ends
      -- up holding the same table the layout stored.
      OnPick = function(r, g, b, a)
        local color = { r = r, g = g, b = b, a = a }
        Show(color)
        SetRowValue(row.libHost, info, setting, color)
      end,
    })
  end
end

-- Greys a row out. The setting still holds its value, it just cannot be reached,
-- which is what a setting another one has made moot should look like.
local function SetRowEnabled(row, kind, enabled)
  if row.Label then
    row.Label:SetFontObject(enabled and "GameFontHighlightMedium" or "GameFontDisableMed2")
  end

  if kind == "checkbox" then
    row.Button:SetEnabled(enabled)
  elseif kind == "dropdown" or kind == "actions" then
    row.Dropdown:SetEnabled(enabled)
  elseif kind == "color" then
    row.Swatch:SetEnabled(enabled)
    row.Swatch:SetAlpha(enabled and 1 or 0.5)
  elseif kind == "text" then
    row.EditBox:SetEnabled(enabled)
    row.EditBox:SetAlpha(enabled and 1 or 0.5)
  elseif kind == "slider" then
    row.Slider.Slider:SetEnabled(enabled)
    row.Slider.Back:SetEnabled(enabled)
    row.Slider.Forward:SetEnabled(enabled)
    row.Slider:SetAlpha(enabled and 1 or 0.5)
  elseif rowIsButton[kind] then
    row:SetEnabled(enabled)
  end
end

-- Blizzard nudges the selected system with the arrow keys, ten pixels at a time
-- while shift is held, and routes the keys through the settings dialog rather
-- than through the frame. Same here, for the same reason: the dialog is on screen
-- exactly while something is selected.
local movementKeys = { UP = true, DOWN = true, LEFT = true, RIGHT = true }

local function NudgeSelection(key)
  local info = lib.selected
  if not info or not IsManaged(info) then
    return false
  end

  local point, relativePoint, x, y = info.GetPosition()
  if not point then
    return false
  end

  local step = IsShiftKeyDown() and 10 or 1
  x, y = x or 0, y or 0
  if key == "UP" then
    y = y + step
  elseif key == "DOWN" then
    y = y - step
  elseif key == "LEFT" then
    x = x - step
  else
    x = x + step
  end

  CommitPosition(info, point, relativePoint, x, y)
  return true
end

-- Puts the frame back where the addon says it belongs, as the kind of change the
-- host makes. Either way the reset position row greys out again once it is back.
local function ResetPosition(host, info)
  local point, relativePoint, x, y = DefaultPosition(info)
  if not point then
    return
  end
  if host.libPage then
    EditThroughAddon(info, function() info.EditPosition(point, relativePoint, x, y) end)
  else
    CommitPosition(info, point, relativePoint, x, y)
  end
end

-- The dialog's width, which a settings page takes too. Then where its rows start
-- below its top edge and the room left under the last one: the dialog has its
-- title above the rows and its border around them, a settings page neither.
local dialogWidth = 400
local dialogTop, dialogBottom = 48, 20

local function BuildDialog()
  if lib.dialog then
    return lib.dialog
  end

  local dialog = CreateFrame("Frame", nil, UIParent)
  dialog:SetFrameStrata("DIALOG")
  dialog:SetFrameLevel(200)
  dialog:SetWidth(dialogWidth)
  dialog:SetHeight(120)
  dialog:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 200)
  dialog:EnableMouse(true)
  dialog:SetMovable(true)
  dialog:SetClampedToScreen(true)
  dialog:RegisterForDrag("LeftButton")
  dialog:SetScript("OnDragStart", dialog.StartMoving)
  dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
  dialog:Hide()

  -- Everything but an arrow key we act on is passed straight on, so that escape
  -- still leaves edit mode, print screen still takes a screenshot and typing still
  -- reaches whatever wanted it. An edit box with focus takes the keys first, so
  -- the arrow keys still walk the cursor along the text being typed.
  dialog:EnableKeyboard(true)
  dialog:SetPropagateKeyboardInput(true)
  dialog:SetScript("OnKeyDown", function(self, key)
    local handled = movementKeys[key] and NudgeSelection(key) or false
    self:SetPropagateKeyboardInput(not handled)
  end)

  dialog.Border = CreateFrame("Frame", nil, dialog, "DialogBorderTranslucentTemplate")

  dialog.Title = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
  dialog.Title:SetPoint("TOP", 0, -16)

  dialog.CloseButton = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
  dialog.CloseButton:SetPoint("TOPRIGHT", 2, 2)
  dialog.CloseButton:SetScript("OnClick", function()
    lib:ClearSelection()
  end)

  dialog.rows = NewRowPools()

  lib.dialog = dialog
  return dialog
end

-- A button's label that is too long for it, as some translations are on a
-- paired button, is scaled down to fit rather than spilling over its edges, the
-- way Blizzard's AutoScalingFontStringMixin does it. buttonTextInset keeps it off
-- the rounded ends.
local buttonTextInset = 8

local function FitButtonText(button)
  local text = button:GetFontString()
  if not (text and text.SetTextScale) then
    return
  end
  text:SetTextScale(1)
  local room = button:GetWidth() - 2 * buttonTextInset
  local width = text:GetUnboundedStringWidth()
  if width > room and room > 0 then
    text:SetTextScale(room / width)
  end
end

-- Draws every row of a registration into a host, top to bottom.
local function Populate(host, info, top, bottom)
  for _, pool in pairs(host.rows) do
    for index = 1, (pool.used or 0) do
      pool[index]:Hide()
    end
    pool.used = 0
  end

  local offsetY = -top
  local lastHeight = 0

  local function Place(row, kind, sameRow, padTop)
    local column = 1
    if sameRow then
      -- Step back onto the row just placed and take its second column.
      offsetY = offsetY + lastHeight
      column = 2
    else
      offsetY = offsetY - (padTop or rowPadTop[kind] or 0)
    end

    row.libOffsetY = offsetY

    row:ClearAllPoints()
    if rowCentred[kind] then
      row:SetPoint("TOP", host, "TOP", 0, offsetY)
    else
      row:SetPoint("TOPLEFT", host, "TOPLEFT", columnOffsets[column], offsetY)
    end
    row:Show()

    lastHeight = rowHeights[kind] or 34
    offsetY = offsetY - lastHeight
  end

  for index, setting in ipairs(info.settings) do
    if rowKinds[setting.type] then
      local row = AcquireRow(host, setting.type)
      row.libInfo = info
      row.libSetting = setting

      if setting.type == "slider" then
        SetupSlider(row, info, setting)
      elseif setting.type == "checkbox" then
        SetupCheckbox(row, info, setting)
      elseif setting.type == "color" then
        SetupColor(row, info, setting)
      elseif setting.type == "text" then
        SetupText(row, info, setting)
      elseif setting.type == "dropdown" then
        SetupDropdown(row, info, setting)
      elseif setting.type == "actions" then
        SetupActions(row, info, setting)
      elseif setting.type == "button" then
        row:SetText(setting.text)
        row:SetScript("OnClick", function()
          setting.OnClick(info)
        end)
      elseif setting.type == "revert" then
        row:SetText(setting.text or HUD_EDIT_MODE_REVERT_CHANGES)
        row:SetScript("OnClick", function()
          if host.libPage then
            RevertPage(host)
          else
            lib:RevertFrame(info.key)
          end
        end)
      elseif setting.type == "resetPosition" then
        row:SetText(setting.text or HUD_EDIT_MODE_RESET_POSITION or "Reset Position")
        row:SetScript("OnClick", function()
          ResetPosition(host, info)
        end)
      end

      -- A row sharing its line has half the width to say it in, and rows come
      -- from a pool, so the natural width has to be put back on the others.
      local nextSetting = info.settings[index + 1]
      local paired = setting.sameRow or (nextSetting ~= nil and nextSetting.sameRow) or false

      if row.Label and type(row.libLabelWidth) == "number" and row.libLabelWidth > 0 then
        row.Label:SetWidth(paired and pairedLabelWidth or row.libLabelWidth)
      end

      -- Rows built here have a fixed width, so a paired one has to be told to
      -- give the other half back. Rows on Blizzard's templates size themselves
      -- from their contents and report no width of their own, so they are left
      -- alone, the label above having already narrowed them.
      if type(row.libWidth) == "number" and row.libWidth > 0 then
        row:SetWidth(paired and pairedRowWidth or row.libWidth)
      end
      if rowIsButton[setting.type] then
        FitButtonText(row)
      end

      if setting.type == "revert" then
        SetRowEnabled(row, setting.type, HostHasChanges(host, info))
      elseif setting.type == "resetPosition" then
        SetRowEnabled(row, setting.type, not IsInDefaultPosition(info))
      elseif setting.type == "actions" then
        -- Greyed when there is nothing to pick, rather than opening on nothing.
        SetRowEnabled(row, setting.type, (row.libActionCount or 0) > 0
          and not (setting.IsDisabled and setting.IsDisabled()))
      elseif setting.type ~= "separator" then
        SetRowEnabled(row, setting.type, not (setting.IsDisabled and setting.IsDisabled()))
      end

      Place(row, setting.type, setting.sameRow, setting.padTop)
    end
  end

  host:SetHeight(-offsetY + bottom)
end

local function PopulateDialog(info)
  local dialog = BuildDialog()
  dialog.Title:SetText(info.displayName)
  Populate(dialog, info, dialogTop, dialogBottom)
end


--------------------------------------------------------------------------------
-- Refreshing the visible state
--------------------------------------------------------------------------------

function RefreshPanel()
  local panel = lib.panel
  if not panel then
    return
  end

  local writable = ActiveLayoutKey() ~= nil

  local index = 0
  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    index = index + 1

    local row = panel.rows[index]
    if not row then
      row = CreateFrame("Frame", nil, panel.List.ScrollChild, "EditModeManagerSettingCheckButtonTemplate")
      row:SetPoint("TOPLEFT", panel.List.ScrollChild, "TOPLEFT", 0, -(index - 1) * panelRowHeight)
      panel.rows[index] = row
    end

    row:SetLabelText(info.displayName)
    row:SetCallback(function(isChecked)
      lib:SetManaged(regKey, isChecked)
    end)

    -- SetControlChecked would fire the callback again, so set the button directly.
    row.Button:SetChecked(IsManaged(info))
    row:Show()

    -- After the show, because Blizzard's OnShow re-enables the button.
    row.Button:SetEnabled(writable)
    row.Label:SetFontObject(writable and "GameFontHighlightMedium" or "GameFontDisableMed2")
  end

  for i = index + 1, #panel.rows do
    panel.rows[i]:Hide()
  end

  -- As wide as the longest name. Measured unbounded, because the template gives
  -- every label a fixed width and would cut a longer name off.
  local widest = 0
  for i = 1, index do
    widest = max(widest, panel.rows[i].Label:GetUnboundedStringWidth())
  end
  widest = ceil(widest)
  local rowWidth = panelCheckWidth + widest
  for i = 1, index do
    local row = panel.rows[i]
    row.Label:SetWidth(widest)
    -- The template lays its rows out at fixedWidth, so that has to follow too.
    row.fixedWidth = rowWidth
    row:SetWidth(rowWidth)
  end
  panel.List:SetWidth(rowWidth)
  panel.List.ScrollChild:SetWidth(rowWidth)

  -- Never narrower than the title above the list.
  local scrolls = index > panelMaxRows
  panel:SetWidth(max(
    panelListInset + rowWidth + (scrolls and panelScrollBarRoom or panelRightInset),
    ceil(panel.Title:GetUnboundedStringWidth()) + 2 * panelListInset))

  -- The list holds every row and shows at most panelMaxRows of them.
  local shown = max(min(index, panelMaxRows), 1)
  panel.List.ScrollChild:SetHeight(max(index, 1) * panelRowHeight)
  panel.List:SetHeight(shown * panelRowHeight)
  panel:SetHeight(panelHeaderHeight + panelFooterHeight + shown * panelRowHeight)
  -- The panel belongs to edit mode, and this runs outside it too: a layout being
  -- applied, or the addon's own settings handing the frame to a layout.
  panel:SetShown(lib.editModeActive and index > 0)
end

function RefreshOverlays()
  -- Done inline rather than through ClearSelection, which would recurse back here.
  if lib.selected and (not lib.editModeActive or not IsManaged(lib.selected)) then
    lib.selected = nil
    if lib.dialog then
      lib.dialog:Hide()
    end
  end

  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    local managed = lib.editModeActive and IsManaged(info)

    if managed then
      -- The preview has to come first, because the frame may only be created
      -- when the addon is asked to show it.
      if info.OnPreview and not info.previewing then
        info.previewing = true
        info.OnPreview(true)
      end

      local overlay = BuildOverlay(info)
      if overlay then
        local selected = lib.selected == info
        if selected then
          overlay:ShowSelected()
        else
          overlay:ShowHighlighted()
        end
        SetOverlayBehind(info, overlay, info.selectionBehind and selected)
      end

    elseif info.overlay then
      info.overlay:Hide()
      SetOverlayBehind(info, info.overlay, false)
    end

    if not managed and info.OnPreview and info.previewing then
      info.previewing = false
      info.OnPreview(false)
    end
  end
end

function RefreshDialog()
  if not lib.dialog or not lib.dialog:IsShown() then
    return
  end
  if lib.selected then
    PopulateDialog(lib.selected)
  end
end

-- Never while the page's own control is changing the value, because redrawing
-- the row under a slider being dragged would make it lose its grip.
local function RefreshPage(page)
  if page:IsVisible() and not page.libWriting then
    Populate(page, page.libInfo, 0, 0)
  end
end

function RefreshPages()
  for _, page in ipairs(lib.pages) do
    RefreshPage(page)
  end
end

function RefreshHost(host)
  if host.libPage then
    RefreshPage(host)
  else
    RefreshDialog()
  end
end


--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

-- Set while this library is the one clearing everyone else, so that the very
-- announcement does not come straight back and clear this library too.
local announcing = false

-- Nothing owns the edit mode screen, so taking a selection means asking whoever
-- else is on it to put their dialog away. Blizzard's manager is asked through its
-- own ClearSelectedSystem, which its dialog listens to. Other libraries doing the
-- same job listen for LibEditMode's event, which is the closest thing there is to
-- a convention, so it is both fired and answered here.
local function AnnounceSelection()
  announcing = true
  -- Blizzard's own settings dialog must not stay attached to a system while ours
  -- is up, because Blizzard's own setting row templates, which this dialog reuses,
  -- report into whichever dialog is listening.
  EditModeManagerFrame:ClearSelectedSystem()
  EventRegistry:TriggerEvent("EditModeExternal.hideDialog")
  announcing = false
end

function lib:SelectFrame(regKey)
  local info = registrations[regKey]
  if not info or not lib.editModeActive or not IsManaged(info) then
    return
  end

  AnnounceSelection()

  lib.selected = info
  PopulateDialog(info)
  lib.dialog:Show()
  RefreshOverlays()
end

function lib:ClearSelection()
  if not lib.selected then
    return
  end
  lib.selected = nil
  if lib.dialog then
    lib.dialog:Hide()
  end
  RefreshOverlays()
end


--------------------------------------------------------------------------------
-- Enabling and disabling a frame for the active layout
--------------------------------------------------------------------------------

-- Returns a copy of the session's entry with only its ownership changed. An entry
-- that does not exist yet starts out with the look the frame has just been given.
local function WithOwnership(entry, look, managed)
  if entry then
    entry = CopyTable(entry)
    entry.inactive = not managed or nil
    return entry
  end
  if managed and look then
    entry = CopyTable(look)
    entry.inactive = nil
    return entry
  end
  return nil
end

function lib:SetManaged(regKey, managed)
  local info = registrations[regKey]
  if not info then
    return
  end

  -- Refused on a preset outside edit mode, where there would be no session to
  -- carry the change into a new layout and the preset itself is never written.
  if not lib:CanManage() then
    RefreshPanel()
    return
  end

  local key = ActiveLayoutKey()

  local entry = CurrentEntry(info)

  if managed then
    if entry then
      -- A look this layout had parked. Put it back on, rather than capturing
      -- whatever the frame happens to be wearing in the meantime.
      entry.inactive = nil
      ApplyEntry(info, entry)
    else
      entry = CaptureEntry(info)
      if lib.sessionKey then
        info.pending = entry
      else
        info.storage[key] = entry
      end
    end
  else
    -- Kept rather than deleted, so that ticking the box again brings this
    -- layout's own look back.
    if entry then
      entry.inactive = true
    end
    if lib.selected == info then
      lib:ClearSelection()
    end
    if info.RestoreOwnSettings then
      info.RestoreOwnSettings()
    end
  end

  -- Ticking and unticking take effect at once, the way Blizzard's own checkboxes
  -- on this panel do, so they are not a change: Save does not light up for them
  -- and reverting leaves them alone. The session carries the new ownership into
  -- everything it measures against, while the look in each stays what it was, so
  -- edits made to the look are still the changes they were.
  if lib.sessionKey then
    info.baseline = WithOwnership(info.baseline, info.pending, managed)
    info.revertPoint = WithOwnership(info.revertPoint, info.pending, managed)
    if managed then
      -- What reverting puts on the frame now that the layout owns it.
      info.live = CopyTable(info.baseline)
    end
    -- A preset is never written, so there a tick lasts only as long as the session.
    if not IsPresetKey(key) then
      info.storage[key] = WithOwnership(info.storage[key], info.pending, managed)
    end
  end

  RefreshButtonStates()
  RefreshPanel()
  RefreshOverlays()
  -- The frame is wearing a different look now, the layout's or its own.
  RefreshPages()
end


--------------------------------------------------------------------------------
-- Applying a layout
--------------------------------------------------------------------------------

local function ApplyLayout()
  local key = ActiveLayoutKey()
  if not key then
    return
  end

  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    -- A layout that does not own the frame has the addon put its own settings
    -- back. Without that the frame would keep wearing whatever the last layout
    -- that did own it imposed, which is not this layout's look at all.
    ApplyOrRestore(info, info.storage[key])
  end
end


--------------------------------------------------------------------------------
-- Hooks into the edit mode manager
--------------------------------------------------------------------------------

-- Puts one frame back to how the session found it. A frame no layout owned then
-- is handed back rather than having its session start values applied: they are
-- the addon's own settings, and applying them would leave the frame looking as
-- though a layout had chosen every one of them.
local function RestoreLook(info, baseline, live)
  if not IsActiveEntry(baseline) and info.RestoreOwnSettings then
    info.RestoreOwnSettings()
  else
    ApplyEntry(info, live)
  end
end

local function RevertSession()
  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    info.pending = info.baseline and CopyTable(info.baseline) or nil
    info.revertPoint = info.baseline and CopyTable(info.baseline) or nil
    RestoreLook(info, info.baseline, info.live)
  end
  lib.dirty = false
  RefreshPanel()
  RefreshOverlays()
  RefreshDialog()
end

-- Blizzard reverts on every exit, on the revert button, and as the very first step
-- of creating a new layout. Which of those it is only becomes clear afterwards, so
-- the session is copied aside here and the actual revert waits one frame. Creating
-- a layout cancels that wait and claims the copy instead.
local function ScheduleRevert()
  if not lib.sessionKey or revertScheduled then
    return
  end

  revertScheduled = true

  local snapshot = { key = lib.sessionKey, entries = {} }
  for _, regKey in ipairs(order) do
    local info = registrations[regKey]
    snapshot.entries[regKey] = {
      pending = info.pending and CopyTable(info.pending) or nil,
      baseline = info.baseline and CopyTable(info.baseline) or nil,
      live = info.live and CopyTable(info.live) or nil,
    }
  end
  revertSnapshot = snapshot

  C_Timer.After(0, function()
    if not revertScheduled then
      return
    end
    revertScheduled = false
    ConsumeRevert()
  end)
end

-- Puts every frame back the way the session found it.
function ConsumeRevert()  -- forward declared as a local above
  local snapshot = revertSnapshot
  revertSnapshot = nil
  if not snapshot then
    return
  end

  for regKey, entry in pairs(snapshot.entries) do
    local info = registrations[regKey]
    if info then
      info.pending = entry.baseline and CopyTable(entry.baseline) or nil
      info.revertPoint = entry.baseline and CopyTable(entry.baseline) or nil
      RestoreLook(info, entry.baseline, entry.live)
    end
  end

  lib.dirty = false
  RefreshPanel()
  RefreshOverlays()
  RefreshDialog()
end

local function OnLayoutsUpdated()
  RefreshLayoutIndex()

  local key = ActiveLayoutKey()

  -- Switching layouts mid session drops unsaved changes, exactly as it does for
  -- Blizzard's own systems. Not while a revert is pending though, because that is
  -- a layout being created out of the one that is active, and those edits are
  -- owed to the new layout.
  if lib.sessionKey and key ~= lib.sessionKey and not revertScheduled then
    RevertSession()
  end

  ApplyLayout()
  RefreshPages()

  -- A plain revert also lands here with the key unchanged, and must not throw the
  -- pending edits away before ConsumeRevert has had its say.
  if lib.editModeActive and key ~= lib.sessionKey then
    BeginSession(key)
  end

  RefreshPanel()
  RefreshOverlays()
  RefreshDialog()
end

local function OnEditModeEnter()
  BuildPanel()
  lib.editModeActive = true
  lib.dirty = false
  BeginSession(ActiveLayoutKey())
  RefreshPanel()
  RefreshOverlays()
end

local function OnEditModeExit()
  -- Blizzard reverts as part of leaving, and that revert has to happen before the
  -- session is torn down, because the session holds what to revert to.
  if revertScheduled then
    revertScheduled = false
    ConsumeRevert()
  end

  local key = lib.sessionKey
  lib.editModeActive = false
  lib:ClearSelection()
  RefreshOverlays()
  EndSession()
  -- A tick on a preset lasts only as long as the session, so the frame is handed
  -- back to what the preset really holds, which is nothing.
  if IsPresetKey(key) then
    ApplyLayout()
  end
  if lib.panel then
    lib.panel:Hide()
  end
end

local function OnNewLayout(_, newLayoutInfo, layoutType, layoutName, isLayoutImported)
  -- Blizzard reverts before it creates the layout, so a pending revert is proof
  -- that a layout was really created. Those reverted edits belong to the new
  -- layout, and the layout they were made in goes back to what it was.
  if not revertScheduled then
    return
  end
  revertScheduled = false

  local snapshot = revertSnapshot
  revertSnapshot = nil
  if not snapshot then
    return
  end

  local oldKey = snapshot.key
  local newKey = LayoutKey({ layoutType = layoutType, layoutName = layoutName })

  for regKey, entry in pairs(snapshot.entries) do
    local info = registrations[regKey]
    if info then
      -- The baseline carries any tick from this session, which on a preset is
      -- never stored.
      if oldKey and not IsPresetKey(oldKey) then
        info.storage[oldKey] = entry.baseline and CopyTable(entry.baseline) or nil
      end
      -- An imported layout was built from someone else's string, which carries
      -- nothing of ours, so it starts out owning nothing. Only a layout the
      -- player made out of the one they were editing inherits those edits.
      if not isLayoutImported then
        info.storage[newKey] = entry.pending and CopyTable(entry.pending) or nil
      end
    end
  end

  -- Applied by key rather than through ApplyLayout, because the client may not
  -- have switched the active layout over yet. A layout that ended up owning
  -- nothing hands the frame back, exactly as ApplyLayout would.
  for _, regKey in ipairs(order) do
    ApplyOrRestore(registrations[regKey], registrations[regKey].storage[newKey])
  end

  BeginSession(newKey)
  lib.dirty = false
  RefreshPanel()
  RefreshOverlays()
  RefreshDialog()
end

local function OnRenameLayout(manager, layoutIndex)
  local layout = manager.layoutInfo and manager.layoutInfo.layouts[layoutIndex]
  local oldKey = lib.keyByIndex and lib.keyByIndex[layoutIndex]
  local newKey = LayoutKey(layout)

  if oldKey and newKey and oldKey ~= newKey then
    for _, regKey in ipairs(order) do
      local info = registrations[regKey]
      info.storage[newKey] = info.storage[oldKey]
      info.storage[oldKey] = nil
    end
    if lib.sessionKey == oldKey then
      lib.sessionKey = newKey
    end
  end

  RefreshLayoutIndex()
end

local function OnDeleteLayout(manager, layoutIndex)
  local oldKey = lib.keyByIndex and lib.keyByIndex[layoutIndex]
  if oldKey then
    for _, regKey in ipairs(order) do
      registrations[regKey].storage[oldKey] = nil
    end
  end
  RefreshLayoutIndex()
end

local function OnCheckActiveChanges(manager)
  if lib.dirty then
    manager:SetHasActiveChanges(true)
  end
end

-- Hooks can only be installed once per session, while a newer copy of the library
-- may well load after an older one has already installed them. So every hook does
-- nothing but dispatch through these fields, which the newest copy overwrites.
lib.handlers = lib.handlers or {}

lib.handlers.OnLayoutsUpdated = function(...) return OnLayoutsUpdated(...) end
lib.handlers.ScheduleRevert = function(...) return ScheduleRevert(...) end
lib.handlers.OnEditModeEnter = function(...) return OnEditModeEnter(...) end
lib.handlers.OnEditModeExit = function(...) return OnEditModeExit(...) end
lib.handlers.CommitSession = function(...) return CommitSession(...) end
lib.handlers.OnNewLayout = function(...) return OnNewLayout(...) end
lib.handlers.OnRenameLayout = function(...) return OnRenameLayout(...) end
lib.handlers.OnDeleteLayout = function(...) return OnDeleteLayout(...) end
lib.handlers.OnCheckActiveChanges = function(...) return OnCheckActiveChanges(...) end
-- Something else on the edit mode screen took a selection. Ignored while this
-- library is the one saying so, or selecting one of our own frames would clear
-- the selection it is in the middle of making.
lib.handlers.ClearSelection = function()
  if announcing then
    return
  end
  return lib:ClearSelection()
end

local function InstallHooks()
  if lib.hooksInstalled or not IsSupported() then
    return
  end
  lib.hooksInstalled = true

  local handlers = lib.handlers

  -- Every path that applies a layout funnels through here, including the layout
  -- dropdown, a spec change (which switches layouts without firing an event of its
  -- own) and override layouts.
  hooksecurefunc(EditModeManagerFrame, "UpdateLayoutInfo", function(...)
    handlers.OnLayoutsUpdated(...)
  end)

  hooksecurefunc(EditModeManagerFrame, "RevertAllChanges", function(...)
    handlers.ScheduleRevert(...)
  end)

  -- Except that the Revert All Changes button never reaches that hook: it was
  -- handed RevertAllChanges as a closure when it loaded, before any hook existed.
  -- ScheduleRevert ignores a second call, so this stays right should Blizzard
  -- ever change that.
  local revertButton = EditModeManagerFrame.RevertAllChangesButton
  if revertButton then
    revertButton:HookScript("OnClick", function()
      handlers.ScheduleRevert()
    end)
  end

  -- Runs whenever a Blizzard system reports in, and would otherwise grey the save
  -- button out again while there are still changes here.
  hooksecurefunc(EditModeManagerFrame, "CheckForSystemActiveChanges", function(...)
    handlers.OnCheckActiveChanges(...)
  end)

  hooksecurefunc(EditModeManagerFrame, "MakeNewLayout", function(...)
    handlers.OnNewLayout(...)
  end)

  hooksecurefunc(EditModeManagerFrame, "RenameLayout", function(...)
    handlers.OnRenameLayout(...)
  end)

  hooksecurefunc(EditModeManagerFrame, "DeleteLayout", function(...)
    handlers.OnDeleteLayout(...)
  end)

  -- One of Blizzard's systems took over, so our dialog has to step aside.
  hooksecurefunc(EditModeManagerFrame, "SelectSystem", function()
    handlers.ClearSelection()
  end)

  -- And so does every other library that adds frames to edit mode: each of them
  -- announces a selection by clearing Blizzard's, so that is the one signal they
  -- all send. EditModeExpanded sends nothing else at all.
  hooksecurefunc(EditModeManagerFrame, "ClearSelectedSystem", function()
    handlers.ClearSelection()
  end)

  -- LibEditMode's convention, which it both fires and answers. Anything that
  -- follows it stands down for us and we stand down for it.
  EventRegistry:RegisterCallback("EditModeExternal.hideDialog", function()
    handlers.ClearSelection()
  end, lib)

  EventRegistry:RegisterCallback("EditMode.Enter", function() handlers.OnEditModeEnter() end, lib)
  EventRegistry:RegisterCallback("EditMode.Exit", function() handlers.OnEditModeExit() end, lib)
  EventRegistry:RegisterCallback("EditMode.SavedLayouts", function() handlers.CommitSession() end, lib)
end

-- Renames and deletions are only reported by index, so the mapping from index to
-- key has to be kept from before the change. Internal: only the layout hooks and
-- registration need it, so it is not part of the API.
function RefreshLayoutIndex()
  local layouts = IsSupported() and EditModeManagerFrame.layoutInfo and EditModeManagerFrame.layoutInfo.layouts
  local keyByIndex = {}
  if layouts then
    for index, layout in ipairs(layouts) do
      keyByIndex[index] = LayoutKey(layout)
    end
  end
  lib.keyByIndex = keyByIndex
end


--------------------------------------------------------------------------------
-- Public interface
--------------------------------------------------------------------------------

function lib:IsSupported()
  return IsSupported()
end

--- Returns true while the active layout is one a frame can be given to. False
-- under an override layout, the kind the game forces on the player, which is
-- never written to. False as well under one of Blizzard's preset layouts outside
-- of edit mode: edit mode only lets a preset be changed by saving it as a new
-- layout, so outside of it there is nowhere for the change to go.
function lib:CanManage()
  if not ActiveLayoutKey() then
    return false
  end
  return not IsPresetLayout(ActiveLayout()) or lib.sessionKey ~= nil
end

--- Returns true while one of Blizzard's preset layouts is active, for an addon
-- that wants to tell the player why CanManage is false.
function lib:IsPresetActive()
  return IsPresetLayout(ActiveLayout())
end

--- Returns the name of the layout that is active, for an addon that wants to
-- name it in its own UI. Whatever its type, so an override layout reports the
-- name the game gave it, and nil on a client with no edit mode at all.
function lib:GetActiveLayoutName()
  local layout = ActiveLayout()
  return layout and layout.layoutName or nil
end

--- Opens Blizzard's colour picker the way a color row does, its button and
-- all, for a colour the addon also offers somewhere of its own, a context menu
-- say. Needs no edit mode, so it works on every client.
-- @param picker  {color =, OnPick =, hasOpacity =, colorButton =}, see README.md
function lib:ShowColorPicker(picker)
  assert(type(picker) == "table" and type(picker.OnPick) == "function",
    MAJOR .. ": picker.OnPick has to be a function.")
  ShowColorPicker(picker)
end

--- Registers a frame for layout aware placement and settings.
-- @param regKey  unique string identifying this registration
-- @param info    table as described at the top of this file
function lib:RegisterFrame(regKey, info)
  assert(type(regKey) == "string", MAJOR .. ": regKey has to be a string.")
  assert(type(info) == "table", MAJOR .. ": info has to be a table.")
  assert(info.frame or info.GetFrame, MAJOR .. ": info.frame or info.GetFrame is required.")
  assert(info.displayName, MAJOR .. ": info.displayName is required.")
  assert(type(info.storage) == "table", MAJOR .. ": info.storage has to be a table.")
  assert(type(info.GetPosition) == "function", MAJOR .. ": info.GetPosition is required.")
  assert(type(info.SetPosition) == "function", MAJOR .. ": info.SetPosition is required.")

  info.settings = info.settings or {}
  if #info.settings > 0 then
    assert(type(info.GetSetting) == "function", MAJOR .. ": info.GetSetting is required for settings.")
    assert(type(info.SetSetting) == "function", MAJOR .. ": info.SetSetting is required for settings.")
  end

  -- Checked here rather than left to the dialog, which draws what it recognises
  -- and passes over the rest without a word - so a mistyped descriptor would
  -- simply never appear, with nothing to say why.
  for index, setting in ipairs(info.settings) do
    local where = MAJOR .. ": settings[" .. index .. "] "
    assert(rowKinds[setting.type], where .. "has an unknown type: " .. tostring(setting.type))

    if setting.type == "actions" then
      assert(setting.actions, where .. "is an action row and so needs actions.")
    elseif not rowIsButton[setting.type] and setting.type ~= "separator" then
      assert(setting.key, where .. "carries a value and so needs a key.")
    end

    if setting.type == "slider" then
      assert(type(setting.minValue) == "number" and type(setting.maxValue) == "number",
        where .. "is a slider and so needs minValue and maxValue.")
    end
  end

  -- Nothing is ever stored for a preset. An entry for one can only be left over
  -- from before that was enforced, and would pin a look on a layout the player
  -- has no way left to change.
  for key in pairs(info.storage) do
    if IsPresetKey(key) then
      info.storage[key] = nil
    end
  end

  info.key = regKey

  if not registrations[regKey] then
    table.insert(order, regKey)
  end
  registrations[regKey] = info

  if not IsSupported() then
    return
  end

  InstallHooks()
  RefreshLayoutIndex()

  -- The layout may already have been applied before this addon finished loading.
  local key = ActiveLayoutKey()
  if key then
    ApplyEntry(info, info.storage[key])
  end

  if lib.editModeActive then
    BeginSession(key)
    RefreshPanel()
    RefreshOverlays()
  end
end

function lib:UnregisterFrame(regKey)
  local info = registrations[regKey]
  if not info then
    return
  end

  if lib.selected == info then
    lib:ClearSelection()
  end
  if info.overlay then
    info.overlay:Hide()
    SetOverlayBehind(info, info.overlay, false)
  end
  if info.previewing then
    info.previewing = false
    if info.OnPreview then
      info.OnPreview(false)
    end
  end

  registrations[regKey] = nil
  for index, key in ipairs(order) do
    if key == regKey then
      table.remove(order, index)
      break
    end
  end

  -- Its settings pages go with it, rather than drawing a registration that is gone.
  for index = #lib.pages, 1, -1 do
    local page = lib.pages[index]
    if page.libInfo == info then
      page:Hide()
      table.remove(lib.pages, index)
    end
  end

  RefreshPanel()
end

--- Re-applies the active layout to one registration, or to all of them.
-- Call this when the addon changed something behind the library's back.
function lib:Refresh(regKey)
  local key = ActiveLayoutKey()
  if not key then
    return
  end
  if regKey then
    local info = registrations[regKey]
    if info then
      ApplyOrRestore(info, info.storage[key])
    end
  else
    ApplyLayout()
  end
end

--- Folds the frame's current position and settings into the active layout.
-- Call this when the addon's own settings changed something, so that a layout
-- owning the frame takes the change on board instead of putting its own value
-- back the next time it is applied. A layout that does not own the frame is left
-- alone, so a player who never opted in is unaffected. A settings page showing
-- the frame is redrawn either way.
function lib:Capture(regKey)
  local info = registrations[regKey]
  if not info then
    return
  end

  -- A layout that is not using the frame keeps its look parked, and a change made
  -- elsewhere is no reason to disturb it.
  local entry = CurrentEntry(info)
  if IsActiveEntry(entry) then
    local fresh = CaptureEntry(info)
    local changed = false

    for _, field in ipairs({ "position", "settings" }) do
      for key, value in pairs(fresh[field]) do
        if not SameValue(entry[field][key], value) then
          entry[field][key] = CopyValue(value)
          changed = true
        end
      end
    end

    if changed and lib.sessionKey then
      -- Changed from under an open edit mode, so it is a change to be saved.
      MarkDirty()
      RefreshDialog()
    end
  end

  -- Whatever changed is on the frame now, and a settings page has to show it.
  RefreshPages()
end

--- Puts one frame back the way this edit mode session found it, the way
-- Blizzard's own Revert Changes button does for one of its systems. Everything
-- else on screen is left alone.
function lib:RevertFrame(regKey)
  local info = registrations[regKey]
  if not info or not lib.sessionKey then
    return
  end

  info.pending = info.revertPoint and CopyTable(info.revertPoint) or nil
  ApplyOrRestore(info, info.pending)

  RefreshPanel()
  RefreshOverlays()
  RefreshDialog()
  RefreshButtonStates()
end

--- Returns true while this edit mode session has changed the frame.
function lib:HasChanges(regKey)
  local info = registrations[regKey]
  return info ~= nil and HasChanges(info)
end

--- Lists the other layouts holding a look for this frame, for a dialog that
-- offers to copy one of them. Only layouts the player actually has are listed,
-- so another character's character layouts and any orphaned entry are left out,
-- and each is named as the edit mode manager names it.
-- @return array of { key = storage key, name = layout name }
function lib:GetStoredLayouts(regKey)
  local info = registrations[regKey]
  local layouts = IsSupported() and EditModeManagerFrame.layoutInfo
    and EditModeManagerFrame.layoutInfo.layouts
  if not info or not layouts then
    return {}
  end

  local activeKey = ActiveLayoutKey()
  local found = {}
  for _, layout in ipairs(layouts) do
    local key = IsWritableLayout(layout) and LayoutKey(layout) or nil
    if key and key ~= activeKey and info.storage[key] then
      found[#found + 1] = { key = key, name = layout.layoutName }
    end
  end
  return found
end

--- Puts another layout's stored look onto this frame, as a change to the layout
-- that owns it now. The copy is a change like any other: the save button lights
-- up and reverting undoes it. The source is left alone. Outside edit mode, from a
-- settings page, it goes through EditSetting and EditPosition instead, onto
-- whatever the frame is wearing.
function lib:CopyFrom(regKey, sourceKey)
  local info = registrations[regKey]
  if not info or not sourceKey then
    return
  end

  local source = info.storage[sourceKey]
  if not source then
    return
  end

  -- From a settings page, outside edit mode: onto whatever the frame is wearing,
  -- the way the addon's own settings change it.
  if not lib.sessionKey and info.EditSetting then
    EditThroughAddon(info, function() EditEntry(info, source) end)
    return
  end

  local entry = CurrentEntry(info)
  if not IsActiveEntry(entry) then
    return
  end

  -- Only the look is copied. Whether this layout is using it is this layout's
  -- business, so the inactive flag is left as it is.
  if source.position then
    entry.position = CopyTable(source.position)
  end
  if source.settings then
    entry.settings = CopyTable(source.settings)
  end

  ApplyEntry(info, entry)
  MarkDirty()
  RefreshDialog()
end

--- Draws the frame's settings rows into a frame of the addon's own, a settings
-- page say, so that they can be changed outside edit mode too. They are the rows
-- the edit mode dialog shows, built from the same descriptors. A change goes
-- through the registration's EditSetting and EditPosition, the way one from the
-- addon's own settings UI does, rather than into a layout. The revert row puts
-- back how the frame looked when the page was last opened.
-- @param regKey  the registration
-- @param parent  the frame to draw into
-- @param opener  optional, the frame whose showing counts as opening the page,
--                for rows the addon hides and shows again while the page is
--                open. Defaults to the frame returned.
-- @return a frame as wide as the dialog whose height follows its rows, for the
--         caller to anchor, or nil on a client without an edit mode
function lib:CreateSettingsFrame(regKey, parent, opener)
  local info = registrations[regKey]
  assert(info, MAJOR .. ": " .. tostring(regKey) .. " is not registered.")
  assert(type(info.EditSetting) == "function" and type(info.EditPosition) == "function",
    MAJOR .. ": a settings frame needs EditSetting and EditPosition in the registration.")
  if not IsSupported() then
    return nil
  end

  local page = CreateFrame("Frame", nil, parent)
  page:SetWidth(dialogWidth)
  page.rows = NewRowPools()
  page.libPage = true
  page.libInfo = info

  -- Opening sets the point Revert Changes goes back to. Showing the rows only
  -- draws them, so rows hidden and shown again keep that point.
  local function Open()
    page.libSnapshot = CaptureEntry(info)
    RefreshButtonStates()
  end
  -- Set before the hook, because setting would replace it when the page is its
  -- own opener.
  page:SetScript("OnShow", RefreshPage)
  opener = opener or page
  opener:HookScript("OnShow", Open)

  -- Created on a page that is already up gets no OnShow for being created.
  if opener:IsVisible() then
    Open()
  end
  RefreshPage(page)

  lib.pages[#lib.pages + 1] = page
  return page
end

--- Returns true while the frame's position and settings are owned by the layout.
function lib:IsManaged(regKey)
  local info = registrations[regKey]
  return info ~= nil and IsManaged(info)
end

InstallHooks()
