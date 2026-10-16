# LibLayoutSettings

A World of Warcraft addon library that lets an addon frame take part in Blizzard's HUD edit mode, with its position and its settings remembered per edit mode layout.

## Why a library and not a Blizzard system

Blizzard's layouts are stored client side, and every entry in them is typed by the `Enum.EditModeSystem` enum, which only knows Blizzard's own systems. A foreign value cannot survive `C_EditMode.SaveLayouts`, and `EditModeManagerFrame` strips unknown systems out of every saved layout on login regardless.

So this library never touches Blizzard's layout data. It only reads which layout is active and keeps its own copy of position and settings, per layout, in the addon's saved variables.

## What it provides

- A panel next to the edit mode manager with one checkbox per registered frame, which shows or hides the frame in edit mode the way Blizzard's own checkboxes there do, scrolling rather than growing once enough addons have registered.
- Blizzard's own selection glow on the frame while edit mode is active, complete with label, mouseover highlight and click to edit.
- Dragging the frame by that glow, and nudging it a pixel at a time with the arrow keys, ten at a time with shift held.
- A settings dialog of slider, checkbox, dropdown, colour, text, button, separator, revert, reset position, action and layout specific rows, scrolling rather than growing past 90% of the screen's height, unless the rows would only overrun that by 5% of it or less, when they are shown whole rather than scrolled for the last few pixels.
- Editing in edit mode whatever the frame is wearing: the active layout's own look while the layout owns the frame, and the addon's own settings while no layout does.
- Copying one layout's stored look onto another.
- The same rows drawn onto a settings page of the addon's own, for changing the frame outside edit mode.
- Save, cancel and revert semantics that match Blizzard's, including creating a new layout when saving while a preset layout is active, and saving without one when only the addon's own settings changed.

Frame snapping and magnetism are deliberately left out.

## Availability

It runs on retail, WoW Forever, Mists of Pandaria Classic, TBC Anniversary and Classic Era. That was checked against each client's own UI source rather than assumed: every edit mode function, template and event the library uses is present on all five, and every Blizzard function whose behaviour it relies on, such as `MakeNewLayout` reverting before it creates, is identical to retail's.

Where `EditModeManagerFrame` is missing, `RegisterFrame` stores the registration and does nothing else, so no version gating is needed in the consuming addon.

## Usage

```lua
local LLS = LibStub("LibLayoutSettings-1.0")

LLS:RegisterFrame("MyBar", {
  frame       = myBar,                       -- or GetFrame = function() ... end
  displayName = "My Addon",
  storage     = MyAddonDB.editModeLayouts,   -- a table in the addon's saved variables

  settings = {
    { type = "layoutSpecific", name = "Layout Specific Settings" },
    { key = "width",   name = "Width",   type = "slider", minValue = 40, maxValue = 1000, stepSize = 5 },
    { key = "spark",   name = "Spark",   type = "checkbox" },
    { key = "texture", name = "Texture", type = "dropdown", options = function() ... end },
  },

  -- what the frame is wearing, and putting a layout's value on it as an override
  GetSetting  = function(key) return look[key] end,
  SetSetting  = function(key, value) override[key] = value end,
  GetPosition = function() return look.p, look.rp, look.x, look.y end,
  SetPosition = function(point, relativePoint, x, y) ... end,

  -- a change to the addon's own settings, see "The addon's own settings" below
  EditSetting  = function(key, value) MyAddon:SetSetting(key, value) end,
  EditPosition = function(point, relativePoint, x, y) ... end,
  RestoreOwnSettings = function() MyAddon:ClearOverrides() end,

  -- optional, what a resetPosition row puts back and measures against
  GetDefaultPosition = function() return defaults.p, defaults.rp, defaults.x, defaults.y end,

  -- optional, where the panel checkbox is kept, see "Showing the frame in edit mode"
  IsShownInEditMode  = function() return not MyAddonDB.editModeHidden end,
  SetShownInEditMode = function(shown) MyAddonDB.editModeHidden = not shown or nil end,

  OnChanged     = function() MyAddon:UpdateLook() end,  -- optional, after any change
  OnPreview     = function(shown) ... end,              -- optional, show a dummy while editing

  selectionInsets    = { left = 8, right = 8, top = 8, bottom = 8 },  -- optional, defaults to 6
  showSelectionLabel = false,                                         -- optional, defaults to true
  selectionBehind    = "BACKGROUND",                                  -- optional, see below
})
```

`GetFrame` is for frames that are only built on demand. It is called the first time the frame actually has to be shown in edit mode.

`selectionBehind` draws the glow behind the frame **while it is selected**, instead of over it. Blizzard's glow sits on top, which suits a frame with nothing to read on it, but its centre fill covers whatever a frame is showing - unhelpful exactly when the settings dialog is open and you are judging the change. Merely highlighted is left on top, since that is how a frame says it can be edited.

Pass `true` to drop one strata below the frame, or a strata name where the frame has children of its own further down - stepping down one would land level with those. While behind, the frame would swallow the clicks meant for the glow, so its mouse is turned off until it is deselected. That also keeps the addon's own click handling out of the way while editing.

`showSelectionLabel = false` suppresses the system name that Blizzard writes across the middle of a selected frame. Pass it for frames that carry text of their own, where the name would sit on top of that text. The name is still shown on the mouseover tooltip and as the settings dialog title.

### Setting descriptors

| Field | Applies to | Meaning |
| --- | --- | --- |
| `key` | all | passed back to `GetSetting` and `SetSetting` |
| `name` | all | row label |
| `type` | all | `"slider"`, `"checkbox"`, `"dropdown"`, `"color"`, `"text"`, `"separator"`, `"button"`, `"revert"`, `"resetPosition"`, `"actions"` or `"layoutSpecific"` |
| `sameRow` | all | put this in the second column of the row before it, rather than on one of its own |
| `padTop` | all | extra space above this row, in pixels. A `revert` row takes 12 by default, matching the gap Blizzard leaves above its own button block |
| `text`, `OnClick` | button | label, and what pressing it does. `OnClick` is passed the registration |
| `IsDisabled` | all | optional predicate, greys the row out when it returns true. A button's is asked again after every change, as Revert's state is, so it can follow the frame |
| `tooltip` | all | mouseover text, or a function returning it. Titled with `name`, or `text` for a button, or the label the library put on the row |
| `refreshOnChange` | checkbox, dropdown | redraw the dialog after this changes, so rows it greys out follow. Never put it on a slider, whose value changes on every frame of a drag |
| `minValue`, `maxValue`, `stepSize` | slider | range, `stepSize` defaults to 1 |
| `formatter` | slider | value formatter, as in Blizzard's edit mode |
| `options` | dropdown | array of `{value =, text =}`, or a function returning one. An entry of `{separator = true}` draws a divider |
| `OnHover` | dropdown | optional, called with an option's value while the mouse rests on it, and with nil once it moves off or the menu closes, picked or not. For trying an option on the frame the way the barber shop does. The setting is not changed by it |
| `actions` | actions | array of `{text =, OnClick =}`, or a function returning one. An entry of `{separator = true}` draws a divider. `OnClick` is passed the registration |
| `placeholder` | actions | what the button reads when nothing has been picked, defaults to `name` |
| `hasOpacity` | color | show the opacity slider, defaults to true |
| `colorButton` | color | optional `{text =, tooltip =, color = {r, g, b, a}}`, a button on the colour picker that picks that colour at a press, with an optional tooltip |
| `OnPicker` | color | optional, called with true once the colour picker has opened for this setting, and with false once it has gone, picked, cancelled or taken over by another addon. For showing the frame in a state where this colour can be judged |
| `maxLetters` | text | cap on the length, 0 or absent for none |
| `trim` | text | strip surrounding whitespace on commit |

Blizzard's edit mode has only three kinds of row - `Enum.EditModeSettingDisplayType` is `Dropdown`, `Checkbox` and `Slider` - so those three reuse its own templates and look exactly like its dialogs. A `color` row is built here out of `ColorSwatchTemplate` and `ColorPickerFrame`, and a `text` row out of `TooltipBackdropTemplate`, which is how `StaticPopup1EditBox` is dressed - the same pieces Blizzard uses for its own colour swatches and text fields.

A `text` row reports every keystroke, so the addon can show the change as it is typed, and Escape restores what was there. `trim` is applied only when the box is left or the value confirmed, never while typing - trimming per keystroke would mean a leading space could never be typed, because it would vanish as it was hit. Set `trim` here whenever the addon's own settings trim, or the two will disagree about what was typed.

A `color` setting's value is a table `{r, g, b, a}`. Table-valued settings are deep copied whenever they cross between the addon and a layout, so a layout's stored colour is never the same table the addon is rendering from. Without that every layout would show whichever colour was picked last.

A `colorButton` sits in the picker's free space, above the hex box on retail and below the swatch on the classic picker. It picks through the picker's own controls, so the swatch follows and Cancel still puts back the colour the picker opened with. The picker is shared by every addon, so the button is shown only while a picker this library opened asks for it.

Separators, buttons and the `layoutSpecific` row are entries in the same `settings` list, so they can be ordered freely against the settings. They have no `key` and are skipped wherever values are read or written.

A `tooltip` is read at hover time rather than when the dialog is built, so a function may return different text as the state changes. Rows are wired for it once, when they are created, and a row that is moused over is also a place the dialog can be dragged from, so mouse-enabling them costs nothing.

There is one tooltip per **row**, never one per widget. A label and the control beside it describe the same setting, so hovering either produces the same tooltip in the same place: the row owns it, and everything on it does nothing but report which row the mouse is on. That means everything, however deep - a slider row's control is `MinimalSliderWithSteppersTemplate`, and what the pointer actually lands on is the slider and the stepper buttons inside it, which take the mouse without passing it up - so every already-hoverable descendant of a row is wired when the row is built. Their mouse state is left as it was: switching it on for a frame built without it would put that frame in the way of clicks meant for something else. It appears off the right edge of the dialog, level with the row, so that it never covers the control you are judging the change by, or, where the widest of the dialog's tooltips would not fit between the dialog and the right edge of the screen, all of them off the left edge, so that they do not switch sides from one row to the next. The widths are measured once whenever the rows are drawn, by showing each one in turn before anything is drawn. A tooltip is not re-anchored while the mouse travels along the row, so it stays put rather than jumping as you move from the label to the control. Two rows sharing a line get their tooltips at the same height, one for each. A dropdown's open menu counts as part of its row: the tooltip stays while the mouse is over the menu, goes when it is over neither the row nor the menu, and comes back when it returns. The tooltip clamps itself to the screen, so where it fits on neither side it still shows.

The tooltip is the library's own, `LibLayoutSettingsTooltip`, rather than `GameTooltip`, which is anchored to whatever it was shown for last, and which in combat could not always be anchored to the dialog: `SetPoint` failed with an anchor family connection. This one is only ever anchored here, and no tooltip addon hooks it, so measuring in it goes unnoticed. The button a `colorButton` puts on the colour picker uses it too.

A `revert` entry needs nothing but `{ type = "revert" }`. The library labels it with Blizzard's own `HUD_EDIT_MODE_REVERT_CHANGES`, reverts this frame when pressed, and enables it only while the frame actually differs - position and every setting included, whether they were changed from this dialog, from the addon's own settings, or by dragging the frame.

It also counts whether the layout owns the frame, and the session's changes to the addon's own settings, and reverting puts all of it back. The state is updated in place rather than by redrawing the dialog, so it stays correct during a slider drag. Put one wherever Blizzard puts theirs, above the closing divider.

A `layoutSpecific` entry needs nothing but `{ type = "layoutSpecific", name = ... }`, where `name` defaults to "Layout Specific". It is a checkbox, ticked while the active layout owns the frame, and ticking or unticking it gives the frame to the layout or takes it away, see "The addon's own settings" below. In the edit mode dialog that is a change like any other, held back until Save, and on a settings page it takes effect at once. It greys itself out where no layout can be given the frame: under an override layout, and on a preset outside edit mode. Put it first, since it decides what every row below it changes.

An `actions` row is a dropdown that *does* something rather than holding a value: the entry you pick runs its `OnClick` and the button goes on reading its placeholder, because what you chose happened rather than became true. It has no `key` and is skipped wherever values are read or written, and it greys itself out when the list comes back empty. Build the list with a function rather than a table whenever it can change while the dialog is open.

A `resetPosition` entry likewise needs nothing but `{ type = "resetPosition" }`, and works only where the registration provides `GetDefaultPosition`. The library labels it with Blizzard's own `HUD_EDIT_MODE_RESET_POSITION`, puts the frame back to that position when pressed, and enables it only while the frame is somewhere else - leaving every other setting alone. Without `GetDefaultPosition` there is nothing to put back, so the row stays greyed out. Blizzard places its own below the closing divider, and so does this.

### Moving the frame

Dragging it by the selection glow is one way. The other is the arrow keys, which move the selected frame one pixel at a time, ten with shift held, exactly as Blizzard's own systems do. The keys are taken on the settings dialog, which is what Blizzard does too and is on screen precisely while something is selected. Anything the library does not act on is passed straight on, so Escape still leaves edit mode and typing still reaches whatever wanted it; a text row with focus takes the arrow keys first, so they still walk the cursor along what is being typed. In combat an addon may not decide which keys go on, so there every key does, the arrows included, and nudging waits for the fight to end.

Every route ends in the same place: `SetPosition`, the session's pending entry for whatever the frame is wearing, and the edit mode Save button lighting up.

### Showing the frame in edit mode

The panel's checkbox shows or hides the frame in edit mode, its glow, its preview and its dialog, and nothing else, the way Blizzard's own checkboxes on that panel do. A hidden frame is still whatever the layout makes it. It starts out shown. Where the registration provides `IsShownInEditMode` and `SetShownInEditMode`, the addon keeps the choice, account wide is what Blizzard does with its own; without them it lasts until the next reload. `LLS:SetShownInEditMode(key, shown)` and `LLS:IsShownInEditMode(key)` do the same from the addon's own UI.

### Sharing the edit mode screen

Nothing owns the edit mode screen, and more than one addon may be adding frames to it. Taking a selection therefore means asking whoever else is on the screen to put their dialog away, and standing down in turn when they say the same.

Blizzard's manager is asked through its own `ClearSelectedSystem`, which its settings dialog listens to; that call is also the one signal every third-party library sends, so the library hooks it and drops its own selection when anyone else makes it. On top of that it fires and answers `EditModeExternal.hideDialog`, which is [LibEditMode](https://github.com/p3lim-wow/LibEditMode)'s convention and the closest thing to a standard there is. Anything following either will not end up with two dialogs open at once.

Except in combat: there Blizzard runs `ClearSelectedSystem` as the addon calling it rather than through its secure delegate, and highlighting its systems again touches action bars, which an addon may not do then. So in combat the library does not call it, and does not take a selection either while one of Blizzard's systems is selected, since Blizzard's dialog, left attached, would take the changes made in this one.

### Handing the frame back

A layout that does **not** own the frame calls `RestoreOwnSettings`. Without that the frame would keep whatever the last owning layout imposed, so a layout the player never opted in would silently inherit another layout's look.

The addon is expected to keep its own settings as they are outside any layout, with a layout's values laid over them as overrides by `SetSetting` and `SetPosition`, and to drop every override here. Reverting or cancelling a session that had only just taken ownership hands the frame back the same way, rather than pinning on the values the session happened to open with. A button that drops a layout's own look in favour of the addon's settings is then a single call, `LLS:SetManaged(key, false)`, which hands the frame back and parks the layout's look in case the player changes their mind.

### The addon's own settings

A frame either belongs to the active layout, which keeps its own look for it, or wears the addon's own settings, which every layout not owning it shares. The `layoutSpecific` row switches between the two, and edit mode changes whichever the frame is wearing. That way a player with a single layout can move the frame in edit mode without ever hearing of layout specific settings, and a player who does want them ticks one box.

While no layout owns the frame, a change in edit mode is still held back until Save, like every change there: it goes on the frame as an override, through `SetSetting` and `SetPosition` as a layout's would, and Revert, Revert All and leaving without saving drop it again. Save hands each changed value to the addon through `EditSetting` and `EditPosition`, the way a change from its own settings UI goes, and then puts back on the frame what it should be wearing: through `RestoreOwnSettings` the addon's own settings, now holding those values, or the layout's look. While those run, `LLS:IsManaged` and `LLS:IsEditing` return false, so that the change lands in the addon's own settings. Hence `EditSetting`, `EditPosition` and `RestoreOwnSettings` are required.

Giving a layout the frame in edit mode starts it out with what the frame is wearing, edits to the addon's own settings included. Those were made for the frame as it is, which is the layout's from then on, so they become the layout's and are no longer changes to the addon's own settings. Taking the frame away again before anything else changed is as if neither had happened. Once the layout's look has been changed, taking the frame away parks that look, as it would after Save.

A change the addon makes itself while edit mode is open, from its own settings UI or a `button` row, belongs to the session too. `LLS:IsEditing()` says when that is: the addon puts the change on the frame as an override, the way `SetSetting` does, and calls `Capture`, and the library keeps it for whatever the frame is wearing until Save.

### Saving on a preset

On a preset layout Blizzard's Save always asks for a new layout, because the preset itself is never written. Changes to the addon's own settings belong to no layout, so when they are all there is to save, the library lays a button of its own over Save, and another over Save and Exit in the dialog Blizzard shows on leaving or switching layouts with unsaved changes. They look like Blizzard's buttons, and save the addon's own settings without a layout. Save and Exit then presses the dialog's Exit, or Switch, as Blizzard's own does once it has saved, except in combat, where leaving edit mode from an addon's code could be blocked: there it saves, and the dialog stays for the player to leave. As soon as the layout or any of Blizzard's own systems has a change too, the buttons step aside and Blizzard's Save makes its new layout, which takes the layout's changes along while the addon's own settings are saved as they are.

Blizzard's buttons cannot simply be told otherwise: they were handed their click handlers as closures when `Blizzard_EditMode` loaded, and replacing those would taint edit mode. The library's own buttons are plain ones, so that they can be shown and hidden in combat too.

### Storage

Entries are keyed by layout type and name, with the character folded into character layout keys so that two characters may each own a layout of the same name:

```lua
storage["1:Raiding"] = {
  position = { point = "BOTTOM", relativePoint = "TOP", x = 0, y = -170 },
  settings = { width = 300, spark = true },
}
```

An entry in use is what the `layoutSpecific` row reflects. Taking the frame away does not delete the entry but marks it `inactive = true`, so the layout keeps its look parked and giving the frame back brings it back rather than capturing whatever the frame happens to be wearing by then. A layout with no entry in use hands the frame back through `RestoreOwnSettings`, as described above.

In edit mode, giving the layout the frame or taking it away is a change like any other: it lights up Save, and Revert, Revert All and leaving without saving undo it. Taking the frame away with unsaved edits parks them along with the look, so Save still stores them and reverting still drops them. Outside edit mode, from a settings page or the addon's own settings, `SetManaged` takes effect at once, as there is no Save to wait for.

Override layouts, the ones the game forces on the player, are never written to. While one is active the `layoutSpecific` row is greyed out and the frame is left wearing whatever the layout before it set.

Preset layouts are read only, as they are for Blizzard's own systems. During an edit mode session a preset can be given the frame and its look edited, but saving makes a new layout: both go to it and the preset is never written. Outside edit mode `CanManage` is false on a preset and `SetManaged` refuses, because there is no session to carry the change into a new layout. Any entry left over for a preset from before this was enforced is dropped on registration. An *imported* layout is built from a string that carries nothing of this library's, so it starts out owning nothing rather than inheriting the edits that happened to be open at the time, and the addon's own settings drop their unsaved edits along with everything else.

## API

| Function | Purpose |
| --- | --- |
| `LLS:IsSupported()` | whether this client has an edit mode |
| `LLS:CanManage()` | whether the active layout is one a frame can be given to, false under an override layout and, outside edit mode, under a preset |
| `LLS:IsPresetActive()` | whether one of Blizzard's preset layouts is active, to tell the player why `CanManage` is false |
| `LLS:RegisterFrame(key, info)` | register a frame, see above |
| `LLS:UnregisterFrame(key)` | remove a registration |
| `LLS:Refresh([key])` | re-apply the active layout, after changing something behind the library's back |
| `LLS:Capture(key)` | fold the frame's current state into what it is wearing, after the addon's own settings changed something |
| `LLS:RevertFrame(key)` | put one frame back the way the session found it, done for you by a `revert` row |
| `LLS:HasChanges(key)` | whether this session has changed the frame, whether the layout owns it, or the addon's own settings |
| `LLS:IsManaged(key)` | whether the active layout owns this frame, in edit mode as the session holds it, saved or not |
| `LLS:IsEditing()` | whether edit mode is open and holding changes back until Save, see "The addon's own settings" |
| `LLS:IsShownInEditMode(key)` | whether the frame shows in edit mode, as the panel checkbox has it |
| `LLS:SetShownInEditMode(key, shown)` | show or hide the frame in edit mode, as the panel checkbox does |
| `LLS:GetActiveLayoutName()` | the active layout's name, for naming it in your own UI |
| `LLS:GetStoredLayouts(key)` | the other layouts holding a look for this frame, as `{key =, name =}` |
| `LLS:CopyFrom(key, sourceKey)` | put another layout's stored look onto this frame |
| `LLS:CreateSettingsFrame(key, parent[, opener])` | draw the frame's rows onto a settings page of your own, see below |
| `LLS:SelectFrame(key)` | open the settings dialog for a frame, as clicking its glow does |
| `LLS:ClearSelection()` | close it again |
| `LLS:SetManaged(key, managed)` | give the active layout the frame or take it away, as the `layoutSpecific` row does |
| `LLS:ShowColorPicker(picker)` | open the colour picker as a `color` row does, see below |
| `LLS:CreateScrollFrame(parent)` | a scroll frame with the scroll bar of Blizzard's settings window on every client, `MinimalScrollBar`, shown only when there is something to scroll. The Classic clients' `ScrollFrameTemplate` gives the older one. Set its points and scroll child as usual |
| `LLS:GetButtonLayout()` | where the two columns of rows start, from the left of the frame they are drawn into, and the width and height of a button row, for lining buttons of the addon's own up with them |

`SelectFrame`, `ClearSelection`, `SetManaged` and `SetShownInEditMode` are what the glow and the rows call, exposed so an addon can drive the same thing from its own UI. Anything else on the library table is internal.

### The colour picker

`LLS:ShowColorPicker{color =, OnPick =, hasOpacity =, colorButton =, OnPicker =}` opens Blizzard's colour picker the way a `color` row does, for an addon that also offers the colour somewhere of its own, a context menu say, so that both show the same picker, its button included. `OnPick(r, g, b, a)` is called with every change, and with the colour the picker opened with on cancel. `hasOpacity`, `colorButton` and `OnPicker` are as on a `color` setting. It needs no edit mode, so it works on every client.

### Keeping the addon's own settings working

An addon that also lets the player change these settings elsewhere, from a context menu say, has to call `LLS:Capture(key)` afterwards. Otherwise the layout owning the frame puts its own value back the next time it is applied, and the change appears to be silently discarded.

Outside edit mode `Capture` only touches a layout that already owns the frame, so a player who never ticked a checkbox is unaffected and the addon's settings keep behaving exactly as they did before. Layouts that were deliberately given their own settings keep them. In edit mode it holds the change back for Save, for the layout or for the addon's own settings, see `LLS:IsEditing`. It also redraws a settings page showing the frame, so call it after a change of the addon's own whether or not a layout owns the frame.

### A settings page

`LLS:CreateSettingsFrame(key, parent[, opener])` draws the rows the edit mode dialog shows onto a frame of your own, a page in the game's AddOns settings say. It returns a frame as wide as the dialog, whose height follows its rows, for you to anchor. The rows are drawn when it is first shown and whenever `Capture` reports a change, but never under a control that is being used.

Outside edit mode there is no session to hold a change, so a change on the page goes through `EditSetting` and `EditPosition` instead of `SetSetting` and `SetPosition`: the way a change from the addon's own settings UI goes, to the layout while it owns the frame and to the addon's own settings otherwise. The library calls `OnChanged` and `Capture` after it. Nothing on the page lights up edit mode's Save.

The rows work as they do in the dialog, with two differences, both because there is no session to measure against or to hold a change back: a `revert` row puts back how the frame looked when the page was last opened, and a `layoutSpecific` row takes effect at once. Opening is the returned frame being shown, unless you pass `opener`, the frame whose showing counts instead. Pass your whole settings page there if you hide and show the rows while it is open, so that doing so does not move the point Revert goes back to. Rows that are buttons or actions run the addon's own code, which should end in `Capture` as any change of its own does. `CopyFrom` called from the page goes through `EditSetting` and `EditPosition` too.

## Embedding

The library needs LibStub, loaded before it:

```xml
<Script file="Libs\LibStub\LibStub.lua"/>
<Script file="Libs\LibLayoutSettings\LibLayoutSettings.lua"/>
```

```yaml
externals:
    Libs/LibLayoutSettings:
        url: https://github.com/LudiusMaximus/LibLayoutSettings
```

## Tests

The `tests` folder holds checks that run outside the game. Packagers leave it out, through the `ignore` list in `.pkgmeta`.

```sh
bash tests/run.sh
```

runs every test with whichever Lua is installed, 5.1 or later or LuaJIT, against a stubbed client in `tests/stubs.lua`. A test that runs away stops itself at 256 MB or 30 seconds, by way of a watchdog in `stubs.lua`, and `run.sh` gives each one 60 seconds at most:

- `session_test.lua` - saving, cancelling, Revert All, reverting one frame, giving the frame to a layout and taking it away as changes like any other, editing the addon's own settings while no layout owns the frame, presets being read only, saving only those on a preset without a new layout, in combat too, a new layout made by saving on a preset, importing, renaming, deleting, the parked look, switching layouts, the same layout applied again mid session, the arrow keys in and out of combat, selecting the frame in combat, the panel checkbox only showing and hiding the frame, and the dialog's layout specific row.
- `copy_from_test.lua` - which layouts are offered as a source, what a copy brings across and leaves alone, copying onto the addon's own settings, a dialog first opened in combat, the action row, the dialog's height, and malformed rows being refused.
- `page_test.lua` - registering under a layout that has parked its look, and the rows on a settings page: where a change goes, the layout specific row taking effect at once, Revert Changes and what counts as opening the page, redrawing, trying a dropdown option on, a dropdown's tooltip following its open menu, tooltips going left of the rows together, a colour's own button on the picker, being told the picker has opened and gone, Copy From, Reset Position and a button greying itself out outside edit mode, and a registration without `EditSetting` being refused.

The stubbed edit mode manager copies the order in which Blizzard calls things, because the library's behaviour depends on it. Whether Blizzard still calls things that way is what `blizzard_compat.sh` checks, in a checkout of [wow-ui-source](https://github.com/Gethe/wow-ui-source):

```sh
bash tests/blizzard_compat.sh ../wow-ui-source                          # every other client against retail
bash tests/blizzard_compat.sh ../wow-ui-source origin/live~1 origin/live  # what the latest patch changed
```

It reads what the library uses straight out of `LibLayoutSettings.lua`, so a newly hooked method, a new template or a new font object is covered without editing the script. Anything missing fails it. A changed method body is only reported, since not every change matters, but when one is, the stub in `session_test.lua` may need the same change.

## License

MIT
