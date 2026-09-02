# flowfocus v1.2.0 — polished, lightweight

Pomodoro timer + To-Do (plain / Kanban) for [Omarchy](https://omarchy.org) — single bar widget, rich popup, minimal resource footprint.

![Flowfocus Preview](assets/preview.png)

* **Pomodoro cycle** — Work / Short break / Long break (default `25/5/15` min, every 4 cycles), pause/resume/reset/skip, cycle counter, deadline-based math survives bar reloads. Single `1000ms` tick timer; ticks muted 30s during alarm to avoid overlap in continuous mode.
* **Sound (lightweight)** — `tick.ogg` (5.3K mono 22k) + `alarm.ogg` (142K mono 22k) — was `5.6M` WAV. Played via `pw-play --volume` with path sanitization (`..` rejected). `tick` every second when enabled, `alarm` once on phase end.
* **To-Do** — plain list or Kanban (`Backlog / To Do / Doing / Done`, `124px` cols in `520px` board, horizontal scroll, per-column vertical scroll for overflow). Plain: custom `18×18` checkbox. Both support `⬆` push to Obsidian. `Space` start/pause when panel focused.
* **Obsidian vault** — optional manual export of any column. Task → `- [ ] task [To Do] — YYYY-MM-DD HH:MM <!-- id -->` or `- [x]` if `Done`. Idempotent `grep -v <!-- id -->` prevents duplicates; `✓` state per-column, re-push allowed after `todo→done` to flip `[ ]→[x]`. `Push all` handles all pending.
* **Bar** — idle `` only; running ring + `MM:SS` (`accent` work, `muted` break, `urgent` long break). `SUPER + SHIFT + T` toggles popup.
* **Compact UI** — `SmallToggle` `32px` rows (was `54px` cards) in 2-col grid, `PanelSlider 95px` (was full-width), timing sliders side-by-side, vault path+file inline, scrollbars removed (`Flickable` only). Outer kanban capped `200/300px`, columns `150/240px` vertical scroll; plain list capped `220/320px`.

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
* `tick.ogg` — 0.5s mono 22k vorbis from `clock.ogg` (Focus Timer flatpak). `alarm.ogg` — 30.01s mono 22k from `s8E_Ggf_QsQ` (grandfather clock) via `yt-dlp --download-sections` + `ffmpeg -ac 1 -ar 22050 -c:a libvorbis -q:a 3`. Play: `pw-play --volume 0.5 ~/.config/omarchy/plugins/flowfocus/sounds/alarm.ogg`.

## IPC
```bash
qs ipc -n -p "$OMARCHY_PATH/shell" call flowfocus togglePanel
qs ipc -n -p "$OMARCHY_PATH/shell" call flowfocus {start,pause,resume,toggle,reset,skip,open,close}
```

## Security
* `Model.sanitizePluginDir` blocks `..`; `sanitizeVaultPath` blocks `..`/`;`/`&`/`|`/`$`/`\``/`*`/`?`/`<>`/`^()`/`{}`/`[]`/`\`/`'`/`"`/control chars, 500 chars, vault file `_/\\`→`_`. Task text `trim` 200, `replace "→'` and `$/\`` escaped before `bash -c` `printf`. Task `column` whitelisted, `done` bool-coerced. All writes `FileView atomicWrites`.

## Development
```bash
omarchy plugin validate ~/.config/omarchy/plugins/flowfocus
omarchy restart shell
```
* `BarWidget.qml` — `FileView` + single `tickTimer 1000ms` + `alarmMuteTimer 30000ms`, `Model.tick` deadline, `JSON.parse(JSON.stringify(state))` to trigger QML.
* `Panel.qml` — `KeyboardPanel` (no extra `BorderSurface`), `Flickable` per-column, `SmallToggle: Item 32px`.
* `Model.js` — pure: `defaultState/parse/serialize`, `phaseDurationSec/tick/progress`, task CRUD + `pushedToObsidian/pushedColumn`, `playTick/alarm` with sanitized `tick.ogg/alarm.ogg`, `appendTaskToVault` idempotent.

## Changelog v1.2.0 (polished)
* Sounds: `5.5M+94K WAV` → `142K+5K OGG` mono 22k, removed `QtQuick.Controls` (ScrollBar), single timer + 30s mute — less CPU/IO/mem.
* Vault: all columns manual `⬆`→`✓`, `[ ]` vs `[x]` per `Done`, `<!-- id -->` dedup, `Push all` pending `!pushed||pushedColumn!==column`, path sanitized, `grep -v` idempotent.
* UI: 2-col `SmallToggle`, `95px` sliders, per-column vertical scroll, capped heights, no `ScrollBar` chrome.
* Fixes: mergeDefaults `COLUMNS.indexOf=== -1`, `addTask` trim, `syncSettingsFromShellJson` coerce, checkbox `NaN`, `X` overflow, `71px→124px` kanban, gear collapsed, `tick+alarm` overlap muted, todo overflow invisible fixed.

## License
MIT — see `LICENSE`. `clock.ogg` © Focus Timer, `alarm.ogg` sample from YouTube grandfather clock — replace for fully libre build.

## Credits
Omarchy `omarchy-shell`/`Quickshell` (`qs.Commons`, `qs.Ui`), Focus Timer flatpak.
