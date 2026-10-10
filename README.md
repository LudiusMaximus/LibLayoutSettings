# LibLayoutSettings

A World of Warcraft addon library that lets an addon frame take part in Blizzard's HUD edit mode, with its position and its settings remembered per edit mode layout.

## Why a library and not a Blizzard system

Blizzard's layouts are stored client side, and every entry in them is typed by the `Enum.EditModeSystem` enum, which only knows Blizzard's own systems. A foreign value cannot survive `C_EditMode.SaveLayouts`, and `EditModeManagerFrame` strips unknown systems out of every saved layout on login regardless.

So this library never touches Blizzard's layout data. It only reads which layout is active and keeps its own copy of position and settings, per layout, in the addon's saved variables.

## What it provides

- A panel next to the edit mode manager with one checkbox per registered frame, scrolling rather than growing once enough addons have registered.
- Blizzard's own selection glow on the frame while edit mode is active, complete with label, mouseover highlight and click to edit.
- Dragging the frame by that glow, and nudging it a pixel at a time with the arrow keys, ten at a time with shift held.
- A settings dialog of slider, checkbox, dropdown, colour, text, button, separator, revert, reset position and action rows.
- Copying one layout's stored look onto another.
- Save, cancel and revert semantics that match Blizzard's, including creating a new layout when saving while a preset layout is active.

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
    { key = "width",   name = "Width",   type = "slider", minValue = 40, maxValue = 1000, stepSize = 5 },
    { key = "spark",   name = "Spark",   type = "checkbox" },
    { key = "texture", name = "Texture", type = "dropdown", options = function() ... end },
  },

  GetSetting  = function(key) return profile[key] end,
  SetSetting  = function(key, value) profile[key] = value end,
  GetPosition = function() return profile.p, profile.rp, profile.x, profile.y end,
  SetPosition = function(point, relativePoint, x, y) ... end,

  -- optional, what a resetPosition row puts back and measures against
  GetDefaultPosition = function() return defaults.p, defaults.rp, defaults.x, defaults.y end,

  OnChanged     = function() MyAddon:UpdateLook() end,  -- optional, after any change
  OnPreview     = function(shown) ... end,              -- optional, show a dummy while editing
  RestoreOwnSettings = function() MyAddon:RestoreOwnSettings() end, -- optional, see below

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
| `type` | all | `"slider"`, `"checkbox"`, `"dropdown"`, `"color"`, `"text"`, `"separator"`, `"button"`, `"revert"`, `"resetPosition"` or `"actions"` |
| `sameRow` | all | put this in the second column of the row before it, rather than on one of its own |
| `padTop` | all | extra space above this row, in pixels. A `revert` row takes 12 by default, matching the gap Blizzard leaves above its own button block |
| `text`, `OnClick` | button | label, and what pressing it does. `OnClick` is passed the registration |
| `IsDisabled` | all | optional predicate, greys the row out when it returns true |
| `tooltip` | all | mouseover text, or a function returning it. Titled with `name`, or `text` for a button, or the label the library put on the row |
| `refreshOnChange` | checkbox, dropdown | redraw the dialog after this changes, so rows it greys out follow. Never put it on a slider, whose value changes on every frame of a drag |
| `minValue`, `maxValue`, `stepSize` | slider | range, `stepSize` defaults to 1 |
| `formatter` | slider | value formatter, as in Blizzard's edit mode |
| `options` | dropdown | array of `{value =, text =}`, or a function returning one |
| `actions` | actions | array of `{text =, OnClick =}`, or a function returning one. An entry of `{separator = true}` draws a divider. `OnClick` is passed the registration |
| `placeholder` | actions | what the button reads when nothing has been picked, defaults to `name` |
| `hasOpacity` | color | show the opacity slider, defaults to true |
| `maxLetters` | text | cap on the length, 0 or absent for none |
| `trim` | text | strip surrounding whitespace on commit |

Blizzard's edit mode has only three kinds of row - `Enum.EditModeSettingDisplayType` is `Dropdown`, `Checkbox` and `Slider` - so those three reuse its own templates and look exactly like its dialogs. A `color` row is built here out of `ColorSwatchTemplate` and `ColorPickerFrame`, and a `text` row out of `TooltipBackdropTemplate`, which is how `StaticPopup1EditBox` is dressed - the same pieces Blizzard uses for its own colour swatches and text fields.

A `text` row reports every keystroke, so the addon can show the change as it is typed, and Escape restores what was there. `trim` is applied only when the box is left or the value confirmed, never while typing - trimming per keystroke would mean a leading space could never be typed, because it would vanish as it was hit. Set `trim` here whenever the addon's own settings trim, or the two will disagree about what was typed.

A `color` setting's value is a table `{r, g, b, a}`. Table-valued settings are deep copied whenever they cross between the addon and a layout, so a layout's stored colour is never the same table the addon is rendering from. Without that every layout would show whichever colour was picked last.

Separators and buttons are entries in the same `settings` list, so they can be ordered freely against the settings. They have no `key` and are skipped wherever values are read or written.

A `tooltip` is read at hover time rather than when the dialog is built, so a function may return different text as the state changes. Rows are wired for it once, when they are created, and a row that is moused over is also a place the dialog can be dragged from, so mouse-enabling them costs nothing.

There is one tooltip per **row**, never one per widget. A label and the control beside it describe the same setting, so hovering either produces the same tooltip in the same place: the row owns it, and everything on it does nothing but report which row the mouse is on. That means everything, however deep - a slider row's control is `MinimalSliderWithSteppersTemplate`, and what the pointer actually lands on is the slider and the stepper buttons inside it, which take the mouse without passing it up - so every already-hoverable descendant of a row is wired when the row is built. Their mouse state is left as it was: switching it on for a frame built without it would put that frame in the way of clicks meant for something else. It appears off the right edge of the dialog, level with the row, so that it never covers the control you are judging the change by, and it is not re-anchored while the mouse travels along the row - so it stays put rather than jumping as you move from the label to the control. Two rows sharing a line get their tooltips at the same height, one for each. `GameTooltip` clamps itself to the screen, so a dialog dragged against the right edge still shows its tooltips.

A `revert` entry needs nothing but `{ type = "revert" }`. The library labels it with Blizzard's own `HUD_EDIT_MODE_REVERT_CHANGES`, reverts this frame when pressed, and enables it only while the frame actually differs - position and every setting included, whether they were changed from this dialog, from the addon's own settings, or by dragging the frame.

It measures against where editing *began*, not against how the session found the frame. Ticking a frame's checkbox is where editing begins, so it moves that mark rather than counting as a change against it. Otherwise a frame no layout owned yet would have something to revert the moment it was ticked, and reverting it would undo the tick and close the dialog. Undoing the tick itself is what edit mode's own Revert All and Cancel are for. The state is updated in place rather than by redrawing the dialog, so it stays correct during a slider drag. Put one wherever Blizzard puts theirs, above the closing divider.

An `actions` row is a dropdown that *does* something rather than holding a value: the entry you pick runs its `OnClick` and the button goes on reading its placeholder, because what you chose happened rather than became true. It has no `key` and is skipped wherever values are read or written, and it greys itself out when the list comes back empty. Build the list with a function rather than a table whenever it can change while the dialog is open.

A `resetPosition` entry likewise needs nothing but `{ type = "resetPosition" }`, and works only where the registration provides `GetDefaultPosition`. The library labels it with Blizzard's own `HUD_EDIT_MODE_RESET_POSITION`, puts the frame back to that position when pressed, and enables it only while the frame is somewhere else - leaving every other setting alone. Without `GetDefaultPosition` there is nothing to put back, so the row stays greyed out. Blizzard places its own below the closing divider, and so does this.

### Moving the frame

Dragging it by the selection glow is one way. The other is the arrow keys, which move the selected frame one pixel at a time, ten with shift held, exactly as Blizzard's own systems do. The keys are taken on the settings dialog, which is what Blizzard does too and is on screen precisely while something is selected. Anything the library does not act on is passed straight on, so Escape still leaves edit mode and typing still reaches whatever wanted it; a text row with focus takes the arrow keys first, so they still walk the cursor along what is being typed.

Every route ends in the same place: `SetPosition`, the layout's stored entry, and the edit mode Save button lighting up.

### Sharing the edit mode screen

Nothing owns the edit mode screen, and more than one addon may be adding frames to it. Taking a selection therefore means asking whoever else is on the screen to put their dialog away, and standing down in turn when they say the same.

Blizzard's manager is asked through its own `ClearSelectedSystem`, which its settings dialog listens to; that call is also the one signal every third-party library sends, so the library hooks it and drops its own selection when anyone else makes it. On top of that it fires and answers `EditModeExternal.hideDialog`, which is [LibEditMode](https://github.com/p3lim-wow/LibEditMode)'s convention and the closest thing to a standard there is. Anything following either will not end up with two dialogs open at once.

### Handing the frame back

A layout that does **not** own the frame calls `RestoreOwnSettings`, if the registration provides one. Without it the frame keeps whatever the last owning layout imposed, so a layout the player never opted in would silently inherit another layout's look.

The addon is expected to keep its own settings as they are outside any layout, and put them back here. Reverting or cancelling a session that had only just taken ownership hands the frame back the same way, rather than pinning on the values the session happened to open with. A button that drops a layout's own look in favour of the addon's settings is then a single call, `LLS:SetManaged(key, false)`, which hands the frame back and parks the layout's look in case the player changes their mind.

### Storage

Entries are keyed by layout type and name, with the character folded into character layout keys so that two characters may each own a layout of the same name:

```lua
storage["1:Raiding"] = {
  position = { point = "BOTTOM", relativePoint = "TOP", x = 0, y = -170 },
  settings = { width = 300, spark = true },
}
```

An entry in use is what the panel checkbox reflects. Unticking does not delete the entry but marks it `inactive = true`, so the layout keeps its look parked and ticking again brings it back rather than capturing whatever the frame happens to be wearing by then. A layout with no entry in use hands the frame back through `RestoreOwnSettings`, as described above.

Override layouts, the ones the game forces on the player, are never written to. While one is active the panel is greyed out and the frame is left wearing whatever the layout before it set.

Saving while a preset layout is active makes a new layout, and the edits made in the preset go to it while the preset goes back to what it was. An *imported* layout is built from a string that carries nothing of this library's, so it starts out owning nothing rather than inheriting the edits that happened to be open at the time.

## API

| Function | Purpose |
| --- | --- |
| `LLS:IsSupported()` | whether this client has an edit mode |
| `LLS:CanManage()` | whether the active layout is one a frame can be given to, false under an override layout |
| `LLS:RegisterFrame(key, info)` | register a frame, see above |
| `LLS:UnregisterFrame(key)` | remove a registration |
| `LLS:Refresh([key])` | re-apply the active layout, after changing something behind the library's back |
| `LLS:Capture(key)` | fold the frame's current state into the active layout, after the addon's own settings changed something |
| `LLS:RevertFrame(key)` | put one frame back the way the session found it, done for you by a `revert` row |
| `LLS:HasChanges(key)` | whether this session has changed the frame |
| `LLS:IsManaged(key)` | whether the active layout owns this frame |
| `LLS:GetActiveLayoutName()` | the active layout's name, for naming it in your own UI |
| `LLS:GetStoredLayouts(key)` | the other layouts holding a look for this frame, as `{key =, name =}` |
| `LLS:CopyFrom(key, sourceKey)` | put another layout's stored look onto this frame |
| `LLS:SelectFrame(key)` | open the settings dialog for a frame, as clicking its glow does |
| `LLS:ClearSelection()` | close it again |
| `LLS:SetManaged(key, managed)` | tick or untick the panel checkbox for the active layout |

`SelectFrame`, `ClearSelection` and `SetManaged` are what the panel and the glow call, exposed so an addon can drive the same thing from its own UI. Anything else on the library table is internal.

### Keeping the addon's own settings working

An addon that also lets the player change these settings elsewhere, from a context menu say, has to call `LLS:Capture(key)` afterwards. Otherwise the layout owning the frame puts its own value back the next time it is applied, and the change appears to be silently discarded.

`Capture` only touches a layout that already owns the frame, so a player who never ticked a checkbox is unaffected and the addon's settings keep behaving exactly as they did before. Layouts that were deliberately given their own settings keep them.

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

## License

MIT
