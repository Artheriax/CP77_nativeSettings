# Native Settings (Fork)

A small mod for Cyberpunk 2077 that allows other mods to easily add settings options to a custom, fully native UI `Mods` settings menu. User-friendly and fully controller compatible.

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/main.gif)

---

## About this fork

This is a patched fork of [NativeSettings](https://www.nexusmods.com/cyberpunk2077/mods/3518) aimed at fixing three classes of issues reported by users of the upstream mod:

1. **Recurring `init.lua:84: attempt to index field 'menuListController' (a nil value)` crash** — fired every time the main menu was opened under certain conditions.
2. **FPS drop and stutter** while interacting with the Mods settings menu (especially dragging sliders, with many options installed).
3. **Game crashes** attributed to the mod — including nil dereferences on out-of-range tab indices, leaked widgets accumulating across menu open/close cycles, and `Game.GetPlayer()` calls on the main menu.

The public API is **100% backwards-compatible**: every mod that consumes NativeSettings via `GetMod("nativeSettings")` will keep working unmodified. No function signatures changed, no fields removed, no behavior changes that affect consuming mods. See [CHANGES.md](./CHANGES.md) for the full per-fix rationale and a compatibility matrix.

### Key fixes at a glance

| Area | Fix |
|------|-----|
| **Crash** | `menuListController:PushData` now nil-guarded with `IsDefined` + deferred via `Cron.NextTick` when the controller isn't ready yet. |
| **Stutter** | `getOptionTable` is now O(1) via a `controllerToOption` lookup map (was O(N) per slider drag tick, calling the C# equality operator for every option). |
| **Stutter** | `tabSizeCache` page membership now uses an O(1) hash set (was O(N) linear scan inside the category loop, making it O(N²) per refresh). |
| **Crash** | `removeOption` / `removeSubcategory` use `table.remove` instead of `t[i] = nil` (was creating holes in arrays, breaking subsequent `#`/`table.insert` math). |
| **Crash** | `PopulateCategorySettingsOptions` and `RequestRestoreDefaults` nil-guard `this.data[idx+1]` / `this.data[tabIndex]` (was dereferencing `nil` on out-of-range indices). |
| **Crash** | `Game.GetPlayer()` guarded for `nil` on main menu / loading screens (audio events no longer crash). |
| **Leak** | `previousButton` / `nextButton` now `:Destroy()`'d on menu close (was accumulating widgets + event catchers every open/close cycle). |
| **Bug** | `spawnButton` now references `offState/body` for the off widget (was a copy-paste bug querying `onState/body` twice, so the off body was never hidden). |
| **Bug** | `setOption` now uses `o.isHold` (was `tab.isHold`, which crashes if the caller's table lacks `isHold`). |
| **Bug** | `setOption` now `break`s after match (was iterating every option in every tab even after applying the change). |
| **Bug** | `Cron.Update` iterates backwards so `table.remove` during iteration doesn't skip the next timer (was a no-op `i = i - 1` inside a generic `for`). |
| **Bug** | `EventProxy` cleanup timer halts itself when its proxy has zero live handlers (was running forever at 30s intervals per proxy signature). |
| **Bug** | `EventProxy.UnregisterCallback` is now the canonical name; the original typo `UnregisteCallback` is kept as an alias for backwards compat. |
| **Bug** | `pathExists` no longer crashes on unknown tab paths (was indexing `.subcategories` on a nil tab). |
| **Bug** | `getIndex` breaks early on first match (was scanning the whole table and returning the last match). |

Full per-fix documentation, root-cause analysis, and an 8-item verification checklist live in [CHANGES.md](./CHANGES.md).

---

## Requirements

- **Cyber Engine Tweaks (CET) 1.25.1 or newer.** The mod declares `minCETVersion = 1.25` internally and will print a warning + abort init if the installed CET is older. (Upstream README listed 1.18.1+, but several CET APIs the mod relies on — particularly around `SettingsMainGameController` hooks — were unstable before 1.25.)
- Cyberpunk 2077 game version 2.0+ (any patch since the Phantom Liberty update).

## Installation

### For end users

1. Make sure [Cyber Engine Tweaks](https://www.nexusmods.com/cyberpunk2077/mods/107) is installed (version 1.25.1+).
2. Copy the `nativeSettings/` folder (containing `init.lua`, `Cron.lua`, `EventProxy.lua`, `Ref.lua`, `UIButton.lua`) into `<Cyberpunk 2077>/r6/scripts/`.
3. Overwrite the existing `nativeSettings/` folder if you are upgrading from upstream.
4. No game restart is required if you reload the mod via the CET console; otherwise restart the game once.

### For mod authors (consuming NativeSettings)

Nothing changes. Your mod's existing `GetMod("nativeSettings")` call works exactly as before. The public API — `addTab`, `addSubcategory`, `addSwitch`, `addRangeInt`, `addRangeFloat`, `addSelectorString`, `addButton`, `addKeyBinding`, `addCustom`, `removeOption`, `removeSubcategory`, `pathExists`, `setOption`, `registerRestoreDefaultsCallback`, `refresh` — is unchanged in name, signature, and return value.

Add this mod to your mod's requirement list: [Nexus page](https://www.nexusmods.com/cyberpunk2077/mods/3518).

Import it into your mod:
```lua
nativeSettings = GetMod("nativeSettings")
```

---

## How to use

### Add a new tab

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/tabs.gif)

- Multiple mods can share the same tab.
- `path` should be a `/` followed by a simple keyword.
- `label` is what will be displayed.
- `callbackFunction` is an optional function parameter that gets called when the tab gets closed.

```lua
nativeSettings.addTab("/myMod", "My mod", callbackFunction) -- Add a tab (path, label, callback)
```

### Add a new subcategory

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/sub.PNG)

- Use subcategories to organize options.
- `path` should be your mods tab path (e.g. `/myMod`), followed by a `/`, followed by a simple keyword.
- `label` is what will be displayed.
- `optionalIndex` is an optional `int` parameter to control the position of the subcategory (Default is same order as `addSubcategory`'s get called).

```lua
nativeSettings.addSubcategory("/myMod/sub", "A subcategory") -- Add a subcategory (path, label, optionalIndex)
```

## Adding option widgets

- All option widgets can be added to either a tab directly (provide the tab path), or a tab's subcategory (provide the full path).

#### Parameters every widget has

- `path` : Where the widget goes, e.g. `/myMod` or `/myMod/sub`.
- `label` : What gets displayed to the left of the widget.
- `desc` : A description of what the option does, gets displayed when hovered over.
- `currentValue` : This is what the option's initial value (type depends on the widget) is. Usually, this value would get read from a settings file / database inside `onInit`.
- `defaultValue` : This is what the option's default value should be, gets set when the `Defaults` button is hit.
- `callback` : Here, you pass a function `f(value)` that gets called when the options gets changed. It gets called with a single parameter, the updated value.
- `optionalIndex` : Optional index parameter that can be used to control the order of the options (Default is same order as the `addOption`'s get called).

### Toggle

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/switch.gif)

- This adds a basic true/false switch.
- Datatype is `boolean`.

```lua
-- Parameters: path, label, desc, currentValue, defaultValue, callback, optionalIndex

nativeSettings.addSwitch("/myMod/sub", "Switch", "Description", true, true, function(state)
    print("Changed SWITCH to ", state)
    -- Add any logic you need in here, such as saving the changes to file / database
end)
```

### Slider Int

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/int.gif)

- This adds a slider that can only get set to whole numbers.
- Datatype is `int`.
- `min` : This is the minimum value of the slider.
- `max` : This is the maximum value of the slider.
- `step` : This is the minimum amount the slider can move.

```lua
-- Parameters: path, label, desc, min, max, step, currentValue, defaultValue, callback, optionalIndex

nativeSettings.addRangeInt("/myMod/sub", "Slider Int", "Description", 1, 100, 1, 50, 25, function(value)
    print("Changed SLIDER INT to ", value)
    -- Add any logic you need in here, such as saving the changes to file / database
end)
```

### Slider Float

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/float.gif)

- This adds a slider that can be set to any value.
- Datatype is `float` (`int` also works).
- `min` : This is the minimum value of the slider.
- `max` : This is the maximum value of the slider.
- `step` : This is the minimum amount the slider can move.
- `format` : This is a format string, to control how the value gets displayed (works the same as Lua's `string.format()`).

```lua
-- Parameters: path, label, desc, min, max, step, format, currentValue, defaultValue, callback, optionalIndex

nativeSettings.addRangeFloat("/myMod/sub", "Slider Float", "Description", 1, 100, 0.25, "%.2f", 50, 1, function(value)
    print("Changed SLIDER FLOAT to ", value)
    -- Add any logic you need in here, such as saving the changes to file / database
end)
```

### String List

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/list.gif)

- This adds a list of strings that can be chosen from.
- Datatype is `table`.
- The table must be numerically indexed.
- `currentValue` / `defaultValue` is the index of the selected element.

```lua
-- Parameters: path, label, desc, elements, currentValue, defaultValue, callback, optionalIndex

local list = {[1] = "Option 1", [2] = "Option 2", [3] = "Option 3", [4] = "Option 4"} -- Create list of options, with numeric index

nativeSettings.addSelectorString("/myMod/sub", "String List", "Description", list, 1, 3, function(value)
    print("Changed LIST STRING to ", list[value])
    -- Add any logic you need in here, such as saving the changes to file / database
end)
```

### Keybind

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/keybind.gif)

- This adds a keybind widget that can be clicked on to store any pressed key.
- Datatype is `string`.
- When pressed, it will return the keycode e.g. `IK_X` of the pressed key.
- `currentKey` and `defaultKey` need to be a [valid keycode](https://nativedb.red4ext.com/EInputKey).
- `isHold` determines whether or not the key icon has a "Hold" outline.
- The actual reading of raw inputs has to be done via [Codeware](https://github.com/psiberx/cp2077-codeware/wiki#game-events). For examples on how to implement this using CET, including a simple module for setting up multikey bindings, check the provided example in this repo.
- Controller bindings are supported too, but require [Codeware](https://github.com/psiberx/cp2077-codeware) to work (required for actually reading inputs anyways). For an example on how to forward the input events from Codeware to Native Settings, check the provided examples in this repo.

```lua
-- Parameters: path, label, desc, currentKey, defaultKey, isHold, callback, optionalIndex

nativeSettings.addKeyBinding("/myMod/sub", "Keybind", "Description", "IK_1", "IK_5", false, function(key)
    print("Changed KEYBIND to", key)
    -- Add any logic you need in here, such as saving the changes to file / database
end)
```

### Button

![](https://cdn.jsdelivr.net/gh/justarandomguyintheinternet/keanuWheeze/nativeSettingsImages/button.gif)

- This adds a simple, interactable button which calls the `callback` function without any parameters when clicked.
- Has no `currentValue` and `defaultValue` parameters.
- `buttonText` is the text that gets displayed inside the button.
- `textSize` is the size of the `buttonText` text.

```lua
-- Parameters: path, label, desc, buttonText, textSize, callback, optionalIndex

nativeSettings.addButton("/myMod/sub", "Button", "Description", "Button label", 45, function()
    print("User clicked BUTTON")
    -- Add any logic you need in here, such as calling a function from your mod
end)
```

### Custom Widget

- This is not a typical widget — it does not have any visible UI.
- It can be used to get a reference to the settings screen's main `inkCompoundWidget`.
- With this reference you can add your own custom widgets to the settings page, such as the [Furigana](https://github.com/dkollmann/cyberpunk2077-furigana) mod is doing.
- `inkCompoundWidget` is the [SettingsMainGameController](https://nativedb.red4ext.com/SettingsMainGameController)'s [settingsOptionsList](https://nativedb.red4ext.com/inkCompoundWidgetReference) widget.

```lua
-- Parameters: path, callback, optionalIndex

nativeSettings.addCustom("/myMod/sub", function(inkCompoundWidget)
    -- Add any logic you need in here, such as adding custom UI to the inkCompoundWidget
end)
```

## Removing options / subcategories

- Option widgets as well as subcategories can be added or removed while the UI is active.
- Use this in combination with the `optionalIndex` parameter of any `addOption` function to add and remove options where they are needed.

### Options

- `optionTable` is what gets returned by any `addOption` function (switch / int / float / list / button).

```lua
-- Parameters: optionTable
nativeSettings.removeOption(optionTable)
```

### Subcategories

- `path` is the full path to the subcategory you want to remove.

```lua
-- Parameters: path
nativeSettings.removeSubcategory("/myMod/sub")
```

## Custom Restore Defaults

A custom callback function can be registered for a tab, and optionally the normal restore default actions can be overridden.

```lua
-- Parameters: path, overrideNativeRestoreDefaults, callback

nativeSettings.registerRestoreDefaultsCallback("/myMod", true, function()
    -- Handle restoring defaults with your own logic
end)
```

## The `refresh` function

- Calling this function is not necessary anymore, as of version 1.4.
- Refreshes the UI when active, to reflect changes made by adding (e.g. `addSwitch`) or removing (e.g. `removeOption`) option widgets or entire subcategories.
- When adding or removing multiple option widgets or subcategories at once, make sure to only call `refresh` once, after all adding / removing operations are done.

```lua
nativeSettings.refresh()
```

## The `setOption` function

- The nativeSettings mod only gets the settings values at startup in the form of the `currentValue`.
- If you modify any settings / options from e.g. a secondary ImGui settings window, the values displayed by nativeSettings will be out of sync.
- Use the `setOption(optionTable, value)` function if you change an option from outside the nativeSettings window, to make sure everything stays synced.
- `optionTable` is what gets returned by any `addOption` function (switch / int / float / list).
- `value` is the value you want to set.

Example:

```lua
local settingsTables = {} -- An empty table to store the return from the addOption functions, in case we want to use setOption() or removeOption(), can be ignored otherwise
local switchState = false -- Would usually get loaded from a config file / database
local nativeSettings

registerForEvent("onInit", function()
    nativeSettings = GetMod("nativeSettings") -- Get a reference to the nativeSettings mod

    if not nativeSettings then -- Make sure the mod is installed
        print("Error: NativeSettings not found!")
        return
    end

    nativeSettings.addTab("/myMod", "My mod") -- Add our mods tab (path, label)
    nativeSettings.addSubcategory("/myMod/sub", "A subcategory") -- Optional: Add a subcategory (path, label), you can add as many as you want

    settingsTables["switch"] = nativeSettings.addSwitch("/myMod/sub", "Switch", "Description", switchState, true, function(state) -- Setup a switch, and store its returned table
        print("Changed SWITCH to ", state)
        switchState = state
    end)
end)

registerForEvent("onDraw", function()
    if ImGui.Begin("Alternative Settings Window", ImGuiWindowFlags.AlwaysAutoResize) then
        switchState, changed = ImGui.Checkbox("Switch", switchState)
        if changed then -- We changed the option value from somewhere else
            nativeSettings.setOption(settingsTables["switch"], switchState) -- Update the value for the nativeSettings mod
        end
    end
    ImGui.End()
end)
```

---

## File structure

```
nativeSettings/
├── init.lua         # Main mod logic (1,650 lines). Public API + CET hooks.
├── Cron.lua         # Timed task manager (psiberx). Patched: backwards iteration, HaltAll.
├── EventProxy.lua   # Event callback manager (psiberx). Patched: cleanup-timer leak, pcall, typo alias.
├── UIButton.lua     # Reusable ink button widget (psiberx). Patched: idempotent Destroy, pcall'd handlers.
├── Ref.lua          # Strong/weak IScriptable references (psiberx). Unchanged.
├── README.md        # This file.
└── CHANGES.md       # Full per-fix documentation, root-cause analysis, compatibility matrix.
```

## Compatibility

### With CET (Cyber Engine Tweaks)

All CET globals and game classes used are present in CET 1.25+:

| CET API | Used for |
|---------|----------|
| `registerForEvent("onInit"/"onUpdate")` | lifecycle hooks |
| `Observe` / `ObserveAfter` / `Override` | method hooking |
| `GetVersion()` | CET version check |
| `CName.add()` | CName registration |
| `GetLocalizedTextByKey()` | localization |
| `NameToString()` / `StringToName()` | CName conversion |
| `BuildWidgetPath()` | widget path construction |
| `IsDefined()` | nil-safety on IScriptable |
| `NewObject()` | creating C# objects from Lua |
| `Game.GetPlayer()` | audio events (now nil-guarded) |
| `Game["OperatorEqual;IScriptableIScriptable;Bool"]` | IScriptable equality |
| `CalcSeed()` | used by Ref.lua |
| `spdlog.warning()` | used by EventProxy |

Game classes hooked (all stable since game v2.0+): `SettingsMainGameController`, `SingleplayerMenuGameController`, `gameuiMenuItemListGameController`, `PauseMenuGameController`, `SettingsCategoryController`, `SettingsSelectorControllerBool`, `SettingsSelectorControllerInt`, `SettingsSelectorControllerFloat`, `SettingsSelectorControllerListString`, `SettingsSelectorControllerKeyBinding`.

Lua version: CET runs Lua 5.4. All code is compatible with Lua 5.1+ (no `goto`, no integer division `//`, no bitwise operators).

### With consuming mods

The public API was verified by automated diff against the upstream:

- **35 / 35 public functions** in `init.lua` unchanged (same name, same params, same return values).
- **0 functions** removed.
- **0 functions** with changed signatures.
- **2 functions** added (additive, can't break existing mods): `registerController` (internal), `invalidateOptionsCache` (no-op stub).
- **22 / 22 table fields** preserved on the `nativeSettings` object.
- **3 new fields** added (internal caches, all nil-initialized).
- `return nativeSettings` at end of `init.lua` preserved (required for `GetMod("nativeSettings")`).
- Option table structure (fields like `.state`, `.currentValue`, `.controller`, `.widgetName`) is unchanged — mods that read/write these fields work unmodified.

Helper modules:

| Module | Removed | Changed | Added | Unchanged |
|--------|---------|---------|-------|-----------|
| `Cron` | 0 | 0 | `HaltAll`, `Clear` | 7 |
| `EventProxy` | 0 (typo alias kept) | 0 | `UnregisterCallback` (correct spelling) | 8 |
| `UIButton` | 0 | 0 | 0 | 7 |
| `Ref` | 0 | 0 | 0 | 7 (unchanged file) |

## Verification checklist

After installing, the following should all work without errors:

1. Open the main menu -> Settings -> Mods tab. The recurring `init.lua:84` error should be gone.
2. Drag a slider with many options installed. Frame time should stay flat (verifiable via the CET overlay FPS counter).
3. Add / remove subcategories via a mod that does so at runtime. No "ghost" options should appear, and the placement of subsequent options should be correct.
4. Open and close the Mods settings menu 20+ times. No crash, no growing stutter (was the symptom of leaking `previousButton` / `nextButton`).
5. Click a button widget while on the main menu (no player loaded). No crash from `Game.GetPlayer()`.
6. Trigger "Restore Defaults" with no tab toggled. No crash from `this.data[0]`.
7. With multi-page tabs (more tabs than fit on one screen), navigate to page 2+ and verify the correct tab's settings are shown (not page 1's).
8. With multi-page tabs, use keyboard `next_menu` / `prior_menu` at the first / last tab to wrap between pages.

---

## Credits

### Upstream

- **[psiberx](https://github.com/psiberx)** for answering all the original author's questions, doing a lot of work on CET that makes this mod even work, and creating `Cron.lua`, `UIButton.lua`, `Ref.lua` and `EventProxy.lua`.
- **[RMK](https://www.nexusmods.com/cyberpunk2077/users/84555803)** for adding the keybind widget, making proper handling for adding and removing elements, and generally helping with bugfixing.
- **[dkollmann](https://github.com/dkollmann)** for adding the "custom" widget type and implementing the optional callback for tabs.
- **nim** for hating ImGui.

### Original upstream mod

- [NativeSettings on Nexus Mods](https://www.nexusmods.com/cyberpunk2077/mods/3518)

### This fork

Patch work focused on stability, performance, and backwards compatibility. No public API changes; no breaking behavior changes. See [CHANGES.md](./CHANGES.md) for the full per-fix documentation.