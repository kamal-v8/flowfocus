// FocusFlow Model — pomodoro phase logic, task CRUD, persistence, sound.
//
// All state lives in a single JSON object persisted to
// ~/.local/state/omarchy/focusflow.json via FileView in BarWidget.qml.
// The QML side owns the FileView and calls Model.serialize/parse; this
// file stays pure JS so the logic is testable without QML.

var PHASE_WORK = "work"
var PHASE_SHORT_BREAK = "short-break"
var PHASE_LONG_BREAK = "long-break"

var STATUS_STOPPED = "stopped"
var STATUS_RUNNING = "running"
var STATUS_PAUSED = "paused"

var COLUMNS = ["backlog", "todo", "doing", "done"]
var COLUMN_LABELS = {
  "backlog": "Backlog",
  "todo": "To Do",
  "doing": "Doing",
  "done": "Done"
}

function defaultKanbanProfiles() {
  return [{ id: "default", name: "Default", createdAt: new Date().toISOString() }]
}

function defaultState() {
  return {
    version: 2,
    timer: {
      phase: PHASE_WORK,
      status: STATUS_STOPPED,
      phaseDurationSec: 1500,
      remainingSec: 1500,
      deadlineMs: 0,
      completedWorkPhases: 0,
      activeTaskId: null
    },
    tasks: [],
    kanbanProfiles: defaultKanbanProfiles(),
    activeKanbanProfileId: "default",
    settings: {
      workSec: 1500,
      shortBreakSec: 300,
      longBreakSec: 900,
      longBreakInterval: 4,
      tickEnabled: false,
      tickVolume: 0.3,
      alarmEnabled: true,
      alarmVolume: 0.5,
      soundMuted: false,
      kanbanMode: false,
      todoEnabled: true,
      kanbanEnabled: true,
      showPomodoros: true,
      autoStartBreaks: false,
      autoStartWork: false,
      notificationsEnabled: true,
      obsidianEnabled: false,
      obsidianVaultPath: ""
    }
  }
}

function genProfileId() {
  return "kp-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 6)
}

function getActiveProfileId(state) {
  return state.activeKanbanProfileId || "default"
}

function getProfileById(state, id) {
  for (var i=0;i<state.kanbanProfiles.length;i++) if (state.kanbanProfiles[i].id === id) return state.kanbanProfiles[i]
  return null
}

function getActiveProfile(state) {
  return getProfileById(state, getActiveProfileId(state)) || state.kanbanProfiles[0]
}

function setActiveKanbanProfile(state, id) {
  if (!getProfileById(state, id)) return state
  state.activeKanbanProfileId = id
  return state
}

function createKanbanProfile(state, name) {
  var cleaned = String(name||"").trim().slice(0,30)
  if (!cleaned) cleaned = "Untitled"
  if (state.kanbanProfiles.length >= 20) return state
  var p = { id: genProfileId(), name: cleaned, createdAt: new Date().toISOString() }
  state.kanbanProfiles.push(p)
  state.activeKanbanProfileId = p.id
  return state
}

function renameKanbanProfile(state, id, newName) {
  var cleaned = String(newName||"").trim().slice(0,30)
  if (!cleaned) return state
  for (var i=0;i<state.kanbanProfiles.length;i++) if (state.kanbanProfiles[i].id===id) { state.kanbanProfiles[i].name = cleaned; break }
  return state
}

function deleteKanbanProfile(state, id) {
  if (id === "default") return state
  if (state.kanbanProfiles.length <= 1) return state
  state.kanbanProfiles = state.kanbanProfiles.filter(function(p){ return p.id !== id })
  state.tasks = state.tasks.filter(function(t){ return t.profileId !== id })
  if (state.activeKanbanProfileId === id) state.activeKanbanProfileId = state.kanbanProfiles[0].id
  if (state.timer.activeTaskId) {
    var stillExists = state.tasks.some(function(t){ return t.id === state.timer.activeTaskId })
    if (!stillExists) state.timer.activeTaskId = null
  }
  return state
}

function tasksForProfile(state, profileId) {
  var pid = profileId || getActiveProfileId(state)
  return state.tasks.filter(function(t){ return (t.profileId || "default") === pid })
}

function tasksByColumnForProfile(state, column, profileId) {
  var pid = profileId || getActiveProfileId(state)
  return state.tasks.filter(function(t){ return t.column === column && (t.profileId || "default") === pid })
}

function parse(raw) {
  var fallback = defaultState()
  if (!raw) return fallback
  try {
    var parsed = JSON.parse(String(raw))
    if (!parsed || typeof parsed !== "object") return fallback
    return mergeDefaults(parsed, fallback)
  } catch (e) {
    return fallback
  }
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

function mergeDefaults(state, defaults) {
  var result = {
    version: 2,
    timer: isPlainObject(state.timer) ? Object.assign({}, defaults.timer, state.timer) : defaults.timer,
    tasks: Array.isArray(state.tasks) ? state.tasks : [],
    kanbanProfiles: Array.isArray(state.kanbanProfiles) ? state.kanbanProfiles.slice() : defaultKanbanProfiles(),
    activeKanbanProfileId: typeof state.activeKanbanProfileId === "string" ? state.activeKanbanProfileId : "default",
    settings: isPlainObject(state.settings) ? Object.assign({}, defaults.settings, state.settings) : defaults.settings
  }
  if ([PHASE_WORK, PHASE_SHORT_BREAK, PHASE_LONG_BREAK].indexOf(result.timer.phase) === -1) result.timer.phase = PHASE_WORK
  // sanitize numeric settings
  var s = result.settings
  s.workSec = Math.max(60, Math.min(18000, Number(s.workSec) || 1500))
  s.shortBreakSec = Math.max(30, Math.min(1500, Number(s.shortBreakSec) || 300))
  s.longBreakSec = Math.max(60, Math.min(3600, Number(s.longBreakSec) || 900))
  s.longBreakInterval = Math.max(1, Math.min(12, Math.floor(Number(s.longBreakInterval) || 4)))
  s.tickVolume = Math.max(0, Math.min(1, Number(s.tickVolume) || 0.3))
  if (s.alarmEnabled === undefined) s.alarmEnabled = true
  else s.alarmEnabled = !!s.alarmEnabled
  s.alarmVolume = Math.max(0, Math.min(1, Number(s.alarmVolume) || 0.5))
  if (s.soundMuted === undefined) s.soundMuted = false
  else s.soundMuted = !!s.soundMuted
  if (s.showPomodoros === undefined) s.showPomodoros = true
  else s.showPomodoros = !!s.showPomodoros
  if (s.obsidianEnabled === undefined) s.obsidianEnabled = false
  else s.obsidianEnabled = !!s.obsidianEnabled
  if (typeof s.obsidianVaultPath !== "string") s.obsidianVaultPath = ""
  else s.obsidianVaultPath = s.obsidianVaultPath.trim().slice(0, 500)
  // NOTE: settings.obsidianFile is retired since v1.5 (filenames are now
  // derived from the space name). A stale value may still ride along in
  // saved state; it is only used to locate legacy files for migration.
  // sanitize kanban profiles
  result.kanbanProfiles = result.kanbanProfiles.filter(function(p){ return p && typeof p.name === "string" && p.name.trim().length>0 && typeof p.id === "string" && p.id.trim().length>0 }).slice(0, 20)
  if (result.kanbanProfiles.length === 0) result.kanbanProfiles = defaultKanbanProfiles()
  // ensure default profile exists
  var hasDefault = result.kanbanProfiles.some(function(p){ return p.id === "default" })
  if (!hasDefault) result.kanbanProfiles.unshift({ id: "default", name: "Default", createdAt: new Date().toISOString() })
  for (var pi=0; pi<result.kanbanProfiles.length; pi++) {
    var pr = result.kanbanProfiles[pi]
    pr.name = String(pr.name).trim().slice(0, 30)
    if (!pr.name) pr.name = "Untitled"
    if (typeof pr.createdAt !== "string") pr.createdAt = new Date().toISOString()
  }
  // dedup ids
  var seenIds = {}
  result.kanbanProfiles = result.kanbanProfiles.filter(function(p){ if (seenIds[p.id]) return false; seenIds[p.id]=true; return true })
  var activeId = result.activeKanbanProfileId
  var activeExists = result.kanbanProfiles.some(function(p){ return p.id === activeId })
  if (!activeExists) result.activeKanbanProfileId = result.kanbanProfiles[0].id
  // sanitize tasks
  result.tasks = result.tasks.filter(function(t) {
    return t && typeof t.text === "string" && t.text.trim().length > 0
  }).slice(0, 200)
  // normalize task fields
  for (var i = 0; i < result.tasks.length; i++) {
    var t = result.tasks[i]
    if (COLUMNS.indexOf(t.column) === -1) t.column = "todo"
    t.done = !!t.done
    if (typeof t.pomodorosSpent !== "number") t.pomodorosSpent = 0
    if (typeof t.pomodorosEstimated !== "number") t.pomodorosEstimated = 1
    if (typeof t.pushedToObsidian !== "boolean") t.pushedToObsidian = !!t.pushedToObsidian
    if (t.pushedAt && typeof t.pushedAt !== "string") t.pushedAt = null
    if (t.pushedColumn && typeof t.pushedColumn !== "string") t.pushedColumn = null
    if (t.pushedColumn && COLUMNS.indexOf(t.pushedColumn) === -1) t.pushedColumn = null
    if (typeof t.profileId !== "string" || !t.profileId.trim() || !seenIds[t.profileId]) {
      t.profileId = result.activeKanbanProfileId
    }
  }
  // sanitize timer
  var tm = result.timer
  if ([STATUS_STOPPED, STATUS_RUNNING, STATUS_PAUSED].indexOf(tm.status) === -1) tm.status = STATUS_STOPPED
  tm.remainingSec = Math.max(0, Math.min(18000, Math.floor(Number(tm.remainingSec) || s.workSec)))
  tm.phaseDurationSec = Math.max(1, Math.min(18000, Math.floor(Number(tm.phaseDurationSec) || s.workSec)))
  tm.completedWorkPhases = Math.max(0, Math.floor(Number(tm.completedWorkPhases) || 0))
  return result
}

function serialize(state) {
  return JSON.stringify(state, null, 2) + "\n"
}

function phaseDurationSec(phase, settings) {
  if (phase === PHASE_WORK) return settings.workSec
  if (phase === PHASE_SHORT_BREAK) return settings.shortBreakSec
  if (phase === PHASE_LONG_BREAK) return settings.longBreakSec
  return settings.workSec
}

function nextPhase(completedWorkPhases, settings) {
  if (completedWorkPhases > 0 && completedWorkPhases % settings.longBreakInterval === 0)
    return PHASE_LONG_BREAK
  return PHASE_SHORT_BREAK
}

function phaseLabel(phase) {
  if (phase === PHASE_WORK) return "Work"
  if (phase === PHASE_SHORT_BREAK) return "Short Break"
  if (phase === PHASE_LONG_BREAK) return "Long Break"
  return "Work"
}

function phaseColor(phase, accent, muted, urgent) {
  if (phase === PHASE_WORK) return accent
  if (phase === PHASE_LONG_BREAK) return urgent
  return muted
}

function formatTime(totalSec) {
  var sec = Math.max(0, Math.floor(totalSec))
  var m = Math.floor(sec / 60)
  var s = sec % 60
  return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
}

function nowMs() {
  return Date.now()
}

function remainingFromDeadline(deadlineMs) {
  if (!deadlineMs) return 0
  return Math.max(0, Math.round((deadlineMs - nowMs()) / 1000))
}

function startTimer(state) {
  var t = state.timer
  var dur = phaseDurationSec(t.phase, state.settings)
  t.phaseDurationSec = dur
  t.remainingSec = dur
  t.deadlineMs = nowMs() + dur * 1000
  t.status = STATUS_RUNNING
  return state
}

function pauseTimer(state) {
  var t = state.timer
  if (t.status !== STATUS_RUNNING) return state
  t.remainingSec = remainingFromDeadline(t.deadlineMs)
  t.deadlineMs = 0
  t.status = STATUS_PAUSED
  return state
}

function resumeTimer(state) {
  var t = state.timer
  if (t.status !== STATUS_PAUSED) return state
  t.deadlineMs = nowMs() + t.remainingSec * 1000
  t.status = STATUS_RUNNING
  return state
}

function resetTimer(state) {
  var t = state.timer
  t.status = STATUS_STOPPED
  t.deadlineMs = 0
  t.remainingSec = phaseDurationSec(t.phase, state.settings)
  t.phaseDurationSec = t.remainingSec
  return state
}

function skipPhase(state) {
  var t = state.timer
  if (t.phase === PHASE_WORK) {
    t.completedWorkPhases++
    var np = nextPhase(t.completedWorkPhases, state.settings)
    t.phase = np
  } else {
    t.phase = PHASE_WORK
  }
  return resetTimer(state)
}

function completePhase(state) {
  var t = state.timer
  var finishedPhase = t.phase
  if (finishedPhase === PHASE_WORK) {
    t.completedWorkPhases++
    if (t.activeTaskId) incrementTaskPomodoro(state, t.activeTaskId)
    t.phase = nextPhase(t.completedWorkPhases, state.settings)
  } else {
    t.phase = PHASE_WORK
  }
  t.status = STATUS_STOPPED
  t.deadlineMs = 0
  t.remainingSec = phaseDurationSec(t.phase, state.settings)
  t.phaseDurationSec = t.remainingSec
  return { state: state, finishedPhase: finishedPhase }
}

function tick(state) {
  var t = state.timer
  if (t.status !== STATUS_RUNNING) return { state: state, phaseEnded: false }
  var rem = remainingFromDeadline(t.deadlineMs)
  t.remainingSec = rem
  if (rem <= 0) {
    var result = completePhase(state)
    return { state: result.state, phaseEnded: true, finishedPhase: result.finishedPhase }
  }
  return { state: state, phaseEnded: false }
}

function shouldAutoStart(state) {
  var t = state.timer
  if (t.phase === PHASE_WORK) return state.settings.autoStartWork
  return state.settings.autoStartBreaks
}

function progress(state) {
  var t = state.timer
  var dur = t.phaseDurationSec || phaseDurationSec(t.phase, state.settings)
  if (dur <= 0) return 0
  return Math.max(0, Math.min(1, 1 - (t.remainingSec / dur)))
}

function genId() {
  return "ff-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8)
}

function addTask(state, text, column, profileId) {
  var cleaned = String(text || "").trim().slice(0, 200)
  if (!cleaned) return state
  if (state.tasks.length >= 200) return state
  var col = column || "todo"
  if (COLUMNS.indexOf(col) === -1) col = "todo"
  var pid = profileId || getActiveProfileId(state)
  if (!getProfileById(state, pid)) pid = getActiveProfileId(state)
  var task = {
    id: genId(),
    text: cleaned,
    column: col,
    done: col === "done",
    profileId: pid,
    pomodorosSpent: 0,
    pomodorosEstimated: 1,
    pushedToObsidian: false,
    pushedAt: null,
    createdAt: new Date().toISOString()
  }
  state.tasks.push(task)
  return state
}

function updateTask(state, id, changes) {
  for (var i = 0; i < state.tasks.length; i++) {
    if (state.tasks[i].id === id) {
      for (var key in changes) state.tasks[i][key] = changes[key]
      break
    }
  }
  return state
}

function deleteTask(state, id) {
  state.tasks = state.tasks.filter(function(t) { return t.id !== id })
  if (state.timer.activeTaskId === id) state.timer.activeTaskId = null
  return state
}

function moveTask(state, id, column) {
  if (COLUMNS.indexOf(column) === -1) return state
  for (var i = 0; i < state.tasks.length; i++) {
    if (state.tasks[i].id === id) {
      state.tasks[i].column = column
      state.tasks[i].done = column === "done"
      break
    }
  }
  return state
}

function moveTaskUp(state, id) {
  var idx = -1
  for (var i=0;i<state.tasks.length;i++) if (state.tasks[i].id===id) { idx=i; break }
  if (idx<0) return state
  var task = state.tasks[idx]
  var pid = task.profileId || "default"
  var col = task.column
  // collect indices in same profile+col in order
  var indices=[]
  for (var j=0;j<state.tasks.length;j++) {
    var t=state.tasks[j]
    if ((t.profileId||"default")===pid && t.column===col) indices.push(j)
  }
  var pos=indices.indexOf(idx)
  if (pos<=0) return state
  var prevIdx=indices[pos-1]
  var tmp=state.tasks[idx]
  state.tasks[idx]=state.tasks[prevIdx]
  state.tasks[prevIdx]=tmp
  return state
}

function moveTaskDown(state, id) {
  var idx=-1
  for (var i=0;i<state.tasks.length;i++) if (state.tasks[i].id===id) { idx=i; break }
  if (idx<0) return state
  var task=state.tasks[idx]
  var pid=task.profileId || "default"
  var col=task.column
  var indices=[]
  for (var j=0;j<state.tasks.length;j++) {
    var t=state.tasks[j]
    if ((t.profileId||"default")===pid && t.column===col) indices.push(j)
  }
  var pos=indices.indexOf(idx)
  if (pos<0 || pos>=indices.length-1) return state
  var nextIdx=indices[pos+1]
  var tmp=state.tasks[idx]
  state.tasks[idx]=state.tasks[nextIdx]
  state.tasks[nextIdx]=tmp
  return state
}

function cycleKanbanProfile(state, dir) {
  if (!state.kanbanProfiles || state.kanbanProfiles.length<=1) return state
  var cur = getActiveProfileId(state)
  var idx=-1
  for (var i=0;i<state.kanbanProfiles.length;i++) if (state.kanbanProfiles[i].id===cur) { idx=i; break }
  if (idx<0) idx=0
  var next = (idx + dir + state.kanbanProfiles.length) % state.kanbanProfiles.length
  state.activeKanbanProfileId = state.kanbanProfiles[next].id
  return state
}

function toggleTaskDone(state, id) {
  for (var i = 0; i < state.tasks.length; i++) {
    if (state.tasks[i].id === id) {
      var done = !state.tasks[i].done
      state.tasks[i].done = done
      state.tasks[i].column = done ? "done" : "todo"
      break
    }
  }
  return state
}

function incrementTaskPomodoro(state, id) {
  for (var i = 0; i < state.tasks.length; i++) {
    if (state.tasks[i].id === id) {
      state.tasks[i].pomodorosSpent++
      break
    }
  }
  return state
}

function setActiveTask(state, id) {
  state.timer.activeTaskId = (id === state.timer.activeTaskId) ? null : id
  return state
}

function markTaskPushed(state, id) {
  for (var i = 0; i < state.tasks.length; i++) {
    if (state.tasks[i].id === id) {
      state.tasks[i].pushedToObsidian = true
      state.tasks[i].pushedAt = new Date().toISOString()
      state.tasks[i].pushedColumn = state.tasks[i].column
      break
    }
  }
  return state
}

function clearTaskPushed(state, id) {
  for (var i = 0; i < state.tasks.length; i++) {
    if (state.tasks[i].id === id) {
      state.tasks[i].pushedToObsidian = false
      state.tasks[i].pushedAt = null
      state.tasks[i].pushedColumn = null
      break
    }
  }
  return state
}

function removeTaskFromVault(pluginDir, settings, task, vaultPath, profileName) {
  if (!task || !task.id) return false
  var vp = expandVaultPath(settings, vaultPath)
  if (!vp) return false
  var pid = String(task.profileId || "default")
  var pName = profileName
  if (pName === undefined) pName = pid === "default" ? "Default" : pid
  // strip from the new per-space file and, just in case, from a legacy file
  var files = [obsidianFilePathForProfile(settings, vp, pid, pName)]
  var legacy = obsidianLegacyFile(settings, vp, pid, pName)
  if (legacy && legacy !== files[0]) files.push(legacy)
  var idTag = "<!-- " + task.id + " -->"
  var escId = idTag.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  var cmd = ""
  for (var i = 0; i < files.length; i++) {
    if (!files[i]) continue
    var escFile = files[i].replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    if (i > 0) cmd += "; "
    cmd += "if [ -e \"" + escFile + "\" ]; then grep -v -F \"" + escId + "\" \"" + escFile + "\" > \"" + escFile + ".tmp\" && mv \"" + escFile + ".tmp\" \"" + escFile + "\"; fi"
  }
  if (!cmd) return false
  Quickshell.execDetached(["bash", "-c", cmd])
  return true
}

function tasksByColumn(state, column, profileId) {
  var pid = profileId || getActiveProfileId(state)
  return state.tasks.filter(function(t) { return t.column === column && (t.profileId || "default") === pid })
}

function incompleteTasks(state, profileId) {
  var pid = profileId || getActiveProfileId(state)
  return state.tasks.filter(function(t) { return !t.done && (t.profileId || "default") === pid })
}

function nextTask(state, profileId) {
  var incomplete = incompleteTasks(state, profileId)
  if (incomplete.length === 0) return null
  var doing = incomplete.filter(function(t) { return t.column === "doing" })
  if (doing.length > 0) return doing[0]
  var todo = incomplete.filter(function(t) { return t.column === "todo" })
  if (todo.length > 0) return todo[0]
  return incomplete[0]
}

function sanitizePluginDir(dir) {
  if (!dir || typeof dir !== "string") return ""
  // prevent path injection, allow only safe chars
  if (dir.indexOf("..") !== -1) return ""
  return dir
}

function tickSoundPath(pluginDir) {
  var safe = sanitizePluginDir(pluginDir)
  if (!safe) return ""
  return safe + "/sounds/tick.ogg"
}

function alarmSoundPath(pluginDir) {
  var safe = sanitizePluginDir(pluginDir)
  if (!safe) return ""
  return safe + "/sounds/alarm.ogg"
}

function tickWavPath(pluginDir) {
  var safe = sanitizePluginDir(pluginDir)
  if (!safe) return ""
  return safe + "/sounds/tick.wav"
}

function alarmWavPath(pluginDir) {
  var safe = sanitizePluginDir(pluginDir)
  if (!safe) return ""
  return safe + "/sounds/alarm.wav"
}

function playTick(pluginDir, volume) {
  var vol = Math.max(0, Math.min(1, Number(volume) || 0))
  if (vol <= 0) return
  var p = tickSoundPath(pluginDir)
  var fallback = tickWavPath(pluginDir)
  if (!p) return
  // try ogg then wav (pw-play handles both, paplay fallback for pulse)
  Quickshell.execDetached(["bash", "-c", "pw-play --volume " + String(vol) + " \"" + p.replace(/"/g, '\\"') + "\" 2>/dev/null || pw-play --volume " + String(vol) + " \"" + fallback.replace(/"/g, '\\"') + "\" 2>/dev/null || paplay --volume " + Math.round(vol*65536) + " \"" + p.replace(/"/g, '\\"') + "\" 2>/dev/null || true"])
}

function playCompleteSound(pluginDir, volume) {
  var vol = Math.max(0, Math.min(1, Number(volume) || 0.5))
  if (vol === 0) return
  var p = alarmSoundPath(pluginDir)
  var fallback = alarmWavPath(pluginDir)
  if (!p) return
  Quickshell.execDetached(["bash", "-c", "pw-play --volume " + String(vol) + " \"" + p.replace(/"/g, '\\"') + "\" 2>/dev/null || pw-play --volume " + String(vol) + " \"" + fallback.replace(/"/g, '\\"') + "\" 2>/dev/null || paplay --volume " + Math.round(vol*65536) + " \"" + p.replace(/"/g, '\\"') + "\" 2>/dev/null || true"])
}

function stopAllSounds(pluginDir) {
  // Immediately silence any tick/alarm currently playing.
  // pw-play/paplay are fire-and-forget, so kill by our sounds-dir path fragment.
  var safe = sanitizePluginDir(pluginDir)
  if (!safe) return
  var base = safe.split("/").pop() || "flowfocus"
  var pattern = base.replace(/[^a-zA-Z0-9_-]/g, "_") + "/sounds"
  Quickshell.execDetached(["bash", "-c", "pkill -f \"" + pattern + "\" 2>/dev/null || true"])
}

function notificationArgs(headline, body) {
  // Prefer the Omarchy notifier; fall back to plain notify-send when
  // OMARCHY_PATH is unset so notifications still work on any setup.
  var omarchyPath = Quickshell.env("OMARCHY_PATH") || ""
  var bin = omarchyPath ? omarchyPath + "/bin/omarchy-notification-send" : "notify-send"
  var args = [bin, "--app-name", "FocusFlow"]
  if (headline) args.push(headline)
  if (body) args.push(body)
  return args
}

function sendNotification(state, headline, body) {
  if (!state.settings.notificationsEnabled) return
  Quickshell.execDetached(notificationArgs(headline, body))
}

function sanitizeVaultPath(p) {
  if (!p || typeof p !== "string") return ""
  var s = p.trim()
  if (!s) return ""
  if (s.indexOf("..") !== -1) return ""
  if (s.length > 500) s = s.slice(0, 500)
  // block shell metachars: ; & | $ ` * ? < > ^ ( ) { } [ ] \ ' " newline — vault path should be plain filesystem path
  if (/[;\n`$&|*?<>^(){}[\]\\'"]/.test(s)) return ""
  // allow only printable safe chars (path safe) — reject control chars
  if (/[\x00-\x1F\x7F]/.test(s)) return ""
  return s
}

function sanitizeProfileNameForPath(name) {
  var s = String(name || "Default").trim().slice(0, 30)
  if (!s) s = "Default"
  s = s.replace(/[\/\\]/g, "_").replace(/[^a-zA-Z0-9 _-]/g, "_").replace(/\s+/g, "_")
  if (!s) s = "Default"
  return s.slice(0, 30)
}

// All FocusFlow vault data lives under <vault>/focusflow/, one file per
// kanban space: focusflow/Default.md, focusflow/<Space>.md, ...
// (This replaced the pre-v1.5 layout: base FlowFocus.md + per-space
// subfolders. Old files are moved over automatically on first write.)
var VAULT_SUBDIR = "focusflow"

function expandVaultPath(settings, vaultPath) {
  var vp = sanitizeVaultPath(vaultPath !== undefined ? vaultPath : settings.obsidianVaultPath)
  if (!vp) return ""
  var home = Quickshell.env("HOME") || ""
  if (vp.startsWith("~/")) vp = home + vp.slice(1)
  else if (vp === "~") vp = home
  // Bare relative paths (e.g. "Documents/notes") resolve against the shell's
  // cwd, which varies per device — anchor them at $HOME instead.
  else if (vp.charAt(0) !== "/" && home) vp = home + "/" + vp
  return vp
}

function profileFileName(profileId, profileName) {
  var pid = String(profileId || "default")
  var name = (pid === "default") ? "Default" : sanitizeProfileNameForPath(profileName || pid)
  // avoid collision if a custom space is literally named "Default"
  if (pid !== "default" && name.toLowerCase() === "default")
    name = name + "_" + pid.replace(/[^a-zA-Z0-9]/g, "").slice(-4)
  return name + ".md"
}

function obsidianFilePathForProfile(settings, vaultPath, profileId, profileName) {
  var vp = expandVaultPath(settings, vaultPath)
  if (!vp) return ""
  var dir = vp.endsWith("/") ? vp + VAULT_SUBDIR : vp + "/" + VAULT_SUBDIR
  return dir + "/" + profileFileName(profileId, profileName)
}

// Legacy locations from before v1.5 (base file + per-space subfolders).
// Only used to find files worth migrating; obsidianFile is otherwise retired.
function obsidianLegacyFile(settings, vpExpanded, profileId, profileName) {
  if (!vpExpanded) return ""
  var file = settings.obsidianFile || "FlowFocus.md"
  file = String(file).trim() || "FlowFocus.md"
  file = file.replace(/[\/\\]/g, "_").slice(0, 100)
  if (!file.toLowerCase().endsWith(".md")) file += ".md"
  var pid = String(profileId || "default")
  var sep = vpExpanded.endsWith("/") ? "" : "/"
  if (pid === "default") return vpExpanded + sep + file
  var sanitized = sanitizeProfileNameForPath(profileName || pid)
  return vpExpanded + sep + sanitized + "/" + file
}

function migrationSnippet(settings, vpExpanded, profileId, profileName) {
  // One-time move snippet: legacy file -> focusflow/<Space>.md, and only when
  // the new file doesn't exist yet, so we never clobber or duplicate content.
  // Returned as shell code so callers run it in the SAME bash invocation as
  // their write (two execDetached calls could race each other).
  var pid = String(profileId || "default")
  var file = obsidianFilePathForProfile(settings, vpExpanded, pid, profileName)
  if (!file) return { file: "", prefix: "" }
  var legacy = obsidianLegacyFile(settings, vpExpanded, pid, profileName)
  if (!legacy || legacy === file) return { file: file, prefix: "" }
  var escFile = file.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  var escLegacy = legacy.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  var prefix = "if [ ! -e \"" + escFile + "\" ] && [ -e \"" + escLegacy + "\" ]; then "
      + "mkdir -p \"$(dirname -- \"" + escFile + "\")\" && mv \"" + escLegacy + "\" \"" + escFile + "\"; "
      + "rmdir \"$(dirname -- \"" + escLegacy + "\")\" 2>/dev/null || true; fi; "
  return { file: file, prefix: prefix }
}

function migrateProfileVaultFile(settings, vpExpanded, profileId, profileName) {
  var r = migrationSnippet(settings, vpExpanded, profileId, profileName)
  if (!r.file) return ""
  if (r.prefix) Quickshell.execDetached(["bash", "-c", r.prefix + "true"])
  return r.file
}

function appendTaskToVault(pluginDir, settings, task, vaultPath, profileName) {
  if (!settings.obsidianEnabled) return false
  var vp = expandVaultPath(settings, vaultPath)
  if (!vp) return false
  // one file per space under focusflow/: Default.md, <Space>.md, ...
  var pid = String(task.profileId || "default")
  var pName = profileName
  if (pName === undefined) pName = pid === "default" ? "Default" : pid
  var mig = migrationSnippet(settings, vp, pid, pName)
  if (!mig.file) return false
  var now = new Date()
  var date = now.toISOString().slice(0,10)
  var time = now.toTimeString().slice(0,5)
  var text = String(task.text || "").replace(/\\/g, "\\\\").replace(/"/g, "'").replace(/\n/g, " ").slice(0,200)
  var col = String(task.column || "todo")
  if (COLUMNS.indexOf(col) === -1) col = "todo"
  var label = COLUMN_LABELS[col] || col
  var isDone = task.done === true || col === "done"
  var idTag = "<!-- " + task.id + " -->"
  var line = "- [" + (isDone ? "x" : " ") + "] " + text + " [" + label + "] — " + date + " " + time + " " + idTag
  var escFile = mig.file.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  var escLine = line.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$").replace(/`/g, "\\`")
  var escId = idTag.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
  // single bash invocation: migrate first, then idempotent append (no race)
  var cmd = mig.prefix
      + "mkdir -p \"$(dirname -- \"" + escFile + "\")\" && touch \"" + escFile + "\" && "
      + "grep -v -F \"" + escId + "\" \"" + escFile + "\" > \"" + escFile + ".tmp\" && mv \"" + escFile + ".tmp\" \"" + escFile + "\"; "
      + "printf '%s\\n' \"" + escLine + "\" >> \"" + escFile + "\""
  Quickshell.execDetached(["bash", "-c", cmd])
  return true
}

if (typeof module !== "undefined") {
  module.exports = {
    PHASE_WORK: PHASE_WORK,
    PHASE_SHORT_BREAK: PHASE_SHORT_BREAK,
    PHASE_LONG_BREAK: PHASE_LONG_BREAK,
    STATUS_STOPPED: STATUS_STOPPED,
    STATUS_RUNNING: STATUS_RUNNING,
    STATUS_PAUSED: STATUS_PAUSED,
    COLUMNS: COLUMNS,
    COLUMN_LABELS: COLUMN_LABELS,
    defaultState: defaultState,
    defaultKanbanProfiles: defaultKanbanProfiles,
    parse: parse,
    serialize: serialize,
    phaseDurationSec: phaseDurationSec,
    nextPhase: nextPhase,
    phaseLabel: phaseLabel,
    phaseColor: phaseColor,
    formatTime: formatTime,
    startTimer: startTimer,
    pauseTimer: pauseTimer,
    resumeTimer: resumeTimer,
    resetTimer: resetTimer,
    skipPhase: skipPhase,
    completePhase: completePhase,
    tick: tick,
    shouldAutoStart: shouldAutoStart,
    progress: progress,
    genId: genId,
    genProfileId: genProfileId,
    getActiveProfileId: getActiveProfileId,
    getProfileById: getProfileById,
    getActiveProfile: getActiveProfile,
    setActiveKanbanProfile: setActiveKanbanProfile,
    createKanbanProfile: createKanbanProfile,
    renameKanbanProfile: renameKanbanProfile,
    deleteKanbanProfile: deleteKanbanProfile,
    tasksForProfile: tasksForProfile,
    tasksByColumnForProfile: tasksByColumnForProfile,
    addTask: addTask,
    updateTask: updateTask,
    deleteTask: deleteTask,
    moveTask: moveTask,
    moveTaskUp: moveTaskUp,
    moveTaskDown: moveTaskDown,
    cycleKanbanProfile: cycleKanbanProfile,
    toggleTaskDone: toggleTaskDone,
    setActiveTask: setActiveTask,
    tasksByColumn: tasksByColumn,
    incompleteTasks: incompleteTasks,
    nextTask: nextTask,
    tickSoundPath: tickSoundPath,
    alarmSoundPath: alarmSoundPath,
    playTick: playTick,
    playCompleteSound: playCompleteSound,
    stopAllSounds: stopAllSounds,
    sendNotification: sendNotification,
    sanitizeVaultPath: sanitizeVaultPath,
    sanitizeProfileNameForPath: sanitizeProfileNameForPath,
    obsidianFilePathForProfile: obsidianFilePathForProfile,
    obsidianLegacyFile: obsidianLegacyFile,
    migrateProfileVaultFile: migrateProfileVaultFile,
    appendTaskToVault: appendTaskToVault,
    markTaskPushed: markTaskPushed,
    clearTaskPushed: clearTaskPushed,
    removeTaskFromVault: removeTaskFromVault
  }
}
