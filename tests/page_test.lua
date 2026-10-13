-- The rows drawn onto a settings page of the addon's own: they are there, a
-- change goes through the addon to whatever the frame is wearing, Revert Changes
-- goes back to how the page was opened, a change made elsewhere redraws the page
-- but a change made on it does not, and Copy From, Reset Position and a colour's
-- own button on the colour picker work there too. Nothing on the page is an edit
-- mode change.

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(here .. "/stubs.lua")
local Stub, slot = STUB.Stub, STUB.slot

--------------------------------------------------------------------------------
-- A stubbed edit mode manager, never entered
--------------------------------------------------------------------------------

EditModeManagerFrame = {
  layoutInfo = {
    activeLayout = 2,
    layouts = {
      { layoutName = "Modern",  layoutType = 0 },
      { layoutName = "Travel",  layoutType = 1 },
      { layoutName = "Raiding", layoutType = 1 },
    },
  },
  hasActiveChanges = false,
}

function EditModeManagerFrame:GetActiveLayoutInfo()
  return self.layoutInfo.layouts[self.layoutInfo.activeLayout]
end
function EditModeManagerFrame:SetHasActiveChanges(v) self.hasActiveChanges = v and true or false end

UnitName = function() return "Tester" end
GetRealmName = function() return "Realm" end

--------------------------------------------------------------------------------

local LLS = STUB.LoadLibrary()

-- The addon: its own settings, and a layout's overrides on top of them while the
-- layout owns the frame, exactly like InFlight's look table.
local own = { p = "BOTTOM", rp = "TOP", x = 0, y = -170, width = 300, spark = true, texture = "Plain",
  barcolor = { r = 0.5, g = 0.5, b = 0.8, a = 0.6 }, fontcolor = { r = 1, g = 1, b = 1, a = 1 } }
local over = {}
local function Get(key)
  local value = over[key]
  if value == nil then value = own[key] end
  return value
end

-- Where a change from the addon's own settings UI goes.
local function Edit(key, value)
  if LLS:IsManaged("Bar") then
    over[key] = value
  else
    own[key] = value
    over[key] = nil
  end
end

local hovered = {}
local picking = {}

local storage = {
  ["1:Raiding"] = {
    position = { point = "TOP", relativePoint = "TOP", x = 40, y = -8 },
    settings = { width = 555, spark = false },
  },
}

local barFrame = Stub()
function barFrame:IsMouseEnabled() return true end
function barFrame:EnableMouse() end
function barFrame:GetFrameStrata() return "MEDIUM" end

local registration = {
  GetFrame = function() return barFrame end,
  displayName = "TestBar",
  storage = storage,
  settings = {
    { key = "width", name = "Width", type = "slider", minValue = 40, maxValue = 1000, stepSize = 5 },
    { key = "spark", name = "Spark", type = "checkbox" },
    -- Records what it is asked to try on, "off" for giving it up.
    { key = "texture", name = "Texture", type = "dropdown", tooltip = "What fills the bar.",
      options = { { value = "Plain", text = "Plain" }, { separator = true }, { value = "Shiny", text = "Shiny" } },
      OnHover = function(value) hovered[#hovered + 1] = value or "off" end },
    { key = "barcolor", name = "Bar Color", type = "color",
      colorButton = { text = "White", tooltip = "Untinted.", color = { r = 1, g = 1, b = 1, a = 1 } },
      OnPicker = function(open) picking[#picking + 1] = open end },
    { key = "fontcolor", name = "Font Color", type = "color", sameRow = true },
    { type = "revert" },
    { type = "resetPosition" },
    { type = "actions", name = "Copy From",
      actions = function()
        local sources = {}
        for _, layout in ipairs(LLS:GetStoredLayouts("Bar")) do
          sources[#sources + 1] = { text = layout.name,
            OnClick = function() LLS:CopyFrom("Bar", layout.key) end }
        end
        return sources
      end },
  },
  RestoreOwnSettings = function() for key in pairs(over) do over[key] = nil end end,
  GetSetting = Get,
  SetSetting = function(key, value) over[key] = value end,
  EditSetting = Edit,
  GetPosition = function() return Get("p"), Get("rp"), Get("x"), Get("y") end,
  SetPosition = function(p, rp, x, y) over.p, over.rp, over.x, over.y = p, rp, x, y end,
  EditPosition = function(p, rp, x, y) Edit("p", p); Edit("rp", rp); Edit("x", x); Edit("y", y) end,
  GetDefaultPosition = function() return "BOTTOM", "TOP", 0, -170 end,
}
LLS:RegisterFrame("Bar", registration)

local failures, count = 0, 0
local function Check(label, ok)
  count = count + 1
  if ok then print("  ok:   " .. label)
  else failures = failures + 1; print("  FAIL: " .. label) end
end

--------------------------------------------------------------------------------

print("== a page needs somewhere to send its changes ==")
LLS:RegisterFrame("NoEdit", {
  GetFrame = function() return Stub() end,
  displayName = "NoEdit",
  storage = {},
  GetPosition = function() return "CENTER", "CENTER", 0, 0 end,
  SetPosition = function() end,
})
Check("a registration without EditSetting is refused a page",
  not pcall(LLS.CreateSettingsFrame, LLS, "NoEdit", Stub()))
LLS:UnregisterFrame("NoEdit")

print("== the page ==")
local page = LLS:CreateSettingsFrame("Bar", Stub())
Check("nothing is drawn before the page is shown", (page.rows.slider.used or 0) == 0)
page:Show()
Check("the rows are drawn once it is", page.rows.slider.used == 1 and page.rows.checkbox.used == 1
  and page.rows.revert.used == 1 and page.rows.resetPosition.used == 1)
local slider = page.rows.slider[1]
local checkbox = page.rows.checkbox[1]
local revert = page.rows.revert[1]
local reset = page.rows.resetPosition[1]
Check("with nothing to revert yet", not revert:IsEnabled())

-- Every redraw sets the page's height, so counting those counts the redraws.
local redraws = 0
local SetHeight = page.SetHeight
page.SetHeight = function(self, height) redraws = redraws + 1; return SetHeight(self, height) end

print("== a change goes to the addon's own settings ==")
slot(slider.Slider).callback(slider, 500)
Check("the width is the user's own now", own.width == 500 and over.width == nil)
Check("revert lights up", revert:IsEnabled())
Check("and edit mode knows nothing of it", not EditModeManagerFrame.hasActiveChanges)
Check("the slider was not redrawn under the mouse", redraws == 0)
checkbox:OnCheckButtonClick()
Check("the checkbox too", own.spark == false)

print("== Revert Changes goes back to how the page was opened ==")
revert:GetScript("OnClick")()
Check("the width is back", own.width == 300)
Check("and the checkbox", own.spark == true)
Check("so nothing is left to revert", not revert:IsEnabled())

print("== a change made elsewhere redraws the page ==")
redraws = 0
own.width = 350                          -- from the addon's own settings menu
LLS:Capture("Bar")
Check("Capture redraws it", redraws == 1)
Check("and the slider shows the new width", slider.libLast == 350)
own.width = 300
LLS:Capture("Bar")

print("== while a layout owns the frame, a change goes to the layout ==")
LLS:SetManaged("Bar", true)
Check("Travel owns the bar", storage["1:Travel"] and not storage["1:Travel"].inactive)
slot(slider.Slider).callback(slider, 600)
Check("the layout takes the width", over.width == 600 and storage["1:Travel"].settings.width == 600)
Check("the user's own stays", own.width == 300)
revert:GetScript("OnClick")()
Check("revert puts the layout's width back", over.width == 300 and storage["1:Travel"].settings.width == 300)
slot(slider.Slider).callback(slider, 650)
LLS:SetManaged("Bar", false)
Check("unticking redraws the page with the user's own width", slider.libLast == 300)

print("== Copy From, outside edit mode ==")
local copyFrom = page.rows.actions[1]
Check("Raiding is offered", copyFrom.Dropdown:IsEnabled())
LLS:CopyFrom("Bar", "1:Raiding")
Check("its look lands on the user's own settings", own.width == 555 and own.spark == false and own.p == "TOP")
Check("with no override left pinned", next(over) == nil)
Check("and Raiding untouched", storage["1:Raiding"].settings.width == 555 and storage["1:Raiding"].position.x == 40)

print("== Reset Position ==")
Check("the bar is off its default spot", reset:IsEnabled())
reset:GetScript("OnClick")()
Check("it goes back", own.p == "BOTTOM" and own.x == 0 and own.y == -170)
Check("and the button greys out", not reset:IsEnabled())

print("== an option is tried on while the mouse rests on it ==")
local dropdown = page.rows.dropdown[1]
local radios, dividers = {}, 0
local root = {
  CreateDivider = function() dividers = dividers + 1 end,
  CreateRadio = function(_, text, isSelected, setSelected, value)
    local radio = { text = text, setSelected = setSelected, value = value }
    function radio:HookOnEnter(fn) self.enter = fn end
    function radio:HookOnLeave(fn) self.leave = fn end
    radios[#radios + 1] = radio
    return radio
  end,
}
slot(dropdown.Dropdown).generator(dropdown.Dropdown, root)
Check("every option is offered", #radios == 2 and radios[2].text == "Shiny")
Check("with a divider where the options ask for one", dividers == 1)
radios[2].enter()
Check("resting on one tries it on", hovered[#hovered] == "Shiny")
radios[2].leave()
Check("moving off it gives it up", hovered[#hovered] == "off")
Check("and nothing was changed by it", Get("texture") == "Plain")
radios[2].enter()
radios[2].setSelected(radios[2].value)
slot(dropdown.Dropdown).callbacks.OnMenuClose()
Check("closing the menu gives it up too", hovered[#hovered] == "off")
Check("while what was picked stays picked", Get("texture") == "Shiny")

print("== a dropdown's tooltip follows its open menu ==")
local tip = STUB.tip
local watcher
for _, frame in ipairs(STUB.frames) do
  if slot(frame).scripts.OnUpdate then watcher = frame end
end
local overMenu = false
local menu = Stub()
function menu:IsMouseOver() return overMenu end

slot(dropdown).mouseOver = true
dropdown:GetScript("OnEnter")(dropdown)
Check("hovering the row shows its tooltip", tip.shown and tip.owner == dropdown)
dropdown.Dropdown.menu = menu
slot(dropdown.Dropdown).callbacks.OnMenuOpen()
Check("opening the menu starts watching it", watcher and watcher:IsShown())

slot(dropdown).mouseOver, overMenu = false, true
dropdown:GetScript("OnLeave")(dropdown)
Check("moving from the row into the menu keeps it", tip.shown)
overMenu = false
watcher:GetScript("OnUpdate")(watcher)
Check("leaving the menu for elsewhere puts it away", not tip.shown)
overMenu = true
watcher:GetScript("OnUpdate")(watcher)
Check("coming back over the menu shows it again", tip.shown and tip.owner == dropdown)

dropdown.Dropdown.menu = false
slot(dropdown.Dropdown).callbacks.OnMenuClose()
watcher:GetScript("OnUpdate")(watcher)
Check("a closed menu is no longer watched", not watcher:IsShown())
dropdown:GetScript("OnLeave")(dropdown)

print("== a colour's own button on the colour picker ==")
local barColor, fontColor = page.rows.color[1], page.rows.color[2]
barColor.libOpenPicker()
local button = LLS.colorButton
Check("opening a colour with one shows it", button and button:IsShown() and button:GetText() == "White")
button:GetScript("OnClick")(button)
local picked = Get("barcolor")
Check("pressing it picks its colour", picked.r == 1 and picked.g == 1 and picked.b == 1 and picked.a == 1)
ColorPickerFrame:SetupColorPickerAndShow({})
Check("another addon setting the picker up hides it", not button:IsShown())
barColor.libOpenPicker()
slot(ColorPickerFrame).scripts.OnHide(ColorPickerFrame)
Check("and so does the picker closing", not button:IsShown())
fontColor.libOpenPicker()
Check("a colour without one leaves it hidden", not button:IsShown())

print("== a colour is told when its picker opens and goes ==")
picking = {}
barColor.libOpenPicker()
Check("opening it says so", #picking == 1 and picking[1] == true)
slot(ColorPickerFrame).scripts.OnHide(ColorPickerFrame)
Check("and closing it", #picking == 2 and picking[2] == false)
barColor.libOpenPicker()
fontColor.libOpenPicker()
Check("as does another colour taking the picker over", #picking == 4 and picking[4] == false)
slot(ColorPickerFrame).scripts.OnHide(ColorPickerFrame)
Check("after which closing is not news to it", #picking == 4)

print("== opening the page again starts over ==")
page:Hide()
page:Show()
Check("what it was opened with is the new starting point", not revert:IsEnabled())

print("== rows hidden and shown again inside an open page ==")
local opener = Stub()
opener:Show()
local openedWith = own.width
local inner = LLS:CreateSettingsFrame("Bar", opener, opener)
inner:Show()
local innerSlider, innerRevert = inner.rows.slider[1], inner.rows.revert[1]
slot(innerSlider.Slider).callback(innerSlider, 700)
inner:Hide()
inner:Show()
Check("keep the point Revert goes back to", innerRevert:IsEnabled())
innerRevert:GetScript("OnClick")()
Check("which is still how the page was opened", own.width == openedWith)
slot(innerSlider.Slider).callback(innerSlider, 710)
opener:Hide()
opener:Show()
Check("while opening the page again moves it", not innerRevert:IsEnabled())

print("== unregistering takes the pages with it ==")
LLS:UnregisterFrame("Bar")
Check("none left to redraw", #LLS.pages == 0)
Check("and none left on screen", not page:IsShown() and not inner:IsShown())

print("")
print(string.format("%d checks, %s", count,
  failures == 0 and "ALL PASSED" or (failures .. " FAILED")))

os.exit(failures == 0 and 0 or 1)
