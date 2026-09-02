# FocusFlow v1.4.0 — polished, lightweight

Pomodoro timer + To-Do (plain / Kanban) for [Omarchy](https://omarchy.org) — single bar widget, rich popup, minimal resource footprint. Hover shows **FocusFlow**.

![FocusFlow Preview](assets/preview.png)

* **Pomodoro cycle** — Work / Short break / Long break (default `25/5/15` min, every 4 cycles), pause/resume/reset/skip, cycle counter, deadline-based math survives bar reloads. Single `1000ms` tick timer; ticks muted 30s during alarm to avoid overlap in continuous mode.
* **Sound (lightweight)** — `tick.ogg` (5.3K mono 22k) + `alarm.ogg` (142K mono 22k) + fallback `tick.wav/alarm.wav` mono 22k — was `5.6M` WAV. Played via `pw-play --volume || paplay` with path sanitization (`..` rejected). `tick` every second when enabled, `alarm` once on phase end. Volume sliders now `save+apply` on release.
* **To-Do** — plain list or Kanban (`132px` cols in `580px` board, horizontal 12px gaps, per-column vertical scroll). Plain: custom `18×18` checkbox. Both support `⬆` push → `↩` undo to Obsidian. `Space` start/pause when panel focused. `▲ ▼` on hover to prioritize within column.
* **Obsidian vault** — optional manual export per kanban profile. Task → `- [ ] task [To Do] — YYYY-MM-DD HH:MM <!-- id -->` (or `[x]` if `Done`) in `vault/<Profile>/FlowFocus.md` (Default → `vault/FlowFocus.md`). Idempotent `grep -v <!-- id -->`, `✓`→`↩` undo removes line, `Push all` per active profile.
* **Kanban profiles** — `Default` + up to 20 custom spaces (`Kanban — <Space>` heading). `Spaces:` pill tabs + `+` creator, `Rename`/`Delete` (with `Yes/No` confirm). Switch via click or `Alt+H` / `Alt+L` when FocusFlow focused. Each profile isolated tasks, vault files, and counts.
* **Bar** — idle `` only; running ring + `MM:SS` (`accent` work, `muted` break, `urgent` long break). `SUPER + SHIFT + T` toggles popup.
* **Compact UI** — `SmallToggle` `32px` 2-col grid, `PanelSlider 95px`, timing side-by-side, vault inline, per-column `Flickable` scroll, capped heights, no `ScrollBar` chrome, left accent `3px` + `●` for active task, `-` delete at top-right `z:10`.

## Install
```bash
omarchy plugin add https://github.com/kamal-v8/flowfocus --enable --yes
omarchy bar move flowfocus --section right
# or manual
git clone https://github.com/kamal-v8/flowfocus ~/.config/omarchy/plugins/flowfocus
omarchy-shell shell rescanPlugins; omarchy plugin enable flowfocus
```

`sounds/*.ogg` are 147K total (was 5.6M). Replace in place and `omarchy restart shell` to use your own.

## Usage
* Click → open/close, Right-click → start/pause, Middle → reset, `SUPER+SHIFT+T` → toggle, `Space` (focused) → start/pause
* Header: ring + `MM:SS` + phase + `Next: task`. Gear `` collapses compact Settings.
* Controls: Start/Pause/Reset/Skip, Board↔List, cycle `N — M pomodoros`.
* Kanban: `← →` move, `✕` delete, `⬆` push (→ `✓`), `●` active. Plain: `☐` done, `○/●` focus, `→` cycle, `⬆`/`✕`.

State: `~/.local/state/omarchy/focusflow.json` (`XDG_STATE_HOME` honoured, atomic `FileView`). `tasks[]` ≤200×200 chars, `column∈{backlog,todo,doing,done}`, `pushedToObsidian`+`pushedColumn` for idempotency.

## Configuration (`shell.json` `flowfocus` entry)

| Key | Type | Default | Notes |
|---|---|---|---|
| `workSec` | int | 1500 | 60–18000 |
| `shortBreakSec` | int | 300 | 30–1500 |
| `longBreakSec` | int | 900 | 60–3600 |
| `longBreakInterval` | int | 4 | 1–12 |
| `tickEnabled` | bool | false |  |
| `tickVolume` | real | 0.3 | 0–1 |
| `alarmEnabled` | bool | true |  |
| `alarmVolume` | real | 0.5 | 0–1 |
| `kanbanMode` | bool | false |  |
| `showPomodoros` | bool | true |  |
| `autoStartBreaks/Work` | bool | false |  |
| `notificationsEnabled` | bool | true |  |
| `obsidianEnabled` | bool | false |  |
| `obsidianVaultPath` | string | "" | `~/ObsidianVault`, `..`/`;`/`$`/`&`/`|`/`*`/`?` rejected |
| `obsidianFile` | string | FlowFocus.md | `_/\\` → `_`, 100 chars |

Example:
```json
{ "id": "flowfocus", "workSec": 1500, "tickEnabled": true, "obsidianEnabled": true, "obsidianVaultPath": "~/Documents/Obsidian-Vault/sync" }
```

## Sounds
* `tick.ogg` (5.3K) / `tick.wav` (23K) — 0.5s mono 22k vorbis/PCM from `clock.ogg` (Focus Timer flatpak). `alarm.ogg` (142K) / `alarm.wav` (1.3M) — 30.01s mono 22k from `s8E_Ggf_QsQ` via `yt-dlp --download-sections` + `ffmpeg -ac 1 -ar 22050 -c:a libvorbis -q:a 3 / pcm_s16le`. Play: `pw-play --volume 0.5 ~/.config/omarchy/plugins/flowfocus/sounds/alarm.ogg || pw-play .../alarm.wav` (fallback `paplay`).

## IPC
```bash
qs ipc -n -p "$OMARCHY_PATH/shell" call flowfocus togglePanel
qs ipc -n -p "$OMARCHY_PATH/shell" call flowfocus {start,pause,resume,toggle,reset,skip,open,close}
```

## Security
* `Model.sanitizePluginDir` blocks `..`; `sanitizeVaultPath` blocks `..`/`;`/`&`/`|`/`$`/`\``/`*`/`?`/`<>`/`^()`/`{}`/`[]`/`\`/`'`/`"`/control chars, 500 chars, vault file `_/\\`→`_` + `sanitizeProfileNameForPath` for per-profile subfolders. Task text `trim` 200, `\\`/`"`/`$`/`` ` `` escaped before `bash -c` `printf`. Task `column`/`profileId` whitelisted, `done`/`pushed` bool-coerced. All writes `FileView atomicWrites`. `ConfirmDialog` Yes/No for delete task/profile + vault sync.

## Development
```bash
omarchy plugin validate ~/.config/omarchy/plugins/flowfocus
omarchy restart shell
# Alt+H/L cycles kanban profiles when FocusFlow focused
```
* `BarWidget.qml` — `FileView` + single `tickTimer 1000ms` + `alarmMuteTimer 30000ms`, `Model.tick` deadline, `JSON.parse(JSON.stringify(state))` to trigger QML, `cycleProfile`/`moveTaskUp/Down`.
* `Panel.qml` — `KeyboardPanel` (no extra `BorderSurface`), `Flickable` per-column, `SmallToggle: Item 32px`, `Shortcut Alt+H/L`, hover `▲▼` prioritization, `ConfirmDialog` for deletes.
* `Model.js` — pure: `defaultState v2` with `kanbanProfiles/activeKanbanProfileId`, `parse` migration, `phaseDurationSec/tick/progress`, task CRUD + `profileId` + `pushedToObsidian/pushedColumn`, `playTick/alarm` `tick.ogg/wav` fallback, `appendTaskToVault` per-profile `vault/<Profile>/FlowFocus.md` idempotent.

## Changelog v1.4.0 (polished)
* Profiles: 20 spaces (`Default` + custom), `Kanban — <Space>` heading, pill tabs + `+` creator, `Alt+H/L` cycle when focused, per-profile tasks/vault files/counts, `Yes/No` confirm on delete.
* Prioritize: `▲ ▼` on hover (plain + kanban) → `moveTaskUp/Down` within `profile+column`, top-right `-` delete `z:10`.
* Sounds: `5.5M+94K WAV` → `142K+5K OGG` + `1.3M+23K WAV` fallback mono 22k, removed `QtQuick.Controls`, single timer + 30s mute — less CPU/IO/mem. Volume sliders `save+apply` on release.
* Vault: per-profile subfolders + `sanitizeProfileNameForPath`, all columns `⬆`→`↩` undo (`removeTaskFromVault` + `clearTaskPushed`), `[ ]` vs `[x]` per `Done`, `<!-- id -->` dedup, `Push all` per active profile, delete task also removes from vault, path `\\` escaped.
* UI: 2-col `SmallToggle`, `95px` sliders, per-column scroll, `580px` board `132px` cols `12px` gaps, left accent `3px` + `●` for active.
* Fixes: `sanitizeVaultPath` blocks `&|*?<>^(){}[]\\'"` + `\` escape, `syncSettingsFromShellJson` coerce, `..` blocks, `Alt+H/L` enable `panel.open` (was `root.opened` bug), `\\` escape in vault line.

## License
MIT — see `LICENSE`. `clock.ogg` © Focus Timer, `alarm.ogg` sample from YouTube grandfather clock — replace for fully libre build.

## Credits
Omarchy `omarchy-shell`/`Quickshell` (`qs.Commons`, `qs.Ui`), Focus Timer flatpak.
