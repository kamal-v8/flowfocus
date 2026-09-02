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
  readonly property color phaseColor: Model.phaseColor(phase, Color.accent, Color.muted, Color.urgent)
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
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.state = Model.parse(text())
      root.loaded = true
      root.syncSettingsFromShellJson()
      root.applyTickState()
    }
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
                "tickEnabled", "tickVolume", "kanbanMode", "autoStartBreaks",
                "autoStartWork", "notificationsEnabled"]
    var changed = false
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      var val = root.setting(key, undefined)
      if (val === undefined || val === null) continue
      // coerce numeric types from shell.json schema (int/real may come as number or string)
      if (["workSec","shortBreakSec","longBreakSec","longBreakInterval"].indexOf(key) !== -1) val = Math.floor(Number(val))
      if (key === "tickVolume") val = Number(val)
      if (["tickEnabled","kanbanMode","autoStartBreaks","autoStartWork","notificationsEnabled"].indexOf(key) !== -1) val = !!val
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
  Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: root.isRunning
    onTriggered: root.onTick()
  }

  // Tick sound timer — fires once per second while running + tickEnabled
  Timer {
    id: soundTimer
    interval: 1000
    repeat: true
    running: root.isRunning && root.ffSettings.tickEnabled
    onTriggered: Model.playTick(root.pluginDir, root.ffSettings.tickVolume)
  }

  function onTick() {
    var result = Model.tick(root.state)
    root.state = result.state

    if (result.phaseEnded) {
      var finished = result.finishedPhase
      var label = Model.phaseLabel(finished)
      var next = Model.phaseLabel(root.state.timer.phase)
      Model.sendNotification(root.state, label + " complete", "Time for " + next.toLowerCase())
      Model.playCompleteSound(root.pluginDir, 0.5)

      if (Model.shouldAutoStart(root.state)) {
        root.state = Model.startTimer(root.state)
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

  function deleteTask(id) {
    root.state = Model.deleteTask(root.state, id)
    root.saveState()
    root.applyTickState()
  }

  function moveTask(id, column) {
    root.state = Model.moveTask(root.state, id, column)
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

    function start(): void { root.startTimer() }
    function pause(): void { root.pauseTimer() }
    function resume(): void { root.resumeTimer() }
    function toggle(): void { root.toggleTimer() }
    function reset(): void { root.resetTimer() }
    function skip(): void { root.skipPhase() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function togglePanel(): void { root.togglePanel() }
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
      ? "FocusFlow — click to open"
      : Model.phaseLabel(root.phase) + (root.activeTask ? " — " + root.activeTask.text : "")

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
