import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// FocusFlow bar widget.
//
// Idle: shows a tomato icon only — clean and minimal.
// Running: shows a progress ring around the icon + countdown text.
// The popup panel (Panel.qml) holds the full timer controls and task list.
//
// State is persisted to ~/.local/state/omarchy/focusflow.json via FileView.
// The FileView reads on load; every mutation calls saveState() which writes
// the full JSON atomically.
BarWidget {
  id: root
  moduleName: "flowfocus"

  // ---- Paths ----
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string statePath: stateHome + "/omarchy/focusflow.json"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/+$/, "")

  // ---- State ----
  property var state: Model.defaultState()
  property bool loaded: false

  // ---- Derived timer values ----
  readonly property var timer: state.timer
  readonly property var ffSettings: state.settings
  readonly property bool isRunning: timer.status === Model.STATUS_RUNNING
  readonly property bool isPaused: timer.status === Model.STATUS_PAUSED
  readonly property bool isStopped: timer.status === Model.STATUS_STOPPED
  readonly property string phase: timer.phase
  readonly property int remainingSec: timer.remainingSec
  readonly property real timerProgress: Model.progress(state)
  // Theme-safe: never Color.muted (near-invisible on light themes like rose-pine).
  readonly property color dimText: Qt.darker(Color.foreground, 1.4)
  readonly property color phaseColor: Model.phaseColor(phase, Color.accent, dimText, Color.urgent)
  readonly property string displayText: Model.formatTime(remainingSec)
  readonly property var activeTask: {
    var id = timer.activeTaskId
    if (!id) return null
    for (var i = 0; i < state.tasks.length; i++) {
      if (state.tasks[i].id === id) return state.tasks[i]
    }
    return null
  }

  // ---- Persistence ----
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    // NOTE: atomicWrites must stay OFF — atomic rename swaps the inode and
    // permanently detaches inotify watchers (frozen display + lost updates).
    atomicWrites: false
    printErrors: false
    onLoaded: {
      root.state = Model.parse(text())
      root.loaded = true
      root.syncSettingsFromShellJson()
      root.applyTickState()
    }
    onTextChanged: {
      // External writer (overlay) changed the file — adopt it so the next
      // tick or action never clobbers it. Own saves re-parse harmlessly.
      // parseOrNull: torn writes are ignored, never adopted.
      if (root.loaded) {
        var ext = Model.parseOrNull(text())
        if (ext) root.state = ext
      }
    }
    // Per the FileView contract, watched content only refreshes via
    // reload() — without this, text() serves the load-time snapshot forever.
    onFileChanged: reload()
  }

  function saveState() {
    if (!root.loaded) return
    stateFile.setText(Model.serialize(root.state))
  }

  // Pull shell.json inline settings (workSec etc.) into state.settings so
  // the panel reflects what the user configured in the bar settings UI.
  function syncSettingsFromShellJson() {
    var s = root.state.settings
    var keys = ["workSec", "shortBreakSec", "longBreakSec", "longBreakInterval",
                "tickEnabled", "tickVolume", "alarmEnabled", "alarmVolume", "soundMuted", "kanbanMode", "todoEnabled", "kanbanEnabled", "showPomodoros", "autoStartBreaks",
                "autoStartWork", "notificationsEnabled", "obsidianEnabled", "obsidianVaultPath"]
    var changed = false
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var val = root.setting(key, undefined)
      if (val === undefined || val === null) continue
      // coerce numeric types from shell.json schema (int/real may come as number or string)
      if (["workSec","shortBreakSec","longBreakSec","longBreakInterval"].indexOf(key) !== -1) val = Math.floor(Number(val))
      if (key === "tickVolume" || key === "alarmVolume") val = Number(val)
      if (["tickEnabled","alarmEnabled","soundMuted","kanbanMode","todoEnabled","kanbanEnabled","showPomodoros","autoStartBreaks","autoStartWork","notificationsEnabled","obsidianEnabled"].indexOf(key) !== -1) val = !!val
      if (key === "obsidianVaultPath") {
        val = String(val || "")
        // An empty shell.json default must not wipe a path typed in the
        // panel — otherwise every settings sync / shell restart resets the
        // manually entered vault path back to "". shell.json still wins
        // whenever it actually holds a non-empty value.
        if (val === "" && s[key] !== "") continue
      }
      if (s[key] !== val) {
        s[key] = val
        changed = true
      }
    }
    if (changed) {
      if (root.isStopped) {
        root.state.timer.remainingSec = Model.phaseDurationSec(root.phase, s)
        root.state.timer.phaseDurationSec = root.state.timer.remainingSec
      }
      root.saveState()
      root.applyTickState()
    }
  }

  // ---- Timer ticking ----
  // alarm.wav is 30s long. While it plays we mute ticks, otherwise in
  // continuous mode the next phase's tick.wav overlaps the alarm.
  Timer {
    id: alarmMuteTimer
    interval: 30000
    repeat: false
  }

  Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: root.isRunning
    onTriggered: root.onTick()
  }

  function onTick() {
    // Re-read first: the overlay may have written since the last tick.
    // parseOrNull keeps memory state on torn reads (never adopt garbage).
    // Memory state is authoritative here: the file watch + reload keeps it
    // fresh, and re-reading text() mid-tick risks adopting a stale snapshot.
    var result = Model.tick(root.state)
    var phaseEnded = result.phaseEnded
    root.state = result.state

    if (phaseEnded) {
      var finished = result.finishedPhase
      var label = Model.phaseLabel(finished)
      var next = Model.phaseLabel(root.state.timer.phase)
      Model.sendNotification(root.state, label + " complete", "Time for " + next.toLowerCase())
      if (root.state.settings.alarmEnabled !== false && !root.state.settings.soundMuted) {
        alarmMuteTimer.restart()
        Model.playCompleteSound(root.pluginDir, root.state.settings.alarmVolume)
      }
      if (Model.shouldAutoStart(root.state)) {
        root.state = Model.startTimer(root.state)
      }
      // do NOT play tick on the same second as alarm
    } else {
      if (root.ffSettings.tickEnabled && !root.ffSettings.soundMuted && !alarmMuteTimer.running) {
        Model.playTick(root.pluginDir, root.ffSettings.tickVolume)
      }
    }

    root.saveState()
    root.applyTickState()
  }

  // Force a property refresh — QML doesn't see mutations inside the state
  // object, so we reassign to trigger bindings.
  function applyTickState() {
    root.state = JSON.parse(JSON.stringify(root.state))
  }

  // ---- Timer controls (called from Panel.qml and IPC) ----
  function startTimer() {
    root.state = Model.startTimer(root.state)
    root.saveState()
    root.applyTickState()
  }

  function pauseTimer() {
    root.state = Model.pauseTimer(root.state)
    root.saveState()
    root.applyTickState()
  }

  function resumeTimer() {
    root.state = Model.resumeTimer(root.state)
    root.saveState()
    root.applyTickState()
  }

  function toggleTimer() {
    if (root.isRunning) root.pauseTimer()
    else if (root.isPaused) root.resumeTimer()
    else root.startTimer()
  }

  function resetTimer() {
    root.state = Model.resetTimer(root.state)
    root.saveState()
    root.applyTickState()
  }

  function skipPhase() {
    root.state = Model.skipPhase(root.state)
    root.saveState()
    root.applyTickState()
  }

  // Master mute — silences tick + alarm AND kills any sound already playing.
  function toggleMute() {
    root.state.settings.soundMuted = !root.state.settings.soundMuted
    if (root.state.settings.soundMuted) Model.stopAllSounds(root.pluginDir)
    root.saveState()
    root.applyTickState()
  }

  // ---- Task controls ----
  function addTask(text, column) {
    root.state = Model.addTask(root.state, text, column)
    root.saveState()
    root.applyTickState()
  }

  function updateTask(id, changes) {
    root.state = Model.updateTask(root.state, id, changes)
    root.saveState()
    root.applyTickState()
  }

  function isNotesLinked() {
    return root.state.settings.obsidianEnabled === true
        && Model.expandVaultPath(root.state.settings, undefined) !== ""
  }

  function deleteTask(id) {
    // Removes from board AND from notes (by id tag) when a vault is linked.
    // Always attempts vault removal — grep -v is a harmless no-op when no
    // line exists, and removeTaskFromVault bails early with no vault path.
    var task = null
    for (var i = 0; i < root.state.tasks.length; i++) if (root.state.tasks[i].id === id) { task = root.state.tasks[i]; break }
    if (task) {
      var prof = Model.getProfileById(root.state, task.profileId || "default")
      var profName = prof ? prof.name : (task.profileId || "Default")
      Model.removeTaskFromVault(root.pluginDir, root.state.settings, task, undefined, profName)
    }
    root.state = Model.deleteTask(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  // Archive a finished (Done) task: ensure it exists in the notes file as
  // "- [x] ..." then remove it from the kanban board WITHOUT touching the
  // notes file. If the notes app isn't linked, falls back to a plain delete.
  // Returns true when the board entry was removed.
  function archiveDoneTask(id) {
    var task = null
    for (var j = 0; j < root.state.tasks.length; j++) if (root.state.tasks[j].id === id) { task = root.state.tasks[j]; break }
    if (!task) return false
    if (!isNotesLinked()) {
      root.state = Model.deleteTask(root.state, id)
      root.saveState()
      root.applyTickState()
      return true
    }
    var aprof = Model.getProfileById(root.state, task.profileId || "default")
    var aprofName = aprof ? aprof.name : (task.profileId || "Default")
    // Force the Done appearance in the vault even if the board row drifted.
    var snapshot = JSON.parse(JSON.stringify(task))
    snapshot.column = "done"
    snapshot.done = true
    var ok = Model.appendTaskToVault(root.pluginDir, root.state.settings, snapshot, undefined, aprofName)
    if (!ok) {
      Model.sendNotification(root.state, "Notes folder not configured", "Set notes path in Settings")
      return false
    }
    root.state = Model.deleteTask(root.state, id)
    root.saveState()
    root.applyTickState()
    Model.sendNotification(root.state, "Archived ✓", task.text.slice(0, 60) + " [x] → " + aprofName)
    return true
  }

  function moveTask(id, column) {
    root.state = Model.moveTask(root.state, id, column)
    root.saveState()
    root.applyTickState()
  }

  function moveTaskUp(id) {
    root.state = Model.moveTaskUp(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function moveTaskDown(id) {
    root.state = Model.moveTaskDown(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function cycleProfile(dir) {
    root.state = Model.cycleKanbanProfile(root.state, dir)
    root.saveState()
    root.applyTickState()
  }

  function toggleTaskDone(id) {
    root.state = Model.toggleTaskDone(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function setActiveTask(id) {
    root.state = Model.setActiveTask(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function setActiveProfile(id) {
    root.state = Model.setActiveKanbanProfile(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function createProfile(name) {
    root.state = Model.createKanbanProfile(root.state, name)
    root.saveState()
    root.applyTickState()
  }

  function renameProfile(id, name) {
    root.state = Model.renameKanbanProfile(root.state, id, name)
    root.saveState()
    root.applyTickState()
  }

  function deleteProfile(id) {
    root.state = Model.deleteKanbanProfile(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function pushTaskToObsidian(id) {
    var task = null
    for (var i = 0; i < root.state.tasks.length; i++) if (root.state.tasks[i].id === id) { task = root.state.tasks[i]; break }
    if (!task) return false
    if (task.pushedToObsidian && task.pushedColumn === task.column) {
      Model.sendNotification(root.state, "Already pushed", task.text.slice(0,60) + " ✓ [" + task.column + "] — click ↩ to undo")
      return false
    }
    var prof = Model.getProfileById(root.state, task.profileId || "default")
    var profName = prof ? prof.name : (task.profileId || "Default")
    var ok = Model.appendTaskToVault(root.pluginDir, root.state.settings, task, undefined, profName)
    if (ok) {
      root.state = Model.markTaskPushed(root.state, id)
      root.saveState()
      root.applyTickState()
      Model.sendNotification(root.state, "Pushed to notes ✓", task.text.slice(0,60) + " [" + task.column + "] → " + profName)
    } else {
      Model.sendNotification(root.state, "Notes folder not configured", "Set notes path in Settings")
    }
    return ok
  }

  function undoPushToObsidian(id) {
    var task = null
    for (var i = 0; i < root.state.tasks.length; i++) if (root.state.tasks[i].id === id) { task = root.state.tasks[i]; break }
    if (!task || !task.pushedToObsidian) return false
    var prof = Model.getProfileById(root.state, task.profileId || "default")
    var profName = prof ? prof.name : (task.profileId || "Default")
    var ok = Model.removeTaskFromVault(root.pluginDir, root.state.settings, task, undefined, profName)
    if (ok) {
      root.state = Model.clearTaskPushed(root.state, id)
      root.saveState()
      root.applyTickState()
      Model.sendNotification(root.state, "Removed from notes ↩", task.text.slice(0,60))
    }
    return ok
  }

  function pushAllDoneToObsidian() {
    // pushes pending tasks for active profile, per-profile file
    var activeId = Model.getActiveProfileId(root.state)
    var activeProf = Model.getProfileById(root.state, activeId)
    var profName = activeProf ? activeProf.name : activeId
    var pending = Model.tasksForProfile(root.state, activeId).filter(function(t){ return !t.pushedToObsidian || t.pushedColumn !== t.column })
    if (pending.length === 0) {
      var all = Model.tasksForProfile(root.state, activeId)
      if (all.length > 0) Model.sendNotification(root.state, "All tasks already pushed ✓", "")
      else Model.sendNotification(root.state, "Nothing to push", "No tasks")
      return 0
    }
    var count = 0
    for (var i = 0; i < pending.length; i++) {
      if (Model.appendTaskToVault(root.pluginDir, root.state.settings, pending[i], undefined, profName)) {
        root.state = Model.markTaskPushed(root.state, pending[i].id)
        count++
      }
    }
    root.saveState()
    root.applyTickState()
    if (count > 0) {
      var dest = Model.obsidianFilePathForProfile(root.state.settings, root.state.settings.obsidianVaultPath, activeId, profName)
      if (root.home && dest.indexOf(root.home) === 0) dest = "~" + dest.slice(root.home.length)
      Model.sendNotification(root.state, "Pushed " + count + " tasks to notes ✓", dest)
    }
    return count
  }

  // ---- Popup panel ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("focusflow" in target) target.focusflow = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Connections {
    target: root
    function onBarChanged() { root.injectPanel() }
    function onSettingsChanged() { if (root.loaded) root.syncSettingsFromShellJson() }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "flowfocus"

    function start() { root.startTimer() }
    function pause() { root.pauseTimer() }
    function resume() { root.resumeTimer() }
    function toggle() { root.toggleTimer() }
    function reset() { root.resetTimer() }
    function skip() { root.skipPhase() }
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function togglePanel() { root.togglePanel() }

    // Generic mutation bridge for the fullscreen overlay (single writer stays
    // here; the overlay reads via file watch and sends ops as one JSON arg).
    // Returns true on success, false on unknown op / bad payload.
    function mutate(json: string) {
      var m = null
      try { m = JSON.parse(String(json || "")) } catch (e) { return false }
      if (!m || typeof m.op !== "string") return false
      var op = m.op
      if (op === "toggle") root.toggleTimer()
      else if (op === "reset") root.resetTimer()
      else if (op === "skip") root.skipPhase()
      else if (op === "mute") root.toggleMute()
      else if (op === "addTask") root.addTask(String(m.text || ""), String(m.column || "todo"))
      else if (op === "toggleDone") root.toggleTaskDone(String(m.id || ""))
      else if (op === "setActiveTask") root.setActiveTask(String(m.id || ""))
      else if (op === "deleteTask") root.deleteTask(String(m.id || ""))
      else if (op === "archiveTask") root.archiveDoneTask(String(m.id || ""))
      else if (op === "moveTask") root.moveTask(String(m.id || ""), String(m.column || "todo"))
      else if (op === "moveUp") root.moveTaskUp(String(m.id || ""))
      else if (op === "moveDown") root.moveTaskDown(String(m.id || ""))
      else if (op === "setProfile") root.setActiveProfile(String(m.id || ""))
      else if (op === "createProfile") root.createProfile(String(m.name || ""))
      else if (op === "renameProfile") root.renameProfile(String(m.id || ""), String(m.name || ""))
      else if (op === "deleteProfile") root.deleteProfile(String(m.id || ""))
      else if (op === "cycleProfile") root.cycleProfile(Number(m.dir) >= 0 ? 1 : -1)
      else if (op === "pushTask") root.pushTaskToObsidian(String(m.id || ""))
      else if (op === "undoPush") root.undoPushToObsidian(String(m.id || ""))
      else if (op === "pushAll") root.pushAllDoneToObsidian()
      else if (op === "set") { if (!root.applySetting(String(m.key || ""), m.value)) return false }
      else return false
      return true
    }
  }

  // Whitelisted absolute setting write with shell.json-style coercion.
  // Returns false for unknown keys so callers can report misuse.
  function applySetting(key, value) {
    if (!root.loaded) return false
    var s = root.state.settings
    var ints = ["workSec", "shortBreakSec", "longBreakSec", "longBreakInterval"]
    var reals = ["tickVolume", "alarmVolume"]
    var bools = ["tickEnabled", "alarmEnabled", "soundMuted", "kanbanMode", "todoEnabled", "kanbanEnabled", "showPomodoros",
                 "autoStartBreaks", "autoStartWork", "notificationsEnabled", "obsidianEnabled"]
    if (ints.indexOf(key) !== -1) {
      var n = Math.floor(Number(value))
      if (!isFinite(n)) return false
      s[key] = n
      if (root.isStopped) {
        if ((key === "workSec" && root.phase === Model.PHASE_WORK)
          || (key === "shortBreakSec" && root.phase === Model.PHASE_SHORT_BREAK)
          || (key === "longBreakSec" && root.phase === Model.PHASE_LONG_BREAK)) {
          root.state.timer.remainingSec = n
          root.state.timer.phaseDurationSec = n
        }
      }
    } else if (reals.indexOf(key) !== -1) {
      var r = Number(value)
      if (!isFinite(r)) return false
      s[key] = Math.max(0, Math.min(1, r))
    } else if (bools.indexOf(key) !== -1) {
      s[key] = (value === true || value === "true" || value === 1 || value === "1")
    } else if (key === "obsidianVaultPath") {
      s[key] = String(value || "").slice(0, 500)
    } else {
      return false
    }
    root.saveState()
    root.applyTickState()
    return true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: root.isStopped ? 8.75 : 4
    verticalPadding: 8.75
    fixedWidth: !root.vertical && !root.isStopped ? (runningContent.implicitWidth + 10) : -1
    tooltipText: root.isStopped
      ? "FocusFlow"
      : Model.phaseLabel(root.phase) + (root.activeTask ? " - " + root.activeTask.text : "")

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleTimer()
      else if (b === Qt.MiddleButton) root.resetTimer()
      else root.togglePanel()
    }

    // Icon + progress ring, centered in the button slot (enlarged)
    Item {
      id: iconSlot
      anchors.centerIn: parent
      width: Math.min(button.width, button.height) - 2
      height: width
      visible: root.vertical || root.isStopped

      Canvas {
        id: ring
        anchors.fill: parent
        property real progress: root.timerProgress
        property color ringColor: root.phaseColor
        property real ringWidth: Math.max(2, Style.space(2))
        property bool showRing: root.isRunning || root.isPaused
        onProgressChanged: requestPaint()
        onRingColorChanged: requestPaint()
        onRingWidthChanged: requestPaint()
        onShowRingChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var w = width, h = height
          if (w <= 0 || h <= 0 || !showRing) return
          var cx = w / 2, cy = h / 2
          var r = Math.max(1, Math.min(cx, cy) - ringWidth / 2)
          ctx.beginPath()
          ctx.arc(cx, cy, r, 0, Math.PI * 2)
          ctx.strokeStyle = Qt.rgba(ringColor.r, ringColor.g, ringColor.b, 0.15)
          ctx.lineWidth = ringWidth
          ctx.stroke()
          if (progress > 0) {
            var start = -Math.PI / 2
            var end = start + Math.PI * 2 * Math.max(0, Math.min(1, progress))
            ctx.beginPath()
            ctx.arc(cx, cy, r, start, end)
            ctx.strokeStyle = ringColor
            ctx.lineWidth = ringWidth
            ctx.lineCap = "round"
            ctx.stroke()
          }
        }
      }

      Text {
        id: icon
        anchors.centerIn: parent
        text: "\uf254"
        color: root.isRunning ? root.phaseColor : (root.bar ? root.bar.barForeground : Color.foreground)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.min(parent.width * 0.62, Style.font.iconLarge)
        font.bold: false
      }
    }

    // When running + horizontal bar: show ring + icon + countdown text
    Item {
      id: runningContent
      anchors.centerIn: parent
      visible: !root.vertical && !root.isStopped
      implicitWidth: ringH.width + countdownLabel.implicitWidth + Style.space(2)
      implicitHeight: Math.max(ringH.height, countdownLabel.implicitHeight)
      width: implicitWidth
      height: implicitHeight

      Canvas {
        id: ringH
        width: Style.bar.iconCanvas + Style.space(4)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        property real progress: root.timerProgress
        property color ringColor: root.phaseColor
        property real ringWidth: Math.max(2, Style.space(2))
        onProgressChanged: requestPaint()
        onRingColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var w = width, h = height
          if (w <= 0 || h <= 0) return
          var cx = w / 2, cy = h / 2
          var r = Math.max(1, Math.min(cx, cy) - ringWidth / 2)
          ctx.beginPath()
          ctx.arc(cx, cy, r, 0, Math.PI * 2)
          ctx.strokeStyle = Qt.rgba(ringColor.r, ringColor.g, ringColor.b, 0.15)
          ctx.lineWidth = ringWidth
          ctx.stroke()
          if (progress > 0) {
            var start = -Math.PI / 2
            var end = start + Math.PI * 2 * Math.max(0, Math.min(1, progress))
            ctx.beginPath()
            ctx.arc(cx, cy, r, start, end)
            ctx.strokeStyle = ringColor
            ctx.lineWidth = ringWidth
            ctx.lineCap = "round"
            ctx.stroke()
          }
        }

        Text {
          anchors.centerIn: parent
          text: "\uf254"
          color: root.phaseColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: parent.width * 0.6
        }
      }

      Text {
        id: countdownLabel
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: ringH.right
        anchors.leftMargin: Style.space(2)
        visible: !root.vertical
        text: root.displayText
        color: root.phaseColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }
  }
}
