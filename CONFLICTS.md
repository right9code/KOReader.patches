# KOReader Patches — Conflict Analysis & Suggestions

## Patch Inventory

| # | File | Size | Description |
|---|------|------|-------------|
| 1 | `2-fast-reading.lua` | 48 KB | Bionic reading, guided dots, first-letter focus |
| 2 | `2-reading-insights-stats.lua` | 101 KB | Reading insights popup (peterboda236 fork) |
| 3 | `2-reading-stats-popup.lua` | 44 KB | Book overview stats popup |
| 4 | `2-cvs-receipt-frankenpatch.lua` | 37 KB | CVS receipt style book completion widget |
| 5 | `2-mini-receipt-frankenpatch.lua` | 36 KB | Mini receipt style book completion widget |
| 6 | `2-reading-insights-popup.lua` | 68 KB | Reading insights popup (zenixlabs fork) |

---

## Conflicts

### 🔴 Conflict 1: `2-reading-insights-stats.lua` vs `2-reading-insights-popup.lua`

**These two patches CANNOT be installed simultaneously.** Both attempt to provide the same feature (reading insights popup) by registering identical Dispatcher actions and overwriting the same KOReader methods.

| Overlap | Details |
|---------|---------|
| Dispatcher action key | Both register `"reading_insights_popup"` with event `"ShowReadingInsightsPopup"` |
| `ReaderUI.onShowReadingInsightsPopup` | Both define this method — second one overwrites the first |
| `FileManager:onShowReadingInsightsPopup` | Both define this method — second one overwrites the first |
| Statistics plugin | `insights-popup` patches `onSyncBookStats` via `userpatch.registerPatchPluginFunc("statistics", ...)`; `insights-stats` does not |

**Recommendation:** Choose one and remove the other.

- **`2-reading-insights-stats.lua`** (peterboda236) — Larger, more feature-rich. Adds last-week view, CalendarView integration, books mode in monthly chart, stale-while-revalidate caching. Sets `_G.READING_INSIGHTS_AVAILABLE = true`.
- **`2-reading-insights-popup.lua`** (zenixlabs) — Original fork with LuaSettings-based disk cache, sync-aware cache invalidation, force-reload options, and statistics plugin sync patching.

---

### 🔴 Conflict 2: `2-cvs-receipt-frankenpatch.lua` vs `2-mini-receipt-frankenpatch.lua`

**These two patches CANNOT be installed simultaneously.** Both are different visual variants of the same "book completion receipt" feature.

| Overlap | Details |
|---------|---------|
| Dispatcher action key | Both register `"quicklookbox_action"` with event `"QuickLook"` |
| `ReaderUI:onQuickLook` | Both define this method |
| `FileManager:onQuickLook` | Both define this method |
| `ReaderUI:onEndOfBook` | Both define this method — one will overwrite the other |
| Global `bookCompleted` | Both set this variable at module scope |

**Recommendation:** Choose one and remove the other.

- **`2-cvs-receipt-frankenpatch.lua`** — Full CVS receipt style with configurable settings via `userpatch.registerPatchPluginFunc("statistics", ...)`
- **`2-mini-receipt-frankenpatch.lua`** — Compact mini receipt. Uses `G_reader_settings` for settings (`mini_rct_sett`).

---

### 🟢 No Conflict: `2-fast-reading.lua`

This patch is completely independent. It:
- Patches the `perceptionexpander` plugin via `userpatch.registerPatchPluginFunc`
- Does not register any Dispatcher action
- Does not modify `ReaderUI` or `FileManager`
- Has no global variable conflicts

**Can be safely installed alongside all other patches.**

---

### 🟢 No Conflict: `2-reading-stats-popup.lua`

This patch is independent from all others. It:
- Registers `"reading_stats_popup"` action (unique key)
- Uses event `"ShowReadingStatsPopup"` (unique event)
- Title: `"Reading statistics: overview"` (distinct from insights patches)
- `reader = true` (only in reader, not file manager)
- Patches `ReaderUI.registerKeyEvents` (unique approach)

**Can be safely installed alongside all other patches.**

---

## Specific Code Issues & Suggestions

### `2-reading-insights-popup.lua` — Global Variable Leaks

**Line 277:** `DEFAULTS` is declared without `local` — it pollutes the global namespace.
```lua
-- CURRENT (line 277):
DEFAULTS = {
    once_per_day = 1,
    reload_all_data_after_sync = 0,
}

-- SUGGESTED:
local DEFAULTS = {
    once_per_day = 1,
    reload_all_data_after_sync = 0,
}
```

**Line 282:** `RI_SETT` is declared without `local` — also leaks to global scope.
```lua
-- CURRENT (line 282):
RI_SETT = ReadingInsightsDatabase:readSetting("RI_SETT") or DEFAULTS

-- SUGGESTED:
local RI_SETT = ReadingInsightsDatabase:readSetting("RI_SETT") or DEFAULTS
```

### `2-reading-insights-popup.lua` — `clearCacheIfRequired` Uninitialized Local

**Line ~360:** `latest_db_mod_timestamp` is assigned without `local`, leaking to global.
```lua
-- CURRENT:
latest_db_mod_timestamp = getDbModTime()

-- SUGGESTED:
local latest_db_mod_timestamp = getDbModTime()
```

### `2-reading-insights-stats.lua` — Global Flag

**Line 42:** Sets a global flag that other patches could theoretically check:
```lua
_G.READING_INSIGHTS_AVAILABLE = true
```
This is intentional (allows other patches to detect if this one is loaded), but be aware of it.

### `2-cvs-receipt-frankenpatch.lua` — `ReaderUI:onEndOfBook` Override

Both receipt patches replace `ReaderUI:onEndOfBook` entirely rather than wrapping it. If another patch also needs to hook into end-of-book events, only the last one loaded will work. A safer pattern would be to save and call the original:

```lua
local orig_onEndOfBook = ReaderUI.onEndOfBook
function ReaderUI:onEndOfBook()
    if orig_onEndOfBook then orig_onEndOfBook(self) end
    -- custom logic here
end
```

### `2-mini-receipt-frankenpatch.lua` — Same `onEndOfBook` Issue

Same as above — replaces `ReaderUI:onEndOfBook` without chaining.

### `2-reading-stats-popup.lua` — ReaderUI.registerKeyEvents Patching

**Lines 1187-1198:** This patch correctly wraps `ReaderUI.registerKeyEvents`:
```lua
local orig_ReaderUI_registerKeyEvents = ReaderUI.registerKeyEvents
ReaderUI.registerKeyEvents = function(self)
    if orig_ReaderUI_registerKeyEvents then
        orig_ReaderUI_registerKeyEvents(self)
    end
    -- adds onShowReadingStatsPopup
end
```
This is the correct pattern. No issue here.

### `2-fast-reading.lua` — Clean

No issues found. Properly uses `local` for all variables and patches via the recommended `userpatch.registerPatchPluginFunc` mechanism.

---

## Recommended Installation Combinations

### Option A: Maximum Features (No Receipt)
```
patches/
├── 2-fast-reading.lua              ✅ no conflicts
├── 2-reading-insights-stats.lua    ✅ (choose this OR insights-popup, not both)
├── 2-reading-stats-popup.lua       ✅ no conflicts
```

### Option B: Maximum Features (With Receipt)
```
patches/
├── 2-fast-reading.lua              ✅ no conflicts
├── 2-reading-insights-stats.lua    ✅ (choose this OR insights-popup, not both)
├── 2-reading-stats-popup.lua       ✅ no conflicts
├── 2-mini-receipt-frankenpatch.lua ✅ (choose this OR cvs-receipt, not both)
```

### Option C: Minimal (Insights + Receipt)
```
patches/
├── 2-reading-insights-popup.lua    ✅ (with sync patching)
├── 2-cvs-receipt-frankenpatch.lua  ✅
```

---

## Summary Table

| | fast-reading | insights-stats | stats-popup | cvs-receipt | mini-receipt | insights-popup |
|---|---|---|---|---|---|---|
| **fast-reading** | — | ✅ | ✅ | ✅ | ✅ | ✅ |
| **insights-stats** | ✅ | — | ✅ | ✅ | ✅ | 🔴 **CONFLICT** |
| **stats-popup** | ✅ | ✅ | — | ✅ | ✅ | ✅ |
| **cvs-receipt** | ✅ | ✅ | ✅ | — | 🔴 **CONFLICT** | ✅ |
| **mini-receipt** | ✅ | ✅ | ✅ | 🔴 **CONFLICT** | — | ✅ |
| **insights-popup** | ✅ | 🔴 **CONFLICT** | ✅ | ✅ | ✅ | — |

---

## Action Items

1. **Fix global variable leaks** in `2-reading-insights-popup.lua` (add `local` to `DEFAULTS`, `RI_SETT`, `latest_db_mod_timestamp`)
2. **Choose one insights patch** — pick either `2-reading-insights-stats.lua` or `2-reading-insights-popup.lua`, not both
3. **Choose one receipt patch** — pick either `2-cvs-receipt-frankenpatch.lua` or `2-mini-receipt-frankenpatch.lua`, not both
4. **Consider wrapping `ReaderUI:onEndOfBook`** in receipt patches to chain with existing handlers instead of replacing them
5. **No changes needed** for `2-fast-reading.lua` or `2-reading-stats-popup.lua`