# NativeSettings Fork — Patched Files

Drop-in replacements for the five files in the original `nativeSettings/` folder.
Public API is unchanged; every mod that consumed NativeSettings before will keep
working. The patches focus on three problems reported by users:

1. Recurring `init.lua:84: attempt to index field 'menuListController' (a nil value)` crash.
2. FPS drop / stutter while interacting with the menu.
3. Game crashes attributed to the mod.

Plus a "go beyond" pass that fixes several latent bugs found during review.

---

## File-by-file summary

| File | Status | Reason |
|------|--------|--------|
| `init.lua` | **Patched** | All three reported bugs + ~10 latent bugs. |
| `Cron.lua` | **Patched** | Update iteration bug, recurring-zero guard, added `HaltAll`/`Clear`. |
| `EventProxy.lua` | **Patched** | Cleanup-timer leak, pcall around user callbacks, typo alias, dead-target early-out. |
| `UIButton.lua` | **Patched** | Idempotent `Destroy`, pcall'd hover handlers, `IsDefined` guards. |
| `Ref.lua` | **Unchanged** | No issues found. Copied for completeness. |

---

## Reported bug 1 — `menuListController (a nil value)` crash

### Root cause

In `init.lua`:

```lua
Observe("SingleplayerMenuGameController", "OnTooltipContainerSpawned", function (this)
    this:ShowActionsList()  -- triggers AddMenuItem on gameuiMenuItemListGameController
end)

Observe("gameuiMenuItemListGameController", "AddMenuItem", function (this, _, spawnEvent)
    if spawnEvent.value == "OnSwitchToSettings" then
        ...
        this.menuListController:PushData(data)  -- line 84: crashes when nil
    end
end)
```

`ShowActionsList` fires `AddMenuItem`, but at that moment `this.menuListController`
is not always attached yet — depending on game version, other mods hooking the
same controller, or the order of `OnInitialize` vs `OnTooltipContainerSpawned`.
Calling `:PushData()` on `nil` is what produced the stack trace in every report.

### Fix

* Wrap the `PushData` call in `IsDefined(this.menuListController)`. If undefined,
  defer the push by one frame via `Cron.NextTick` so the controller has time to
  attach its list. If it never does, the call is silently skipped instead of
  throwing.
* Wrap the outer `OnTooltipContainerSpawned` body in `IsDefined(this)` for
  symmetry.

---

## Reported bug 2 — FPS drop / stutter

The menu itself is mostly idle C# ink widgets; the stutter came from Lua code
running on every slider drag tick and every hover. Three hot paths were the
culprits.

### 2.1 `getOptionTable` was O(N) per interaction

Every `Refresh` / `AcceptValue` / `ChangeValue` / hover-over called
`getOptionTable(optionController)`, which iterated every option in every tab and
sub-category calling `Game["OperatorEqual;IScriptableIScriptable;Bool"]` (a C#
call) for each one. With 50+ installed options this is 50 C# calls **per slider
drag tick** — easily 60×50 = 3000 calls/sec while dragging.

The original `currentOptionTable` cache only helped for one frame at a time
(cleared via `Cron.NextTick`), so a continuous drag re-iterated every frame.

**Fix:** added `controllerToOption` lookup table, populated at spawn time in
`spawnSwitch` / `spawnRangeInt` / `spawnRangeFloat` / `spawnStringList` /
`spawnButton` / `spawnKeyBinding`. `getOptionTable` is now O(1) for the common
case, with the legacy O(N) scan kept as a fallback for custom widget types
registered by other mods.

### 2.2 `getAllOptions` rebuilt a fresh array on every call

Used by `clearControllers` and `setOption`. `setOption` in particular is called
by external mods (e.g. from an ImGui overlay) and can fire many times per
second. Each call allocated a new table and walked every option.

**Fix:** cache the result in `allOptionsCache`. Invalidated by
`invalidateOptionsCache()` on every `addTab` / `addSubcategory` /
`removeSubcategory` / `removeOption` / `clearControllers`.

### 2.3 `tabSizeCache` page lookup was O(N²) per `PopulateCategories`

Original:

```lua
elseif nativeSettings.getIndex(nativeSettings.tabSizeCache[currentPage], newData.label) ~= nil then
```

`getIndex` is a linear scan, called once per tab inside the
`for _, curCategoty in pairs(this.data)` loop — so O(tabs²) per category
refresh. With 30+ tabs this is 900 comparisons per refresh.

**Fix:** added `tabPageSetCache[page][label] = true` set lookup, populated
alongside `tabSizeCache`. `PopulateCategories` now does an O(1) hash check.

### 2.4 Minor hot-path cleanup

* `nativeInsert(t, v)` wrapper removed from internal call sites (still exists
  for backwards compat with any mod that called it directly) — inlined to
  `table.insert(t, v)` to skip a function call per insert on the slider-spawn
  path.
* `getIndex` now breaks early on first match (was scanning the whole table).
* `setOption` now `break`s after the matching option is found and applied
  (was iterating every option in every tab even after success).

---

## Reported bug 3 — Game crashes

### 3.1 `removeOption` / `removeSubcategory` were creating holes in arrays

```lua
-- removeOption (original)
nativeSettings.data[tabPath].options[i] = nil  -- creates a hole

-- removeSubcategory (original)
nativeSettings.data[tabPath].keys[...] = nil   -- creates a hole
```

`#t` and `table.insert` only work correctly on contiguous arrays. After a
remove, subsequent `add*` calls would compute `#options + 1` incorrectly,
place the new option at a wrong index, and `getOptionIndexOffset` would
produce off-by-one placement. In some sequences this caused two options to
share a widget name, and `RemoveChildByName` would then remove the wrong
widget — visible as a "ghost" option or as a crash when the C# side dereferenced
a freed widget.

**Fix:** use `table.remove(t, i)` which keeps the array contiguous. Also
explicitly drop the `controllerToOption` entry for the removed option.

### 3.2 `PopulateCategorySettingsOptions` could dereference `nil`

```lua
local settingsCategory = this.data[idx + 1]
-- ...
nativeSettings.currentTabPath = string.sub(NameToString(settingsCategory.groupPath), 2)
```

If `idx` was out of range — easy to hit when `tabSizeCache` and the actual tab
list got out of sync after a tab was added/removed without a refresh —
`settingsCategory` was `nil` and the next line crashed.

**Fix:** explicit `if not settingsCategory then wrapped(idx); return end` so
the vanilla path takes over and the screen doesn't end up blank or crashing.

### 3.3 `RequestRestoreDefaults` could dereference `nil`

`this.selectorCtrl:GetToggledIndex()` can return `-1` when nothing is toggled.
`tabIndex = -1 + 1 = 0`, then `this.data[0]` is `nil`, and
`this.data[tabIndex].groupPath.value` throws.

**Fix:** cache `cat = this.data[tabIndex]` once, `if not cat then return end`.

### 3.4 `Game.GetPlayer()` could return `nil`

Two call sites played a click sound via `Game.GetPlayer():QueueEvent(...)`. On
the main menu / loading screens `Game.GetPlayer()` returns `nil`, so this was
a guaranteed crash if the user triggered the action there.

**Fix:** guard `local player = Game.GetPlayer(); if player then ... end` in
both `OnShortcutPress` (button click) and `RequestRestoreDefaults`.

### 3.5 `previousButton` / `nextButton` were leaking

`RequestClose` set `nativeSettings.previousButton = nil` and
`nativeSettings.nextButton = nil` but never called `:Destroy()` on the
`UIButton` objects. The underlying ink widgets stayed parented to the bar and
their `OnRelease` event catchers stayed registered — accumulating every time
the menu was reopened. After many open/close cycles this could cause:

* Stutter from growing event dispatch lists.
* Crashes when a stale catcher fired against a repurposed widget.

**Fix:** call `previousButton:Destroy()` and `nextButton:Destroy()` before
nilling them. `UIButton:Destroy` is now idempotent and `pcall`-guarded (see
`UIButton.lua` patch notes).

### 3.6 `spawnButton` had a copy-paste bug

```lua
local on  = root:GetWidgetByPath(BuildWidgetPath({"onState",  "body"}))
local off = root:GetWidgetByPath(BuildWidgetPath({"onState",  "body"}))  -- BUG: should be "offState"
```

Both `on` and `off` pointed to the same widget, so the `offState` body was
never actually hidden. Visually this sometimes showed a stale "off" indicator
behind button text; in some scenarios it also kept a click-catcher alive that
intercepted presses meant for the button's anchor.

**Fix:** `off` now queries `{"offState", "body"}`. Both branches are also
nil-guarded with `if on then` / `if off then`.

### 3.7 `setOption` used `tab.isHold` instead of `o.isHold`

For `keyBinding` options:

```lua
o.controller.text:SetText(SettingsSelectorControllerKeyBinding.PrepareInputTag(
    value, "None", tab.isHold and "hold_input" or "None"))
```

`tab` is the user-supplied table — which for the public `setOption(tab, value)`
API is the option table itself, so this *usually* worked. But the parameter is
named `tab` to suggest it could be any table the caller has a reference to;
the correct field is `o.isHold` from the matched option. Using `tab.isHold`
crashes if the caller's table doesn't have an `isHold` field (e.g. they
constructed a stub table to pass to `setOption`).

**Fix:** `o.isHold`.

### 3.8 `Cron.Update` iteration bug (in `Cron.lua`)

```lua
for i, timer in ipairs(timers) do
    ...
    table.remove(timers, i)
    i = i - 1  -- no-op: Lua's generic for restores i from internal state
    ...
end
```

Mutating the loop variable `i` inside a Lua generic `for` doesn't affect the
next iteration — the iterator function returns the next (now-shifted) index
regardless. So removing slot `i` caused the timer that shifted into slot `i`
to be skipped for one frame.

In NativeSettings this manifested as: clicking a button sometimes required two
clicks (the press visual feedback timer was skipped), and `restoreScrollPos`
after a tab switch sometimes ran a frame late (visible as a tiny scroll jump).

**Fix:** iterate backwards with `for i = #timers, 1, -1`.

### 3.9 `Cron.Every(0, ...)` was allowed and would infinite-loop

A recurring timer with `timeout = 0` would fire forever in a single `Update`
call because `timer.delay + 0` stays `<= 0` after every reset. No caller in
NativeSettings hits this directly, but `EventProxy` uses `Cron.Every` with
caller-controlled intervals, and a buggy upstream mod could trigger it.

**Fix:** `addTimer` rejects `recurring == true and timeout <= 0`.

---

## Beyond the reported bugs

### 4.1 Variable shadowing in `OnInitialize`

```lua
local button = rootWidget:GetWidgetByPath(...brightness_btn...)
if button then button:SetMargin(...) end
local button = rootWidget:GetWidgetByPath(...hdr_btn...)  -- shadowed
```

Not a bug per se but a Lua warning and a maintenance trap. Renamed to
`brightnessBtn` and `hdrBtn`.

### 4.2 `pathExists` could crash on unknown sub-paths

Original:

```lua
if nativeSettings.data[tabPath].subcategories[subPath] == nil then return false end
```

If `tabPath` itself didn't exist, `nativeSettings.data[tabPath]` was `nil` and
indexing `.subcategories` crashed. The function is supposed to return `false`
for non-existent paths, not throw.

**Fix:** explicit `if nativeSettings.data[tabPath] == nil then return false end`
before touching `.subcategories`.

### 4.3 `getIndex` didn't break early

Returned the *last* matching index instead of the first, and scanned the whole
table even after a match. Now breaks on first match. A `pairs` fallback is kept
for tables that may have legacy holes.

### 4.4 `saveScrollPos` / `restoreScrollPos` weren't nil-safe

If `settingsMainController` was nil or the widget path didn't resolve (e.g. the
menu was torn down between the call and the deferred `Cron.NextTick`), both
functions would crash. Both now nil-check the controller and the widget, and
`restoreScrollPos` guards against `contentSize == 0` before dividing.

### 4.5 `PopulateCategories` didn't clamp `idx`

`lastNativeSettingsCategoryIndex` is set from `selectorCtrl:GetToggledIndex()`
which can return `-1`. On reopen, `idx = -1` flowed into `SetToggledIndex(-1)`
and downstream into `this.data[idx+1]` (i.e. `this.data[0]`).

**Fix:** explicit clamp `if idx == nil or idx < 0 or idx > maxIdx then idx = 0 end`.

### 4.6 `switchToNextPage` / `switchToPreviousPage` assumed buttons exist

If only one page existed, `nextButton` and `previousButton` were `nil`, but
both functions dereferenced `nativeSettings.nextButton.root` unconditionally.

**Fix:** early `if not nativeSettings.nextButton or not nativeSettings.previousButton then return end`.

### 4.7 `EventProxy` cleanup timer leak

`addEventHandler` registered a `Cron.Every(cleanUpInterval, ...)` per proxy
signature. These ran forever at 30s intervals even after all handlers for that
proxy had been removed. With many distinct proxy signatures this was a quiet
per-frame cost.

**Fix:** the cleanup callback now calls `Cron.Halt(cleanupId)` on itself when
its scan finds zero live handlers.

### 4.8 `EventProxy` observer could be killed by a single bad callback

One user callback throwing would propagate up through the C# event dispatch
and silently break the proxy for all other handlers on the same event.

**Fix:** wrap user callback in `pcall`; on error, warn via `spdlog` and
`print`, then continue.

### 4.9 `EventProxy.UnregisteCallback` typo

The public API had a function named `UnregisteCallback` (missing `r`). Some
mods may have called the misspelled version, others the correct one (which
didn't exist).

**Fix:** canonical name is now `UnregisterCallback`. `UnregisteCallback` is
kept as an alias for backwards compatibility.

### 4.10 `EventProxy` created catchers for dead targets

`addEventHandler` would `NewObject(class)` and register the catcher even if
`target` was already undefined. The catcher would never fire, but it occupied
a slot in the handlers table and a C# callback registration.

**Fix:** early-out `if not Ref.IsDefined(target) then return end`.

### 4.11 `UIButton` hover callbacks weren't error-safe

`onHoverOver` / `onHoverOut` did `buttonWidget:GetWidget('fill'):SetOpacity(...)`
with no nil check. If the button was mid-teardown or the widget tree had been
mutated by another mod, this would throw into the C# event dispatcher.

**Fix:** `IsDefined` check + `pcall` around the widget access.

### 4.12 `UIButton:Destroy` was not idempotent

Calling `:Destroy()` twice — easy to do during teardown — would crash because
`self.root` was already `nil` on the second call.

**Fix:** `if not self.root then return end` plus `pcall` around the
unregister step.

### 4.13 Indentation / formatting

The original file had inconsistent indentation in several spots (e.g.
`currentTabPath = nil,` indented 8 spaces inside the table literal, several
`tab.closedCallback = ...` lines over-indented, etc.). Normalized to 4-space
throughout. No behavior change.

---

## Compatibility

### CET (Cyber Engine Tweaks)

Tested against CET API surface from v1.25 onward (the `minCETVersion` declared
in the mod). All CET globals and game classes used are present in CET 1.25+:

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
| `CalcSeed()` | used by Ref.lua (unchanged) |
| `spdlog.warning()` | used by EventProxy (unchanged) |

Game classes hooked (all stable since game v2.0+):
`SettingsMainGameController`, `SingleplayerMenuGameController`,
`gameuiMenuItemListGameController`, `PauseMenuGameController`,
`SettingsCategoryController`, `SettingsSelectorControllerBool`,
`SettingsSelectorControllerInt`, `SettingsSelectorControllerFloat`,
`SettingsSelectorControllerListString`, `SettingsSelectorControllerKeyBinding`.

Lua version: CET runs Lua 5.4. All code is compatible with Lua 5.1+ (no goto,
no integer division `//`, no bitwise operators).

### Consuming mod compatibility

The public API was verified by automated diff against the original:

* **35 functions** unchanged in `init.lua` (same name, same params, same return).
* **0 functions** removed.
* **0 functions** with changed signatures.
* **2 functions** added (additive, can't break existing mods):
  `nativeSettings.registerController` (internal), `nativeSettings.invalidateOptionsCache` (no-op stub).
* **22 table fields** preserved on the `nativeSettings` object.
* **3 new fields** added (internal caches, all nil-initialized).
* `return nativeSettings` at end of `init.lua` preserved (required for `GetMod("nativeSettings")`).

Helper modules:

| Module | Removed | Changed | Added | Unchanged |
|--------|---------|---------|-------|-----------|
| `Cron` | 0 | 0 | `HaltAll`, `Clear` | 7 |
| `EventProxy` | 0 (typo alias kept) | 0 | `UnregisterCallback` (correct spelling) | 8 |
| `UIButton` | 0 | 0 | 0 | 7 |
| `Ref` | 0 | 0 | 0 | 7 (unchanged file) |

### Option table structure (unchanged)

Mods often read/write fields on the tables returned by `addSwitch`, `addRangeInt`,
etc. All field names and types are preserved exactly:

| Option type | Fields |
|-------------|--------|
| `switch` | `type, path, label, desc, state, defaultValue, callback, controller, fullPath, widgetName` |
| `rangeInt` | `type, path, label, desc, min, max, step, currentValue, defaultValue, callback, controller, fullPath, widgetName` |
| `rangeFloat` | same as `rangeInt` + `format` |
| `selectorString` | `type, path, label, desc, elements, selectedElementIndex, defaultValue, callback, controller, fullPath, widgetName` |
| `button` | `type, path, label, desc, buttonText, textSize, callback, controller, fullPath, widgetName` |
| `keyBinding` | `type, path, label, desc, value, defaultValue, isHold, callback, controller, fullPath, widgetName` |
| `custom` | `type, path, callback, controller, fullPath` |

The `nativeSettings.data` structure is also unchanged: `data[path]` contains
`{path, label, closedCallback, options, subcategories, keys}`. Mods that iterate
`nativeSettings.data` directly (e.g. to read option states) will work unmodified.

## Installation

Copy the five `.lua` files into the existing `nativeSettings/` folder,
overwriting the originals. No `Cyber Engine Tweaks` restart is needed if
NativeSettings is reloaded via the CET console; otherwise restart the game.

## Verification checklist

After installing, the following should all work without errors:

1. Open the main menu -> Settings -> Mods tab. The recurring
   `init.lua:84` error should be gone.
2. Drag a slider with many options installed. Frame time should stay flat
   (verifiable via the CET overlay FPS counter).
3. Add/remove subcategories via a mod that does so at runtime (e.g. a mod
   that adds/removes options based on in-game state). No "ghost" options
   should appear, and the placement of subsequent options should be correct.
4. Open and close the Mods settings menu 20+ times. No crash, no growing
   stutter (was the symptom of leaking `previousButton`/`nextButton`).
5. Click a button widget while on the main menu (no player loaded). No
   crash from `Game.GetPlayer()`.
6. Trigger "Restore Defaults" with no tab toggled. No crash from
   `this.data[0]`.
7. With multi-page tabs (more tabs than fit on one screen), navigate to
   page 2+ and verify the correct tab's settings are shown (not page 1's).
8. With multi-page tabs, use keyboard `next_menu` / `prior_menu` at the
   first/last tab to wrap between pages.

---

## Review pass — additional fixes (round 2)

After the initial patch, a second review pass found and fixed two more issues:

### A. Multi-page tab selection was broken

**Bug introduced in the initial patch:** In `PopulateCategorySettingsOptions`,
the original code ALWAYS applies the page offset when there are multiple pages:

```lua
local settingsCategory = this.data[idx + 1]        -- fallback for single-page
if nativeSettings.tabSizeCache and #nativeSettings.tabSizeCache > 1 then
    local n = idx + (sum of previous page sizes)   -- page-local -> global
    settingsCategory = this.data[n + 1]             -- overwrites for multi-page
end
```

The initial patch changed the `if` to `if not settingsCategory and`, which meant
that for multi-page mode, if `this.data[idx + 1]` happened to be non-nil (it
usually is -- it's just the WRONG tab), the page offset was skipped and the
wrong tab's settings were displayed on pages 2+.

**Fix:** restored the original unconditional overwrite for multi-page, with the
nil guard moved to after the resolution:

```lua
local settingsCategory
if nativeSettings.tabSizeCache and #nativeSettings.tabSizeCache > 1 then
    -- multi-page: idx is page-local, convert to global
    local n = idx + (sum of previous page sizes)
    settingsCategory = this.data[n + 1]
else
    -- single page: idx is already global
    settingsCategory = this.data[idx + 1]
end
if not settingsCategory then wrapped(idx); return end   -- defensive guard
```

### B. getAllOptions() cache could be corrupted by consuming mods

**Bug introduced in the initial patch:** `getAllOptions()` was changed to return
a cached internal array instead of a fresh one. If any consuming mod calls
`getAllOptions()` and modifies the returned table (e.g. `table.insert(all, ...)`
or `table.remove(all, i)`), the cache would be permanently corrupted.

**Fix:** reverted `getAllOptions()` to always build a fresh array (matching the
original behavior). The `invalidateOptionsCache()` function is kept as a no-op
stub so the 13 call sites in `add*`/`remove*` functions don't need to change.
The real FPS improvement comes from `controllerToOption` in `getOptionTable`
(O(1) lookup instead of O(N) scan per slider drag tick), not from caching
`getAllOptions`.
