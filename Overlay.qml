import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// FocusFlow workspace overlay — fullscreen 3-region layout (rail + main +
// side) for the same state the popup manages. READ-ONLY locally: all
// mutations go through the bar widget's `mutate` IPC (single writer), this
// side watches the state file for live updates (1s while the timer runs).
Item {
  id: root

  property bool opened: false
  property string view: "focus"
  property string searchText: ""
  property string newTaskText: ""

  // ---- Paths ----
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string statePath: stateHome + "/omarchy/focusflow.json"
  readonly property string shellPath: (Quickshell.env("OMARCHY_PATH") || "") + "/shell"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/+$/, "")

  // ---- State (watched, never written here) ----
  property var state: Model.defaultState()
  property bool loaded: false

  readonly property var timer: state.timer
  readonly property var ovSettings: state.settings
  readonly property bool isRunning: timer.status === Model.STATUS_RUNNING
  readonly property bool isPaused: timer.status === Model.STATUS_PAUSED
  readonly property string phase: timer.phase
  readonly property int remainingSec: timer.remainingSec
  readonly property real timerProgress: Model.progress(state)
  readonly property color phaseColor: Model.phaseColor(phase, Color.accent, Qt.darker(Color.foreground, 1.4), Color.urgent)
  readonly property string displayText: Model.formatTime(remainingSec)
  readonly property string activeProfileId: state.activeKanbanProfileId || "default"
  readonly property var profiles: state.kanbanProfiles || []
  readonly property var activeProfile: Model.getActiveProfile(state)
  readonly property var profileTasks: Model.tasksForProfile(root.state, root.activeProfileId)
  readonly property int profileDoneCount: profileTasks.filter(function(t){ return t.done }).length
  readonly property int profileFocusedCount: profileTasks.reduce(function(a, t){ return a + (t.pomodorosSpent || 0) }, 0)
  readonly property int profilePendingPush: profileTasks.filter(function(t){ return !t.pushedToObsidian || t.pushedColumn !== t.column }).length
  readonly property color dimText: Qt.darker(Color.foreground, 1.4)
  readonly property var activeTask: {
    var id = timer.activeTaskId
    if (!id) return null
    for (var i = 0; i < state.tasks.length; i++) {
      if (state.tasks[i].id === id) return state.tasks[i]
    }
    return null
  }
  readonly property var nextUp: Model.nextTask(state, state.activeKanbanProfileId)

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.state = Model.parse(text())
      root.loaded = true
    }
    onTextChanged: {
      if (root.loaded) root.state = Model.parse(text())
    }
  }

  // ---- IPC bridge: every mutation runs in the bar widget ----
  function call(op, args) {
    var payload = args || {}
    payload.op = op
    var json = ""
    try { json = JSON.stringify(payload) } catch (e) { return }
    if (root.shellPath === "/shell") return
    Quickshell.execDetached(["qs", "ipc", "-n", "-p", root.shellPath, "call", "flowfocus", "mutate", json])
  }

  // True while typing in any overlay input — letter shortcuts stay off
  readonly property bool typing: boardSearch.activeFocus || addBox.activeFocus || notesPath.activeFocus

  function taskMatches(task) {
    var q = root.searchText.trim().toLowerCase()
    if (!q || !task) return true
    return (task.text || "").toLowerCase().indexOf(q) !== -1
  }

  function cycleTaskColumn(task) {
    var cols = Model.COLUMNS
    var idx = cols.indexOf(task.column)
    root.call("moveTask", { id: task.id, column: cols[(idx + 1) % cols.length] })
  }

  function vaultDestForActive() {
    var name = root.activeProfile ? root.activeProfile.name : "Default"
    var p = Model.obsidianFilePathForProfile(root.ovSettings, root.ovSettings.obsidianVaultPath, root.activeProfileId, name) || ""
    if (!p) return ""
    if (root.home && p.indexOf(root.home) === 0) p = "~" + p.slice(root.home.length)
    return p
  }

  // ---- Lifecycle (called by omarchy-shell summon/hide) ----
  function open(payload) {
    try {
      if (payload) {
        var args = JSON.parse(payload) || {}
        if (typeof args.view === "string" && ["focus", "kanban", "todo", "settings"].indexOf(args.view) !== -1) root.view = args.view
      }
    } catch (e) {}
    try { root.state = Model.parse(stateFile.text()) } catch (e) {}
    root.loaded = true
    root.opened = true
    keyGrab.forceActiveFocus()
  }

  function close() {
    root.opened = false
  }

  // ---- Window ----
  PanelWindow {
    id: win
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "flowfocus-workspace"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Scrim — click closes
    Rectangle {
      anchors.fill: parent
      visible: root.opened
      color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.72)
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    // Keyboard — letter keys stay off while typing in search/add/path fields
    Item {
      id: keyGrab
      anchors.fill: parent
      focus: root.opened
      Keys.onEscapePressed: root.close()
      Keys.onSpacePressed: function(event) { if (root.typing) return; root.call("toggle"); event.accepted = true }
      Shortcut {
        sequence: "Tab"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.cycleView(1)
      }
      Shortcut {
        sequence: "M"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.call("mute")
      }
      Shortcut {
        sequence: "m"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.call("mute")
      }
      Shortcut {
        sequence: "f"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.view = "focus"
      }
      Shortcut {
        sequence: "k"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.view = "kanban"
      }
      Shortcut {
        sequence: "t"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.view = "todo"
      }
      Shortcut {
        sequence: "s"
        context: Qt.WindowShortcut
        enabled: root.opened && !root.typing
        onActivated: root.view = "settings"
      }
      Shortcut {
        sequence: "Alt+H"
        context: Qt.ApplicationShortcut
        enabled: root.opened && !root.typing
        onActivated: root.call("cycleProfile", { dir: -1 })
      }
      Shortcut {
        sequence: "Alt+L"
        context: Qt.ApplicationShortcut
        enabled: root.opened && !root.typing
        onActivated: root.call("cycleProfile", { dir: 1 })
      }
    }

    // Delete confirm (plain tasks)
    ConfirmDialog {
      id: confirmDeleteTask
      anchors.fill: parent
      z: 100
      message: "Delete task \"" + root.delTaskText + "\"? Also removes from notes if pushed. This cannot be undone."
      confirmText: "Delete"
      cancelText: "Cancel"
      onConfirmed: { if (root.delTaskId) root.call("deleteTask", { id: root.delTaskId }); opened = false; root.delTaskId = ""; root.delTaskText = "" }
      onCanceled: { opened = false; root.delTaskId = ""; root.delTaskText = "" }
    }

    // Done-task choice: Archive [x] in notes vs Delete everywhere
    Item {
      anchors.fill: parent
      z: 110
      visible: root.delDoneOpen
      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.7)
        MouseArea { anchors.fill: parent; onClicked: root.closeDeleteDone() }
        Rectangle {
          width: Math.min(parent.width - 64, 420)
          height: doneCol.implicitHeight + 36
          anchors.centerIn: parent
          radius: Style.cornerRadius
          color: Color.background
          border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.4)
          border.width: 1
          MouseArea { anchors.fill: parent; onClicked: {} }
          Column {
            id: doneCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Done — \"" + root.delTaskText + "\" is finished. Archive as - [x] in notes and remove from board, or delete everywhere?"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Row {
              anchors.right: parent.right
              spacing: Style.space(8)
              Button {
                text: "Cancel"
                foreground: root.dimText
                fontSize: Style.font.caption
                onClicked: root.closeDeleteDone()
              }
              Button {
                text: "Archive [x]"
                foreground: Color.accent
                selected: true
                fontSize: Style.font.caption
                onClicked: { if (root.delTaskId) root.call("archiveTask", { id: root.delTaskId }); root.closeDeleteDone() }
              }
              Button {
                text: "Delete all"
                foreground: Color.urgent
                fontSize: Style.font.caption
                onClicked: { if (root.delTaskId) root.call("deleteTask", { id: root.delTaskId }); root.closeDeleteDone() }
              }
            }
          }
        }
      }
    }

    // Compact workspace card — floats above the bar, not fullscreen-center
    Rectangle {
      id: card
      visible: root.opened
      width: Math.min(parent.width - 80, 980)
      height: Math.min(parent.height - 140, 620)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 56
      radius: Style.cornerRadius
      color: Color.background
      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.14)
      border.width: 1
      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: cardCol
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(8)

        // ---- TopBar ----
        Row {
          id: topBar
          width: parent.width
          spacing: Style.space(8)
          Text {
            id: tbMark
            text: "\uf254"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: tbName
            text: "FocusFlow"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: profileTag
            text: root.activeProfile ? root.activeProfile.name : "Default"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            id: topSpacer
            width: Math.max(0, parent.width - tbMark.width - tbName.width - syncBtn.width - bellBtn.width - closeBtn.width - profileTag.width - parent.spacing * 6)
            height: 1
          }
          Button {
            id: bellBtn
            text: root.ovSettings.soundMuted ? "\uf1f6" : "\uf0f3"
            foreground: root.ovSettings.soundMuted ? Color.urgent : root.dimText
            tooltipText: "Mute all sound (M)"
            onClicked: root.call("mute")
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            id: syncBtn
            text: "●"
            fontSize: Style.font.caption
            foreground: !root.ovSettings.obsidianEnabled ? root.dimText : (root.profilePendingPush > 0 ? Color.accent : root.dimText)
            tooltipText: !root.ovSettings.obsidianEnabled ? "Notes export off — open Setup" : (root.profilePendingPush > 0 ? (root.profilePendingPush + " pending — open Setup") : "Synced ✓ — open Setup")
            onClicked: root.view = "settings"
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            id: closeBtn
            text: "✕"
            foreground: root.dimText
            tooltipText: "Close (Esc)"
            onClicked: root.close()
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---- Body: rail + main ----
        Row {
          id: bodyRow
          width: parent.width
          height: parent.height - topBar.height - parent.spacing
          spacing: Style.space(8)

          // Icon rail — 64px, letters + tooltips (theme-font-safe)
          Column {
            id: rail
            width: 64
            height: parent.height
            spacing: Style.space(4)
            Repeater {
              model: [
                { id: "focus", key: "F", tip: "Focus timer" },
                { id: "kanban", key: "K", tip: "Kanban board" },
                { id: "todo", key: "T", tip: "To-Do list" },
                { id: "settings", key: "S", tip: "Settings" }
              ]
              delegate: Rectangle {
                required property var modelData
                width: 64
                height: 48
                radius: Style.cornerRadius
                color: root.view === modelData.id ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : "transparent"
                border.color: root.view === modelData.id ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35) : "transparent"
                border.width: 1
                Text {
                  anchors.centerIn: parent
                  text: modelData.key
                  color: root.view === modelData.id ? Color.accent : root.dimText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.view = modelData.id
                }
              }
            }
            Item { width: 64; height: Math.max(0, parent.height - 4 * 48 - parent.spacing * 4 - syncDot.height - parent.spacing) }
            Text {
              id: syncDot
              width: 64
              horizontalAlignment: Text.AlignHCenter
              text: "●"
              color: !root.ovSettings.obsidianEnabled ? root.dimText : (root.profilePendingPush > 0 ? Color.accent : Color.accent)
              font.pixelSize: Style.font.caption
              opacity: (!root.ovSettings.obsidianEnabled || root.profilePendingPush === 0) ? 0.45 : 1.0
            }
          }

          // Main region — views land here
          Item {
            id: mainRegion
            width: parent.width - rail.width - parent.spacing
            height: parent.height
            clip: true

            // ---- Focus view ----
            Row {
              visible: root.view === "focus"
              anchors.fill: parent
              spacing: Style.space(8)

              // Timer panel
              Rectangle {
                width: Math.round(parent.width * 0.58)
                height: parent.height
                radius: Style.cornerRadius
                color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
                border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                border.width: 1
                Column {
                  anchors.fill: parent
                  anchors.margins: Style.space(12)
                  spacing: Style.space(8)
                  Row {
                    spacing: Style.space(6)
                    Text { text: "●"; color: Color.accent; font.pixelSize: Style.font.caption }
                    Text {
                      text: "Focus Mode"
                      color: Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }
                  Item {
                    width: parent.width
                    height: 230
                    Canvas {
                      id: focusRing
                      width: 210
                      height: 210
                      anchors.centerIn: parent
                      property real progress: root.timerProgress
                      property color ringColor: root.phaseColor
                      onProgressChanged: requestPaint()
                      onRingColorChanged: requestPaint()
                      onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var cx = width / 2, cy = height / 2
                        var r = Math.min(cx, cy) - 6
                        ctx.beginPath()
                        ctx.arc(cx, cy, r, 0, Math.PI * 2)
                        ctx.strokeStyle = Qt.rgba(ringColor.r, ringColor.g, ringColor.b, 0.15)
                        ctx.lineWidth = 10
                        ctx.stroke()
                        if (progress > 0) {
                          ctx.beginPath()
                          ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0, Math.min(1, progress)))
                          ctx.strokeStyle = ringColor
                          ctx.lineWidth = 10
                          ctx.lineCap = "round"
                          ctx.stroke()
                        }
                      }
                    }
                    Column {
                      anchors.centerIn: parent
                      spacing: 0
                      Text {
                        text: root.displayText
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.displayLarge
                        font.bold: true
                        anchors.horizontalCenter: parent.horizontalCenter
                      }
                      Text {
                        text: Model.phaseLabel(root.phase)
                        color: Color.accent
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        anchors.horizontalCenter: parent.horizontalCenter
                      }
                    }
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.activeTask ? root.activeTask.text : (root.nextUp ? "Next: " + root.nextUp.text : "No tasks")
                    color: root.dimText
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Row {
                    spacing: Style.space(8)
                    anchors.horizontalCenter: parent.horizontalCenter
                    Button {
                      text: root.isRunning ? "Pause" : (root.isPaused ? "Resume" : "Start")
                      foreground: Color.accent
                      selected: true
                      fontSize: Style.font.body
                      horizontalPadding: Style.space(16)
                      verticalPadding: Style.space(6)
                      onClicked: root.call("toggle")
                    }
                    Button {
                      text: "Skip"
                      foreground: root.dimText
                      fontSize: Style.font.body
                      horizontalPadding: Style.space(16)
                      verticalPadding: Style.space(6)
                      onClicked: root.call("skip")
                    }
                  }
                  Row {
                    width: parent.width
                    spacing: Style.space(4)
                    Text { text: "●"; color: Color.accent; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                      text: "Work " + Math.round((root.ovSettings.workSec || 1500) / 60) + "m"
                      color: Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Item { width: Style.space(8); height: 1 }
                    Text { text: "●"; color: root.dimText; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                      text: "Break " + Math.round((root.ovSettings.shortBreakSec || 300) / 60) + "m"
                      color: root.dimText
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Item {
                      width: Math.max(0, parent.width - 200)
                      height: 1
                    }
                    Text {
                      text: "1/" + (root.ovSettings.longBreakInterval || 4)
                      color: root.dimText
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }

              // Side: progress + quick settings
              Column {
                width: parent.width - Math.round(parent.width * 0.58) - parent.spacing
                height: parent.height
                spacing: Style.space(8)
                Rectangle {
                  width: parent.width
                  height: progBoxCol.implicitHeight + Style.space(20)
                  radius: Style.cornerRadius
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
                  border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                  border.width: 1
                  Column {
                    id: progBoxCol
                    anchors.fill: parent
                    anchors.margins: Style.space(10)
                    spacing: Style.space(6)
                    Row {
                      width: parent.width
                      spacing: Style.space(6)
                      Text {
                        id: progTitle
                        text: "Today's Progress"
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Item { width: Math.max(0, parent.width - progTitle.width - progFrac.width - parent.spacing * 2); height: 1 }
                      Text {
                        id: progFrac
                        text: root.profileDoneCount + " / " + root.profileTasks.length
                        color: root.dimText
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                    Item {
                      id: progBarTrack
                      width: parent.width
                      height: 6
                      Rectangle {
                        anchors.fill: parent
                        radius: 3
                        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
                      }
                      Rectangle {
                        height: parent.height
                        width: parent.width * (root.profileTasks.length > 0 ? root.profileDoneCount / root.profileTasks.length : 0)
                        radius: 3
                        color: Color.accent
                      }
                    }
                    Row {
                      width: parent.width
                      spacing: Style.space(16)
                      Column { spacing: 0; Text { text: String(root.profileFocusedCount); color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter } Text { text: "Focused 🍅"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter } }
                      Column { spacing: 0; Text { text: String(root.profilePendingPush); color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter } Text { text: "To sync"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter } }
                      Column { spacing: 0; Text { text: String(root.profiles.length); color: Color.popups.text; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter } Text { text: "Spaces"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter } }
                    }
                  }
                }
                Rectangle {
                  width: parent.width
                  height: parent.height - progBoxCol.parent.height - parent.spacing
                  radius: Style.cornerRadius
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
                  border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                  border.width: 1
                  Column {
                    anchors.fill: parent
                    anchors.margins: Style.space(10)
                    spacing: Style.space(6)
                    Text {
                      text: "Quick Settings"
                      color: Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Repeater {
                      model: [
                        { key: "workSec", label: "Work Duration", suffix: "m", min: 1, max: 60, interval: false },
                        { key: "shortBreakSec", label: "Short Break", suffix: "m", min: 1, max: 25, interval: false },
                        { key: "longBreakSec", label: "Long Break", suffix: "m", min: 1, max: 60, interval: false },
                        { key: "longBreakInterval", label: "Cycles Until Long Break", suffix: "", min: 1, max: 12, interval: true }
                      ]
                      delegate: Row {
                        required property var modelData
                        width: parent.width
                        spacing: Style.space(6)
                        Text {
                          text: modelData.label
                          color: Color.popups.text
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                          width: parent.width - decB.width - valT.width - incB.width - parent.spacing * 3
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Button {
                          id: decB
                          text: "−"
                          foreground: root.dimText
                          fontSize: Style.font.caption
                          horizontalPadding: Style.space(4)
                          verticalPadding: Style.space(2)
                          onClicked: root.stepDuration(modelData.key, -1, modelData.min, modelData.max)
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                          id: valT
                          width: 44
                          horizontalAlignment: Text.AlignHCenter
                          text: modelData.interval ? String(root.ovSettings[modelData.key] || 4) : (Math.round((root.ovSettings[modelData.key] || 1500) / 60) + modelData.suffix)
                          color: Color.popups.text
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Button {
                          id: incB
                          text: "+"
                          foreground: root.dimText
                          fontSize: Style.font.caption
                          horizontalPadding: Style.space(4)
                          verticalPadding: Style.space(2)
                          onClicked: root.stepDuration(modelData.key, 1, modelData.min, modelData.max)
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }
                  }
                }
              }
            }

            // __VIEWS2__

            // ---- Board view ----
            Column {
              visible: root.view === "kanban" || root.view === "todo"
              anchors.fill: parent
              spacing: Style.space(8)

              // Tabs + search + add
              Row {
                id: boardTabs
                width: parent.width
                spacing: Style.space(8)
                Button {
                  text: "Kanban"
                  foreground: root.view === "kanban" ? Color.accent : root.dimText
                  selected: root.view === "kanban"
                  fontSize: Style.font.bodySmall
                  onClicked: root.view = "kanban"
                  anchors.verticalCenter: parent.verticalCenter
                }
                Button {
                  text: "To-Do"
                  foreground: root.view === "todo" ? Color.accent : root.dimText
                  selected: root.view === "todo"
                  fontSize: Style.font.bodySmall
                  onClicked: root.view = "todo"
                  anchors.verticalCenter: parent.verticalCenter
                }
                TextField {
                  id: boardSearch
                  width: Math.max(140, parent.width - 400)
                  placeholderText: "Search tasks…"
                  text: root.searchText
                  maximumLength: 100
                  onTextChanged: root.searchText = text.slice(0, 100)
                }
                Item { width: Math.max(0, parent.width - 400 - boardSearch.width - addBox.width - parent.spacing * 3); height: 1 }
                TextField {
                  id: addBox
                  width: 220
                  placeholderText: "Add a task…"
                  text: root.newTaskText
                  maximumLength: 200
                  onTextChanged: root.newTaskText = text.slice(0, 200)
                  onAccepted: { root.call("addTask", { text: root.newTaskText, column: "todo" }); root.newTaskText = "" }
                }
                Button {
                  text: "+ Add Task"
                  foreground: Color.accent
                  selected: true
                  fontSize: Style.font.bodySmall
                  onClicked: { root.call("addTask", { text: root.newTaskText, column: "todo" }); root.newTaskText = "" }
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Spaces row (Board view)
              Row {
                visible: root.view === "kanban"
                width: parent.width
                spacing: Style.space(6)
                Text {
                  text: "Spaces:"
                  color: root.dimText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
                Repeater {
                  model: root.profiles
                  delegate: Button {
                    required property var modelData
                    text: modelData.name
                    foreground: modelData.id === root.activeProfileId ? Color.accent : root.dimText
                    selected: modelData.id === root.activeProfileId
                    fontSize: Style.font.caption
                    onClicked: root.call("setProfile", { id: modelData.id })
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                Button {
                  text: "+"
                  foreground: Color.accent
                  fontSize: Style.font.caption
                  tooltipText: "New space (creates with input text)"
                  onClicked: { if (root.newTaskText.trim() !== "") { root.call("createProfile", { name: root.newTaskText.trim().slice(0, 30) }); root.newTaskText = "" } }
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Columns
              Row {
                visible: root.view === "kanban"
                width: parent.width
                height: parent.height - 36 - 30 - parent.spacing * 2
                spacing: Style.space(8)
                Repeater {
                  model: Model.COLUMNS
                  delegate: Item {
                    required property string modelData
                    property string colId: modelData
                    property var colTasks: Model.tasksByColumn(root.state, colId, root.activeProfileId).filter(root.taskMatches)
                    width: (parent.width - Style.space(8) * 3) / 4
                    height: parent.height
                    Rectangle {
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.045)
                      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                      border.width: 1
                    }
                    Column {
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      spacing: Style.space(6)
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        Text { id: dotW; text: "●"; color: colTasks.length > 0 ? Color.accent : root.dimText; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                        Text {
                          id: labW
                          text: String(Model.COLUMN_LABELS[colId]).toUpperCase()
                          color: root.dimText
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          font.letterSpacing: 1
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Item { width: Math.max(0, parent.width - dotW.width - labW.width - badgeW.width - parent.spacing * 3); height: 1 }
                        Rectangle {
                          id: badgeW
                          width: badgeT.implicitWidth + Style.space(10)
                          height: Style.space(16)
                          radius: height / 2
                          color: colTasks.length > 0 ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                          Text {
                            id: badgeT
                            anchors.centerIn: parent
                            text: String(colTasks.length)
                            color: colTasks.length > 0 ? Color.accent : root.dimText
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                          }
                        }
                      }
                      Flickable {
                        width: parent.width
                        height: parent.height - 24 - addFooter.height - parent.spacing * 2
                        contentHeight: cardsCol.implicitHeight
                        clip: true
                        flickableDirection: Flickable.VerticalFlick
                        boundsBehavior: Flickable.StopAtBounds
                        Column {
                          id: cardsCol
                          width: parent.width
                          spacing: Style.space(6)
                          Repeater {
                            model: colTasks
                            delegate: Rectangle {
                              required property var modelData
                              property var task: modelData
                              width: cardsCol.width
                              height: cardInner.implicitHeight + Style.space(10)
                              radius: Style.cornerRadius
                              color: task.id === root.timer.activeTaskId ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
                              border.color: task.id === root.timer.activeTaskId ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.16)
                              border.width: 1
                              Column {
                                id: cardInner
                                anchors.fill: parent
                                anchors.margins: Style.space(6)
                                spacing: 4
                                Row {
                                  width: parent.width
                                  spacing: Style.space(6)
                                  Text {
                                    text: task.done ? "●" : "○"
                                    color: task.done ? Color.accent : root.dimText
                                    font.pixelSize: Style.font.body
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.call("toggleDone", { id: task.id }) }
                                  }
                                  Text {
                                    text: task.text
                                    color: task.done ? root.dimText : Color.popups.text
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.bodySmall
                                    font.strikeout: task.done
                                    wrapMode: Text.Wrap
                                    width: parent.width - 22 - delBtn.width - parent.spacing * 2
                                    anchors.verticalCenter: parent.verticalCenter
                                  }
                                  Text {
                                    id: delBtn
                                    text: "−"
                                    color: Color.urgent
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea {
                                      anchors.fill: parent
                                      anchors.margins: -6
                                      cursorShape: Qt.PointingHandCursor
                                      onClicked: {
                                        if (task.done || task.column === "done") root.askDeleteDone(task)
                                        else root.askDeleteTask(task)
                                      }
                                    }
                                  }
                                }
                                Row {
                                  spacing: Style.space(8)
                                  Text {
                                    visible: root.ovSettings.showPomodoros !== false
                                    text: "🍅 " + (task.pomodorosSpent || 0) + "/" + (task.pomodorosEstimated || 0)
                                    color: root.dimText
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                  }
                                  Text {
                                    text: "←"
                                    color: colId === "backlog" ? root.dimText : Color.accent
                                    opacity: colId === "backlog" ? 0.35 : 1
                                    font.pixelSize: Style.font.bodySmall
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea {
                                      anchors.fill: parent
                                      anchors.margins: -4
                                      enabled: colId !== "backlog"
                                      cursorShape: Qt.PointingHandCursor
                                      onClicked: {
                                        var idx = Model.COLUMNS.indexOf(colId)
                                        if (idx > 0) root.call("moveTask", { id: task.id, column: Model.COLUMNS[idx - 1] })
                                      }
                                    }
                                  }
                                  Text {
                                    text: "→"
                                    color: colId === "done" ? root.dimText : Color.accent
                                    opacity: colId === "done" ? 0.35 : 1
                                    font.pixelSize: Style.font.bodySmall
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea {
                                      anchors.fill: parent
                                      anchors.margins: -4
                                      enabled: colId !== "done"
                                      cursorShape: Qt.PointingHandCursor
                                      onClicked: {
                                        var j = Model.COLUMNS.indexOf(colId)
                                        if (j < Model.COLUMNS.length - 1) root.call("moveTask", { id: task.id, column: Model.COLUMNS[j + 1] })
                                      }
                                    }
                                  }
                                  Text {
                                    visible: root.ovSettings.obsidianEnabled === true
                                    text: (task.pushedToObsidian && task.pushedColumn === task.column) ? "↩" : "⬆"
                                    color: (task.pushedToObsidian && task.pushedColumn === task.column) ? Color.urgent : Color.accent
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea {
                                      anchors.fill: parent
                                      anchors.margins: -4
                                      cursorShape: Qt.PointingHandCursor
                                      enabled: parent.visible
                                      onClicked: {
                                        if (task.pushedToObsidian && task.pushedColumn === task.column) root.call("undoPush", { id: task.id })
                                        else root.call("pushTask", { id: task.id })
                                      }
                                    }
                                  }
                                  Text {
                                    text: task.id === root.timer.activeTaskId ? "● focused" : "○ focus"
                                    color: task.id === root.timer.activeTaskId ? Color.accent : root.dimText
                                    font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.call("setActiveTask", { id: task.id }) }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                      Button {
                        id: addFooter
                        width: parent.width
                        text: "+ Add task"
                        foreground: root.dimText
                        fontSize: Style.font.caption
                        enabled: root.newTaskText.trim() !== ""
                        tooltipText: "Add the top input text to this column"
                        onClicked: { root.call("addTask", { text: root.newTaskText, column: colId }); root.newTaskText = "" }
                      }
                    }
                  }
                }
              }

              // Todo list (grouped Open / Completed)
              ListView {
                id: todoList
                visible: root.view === "todo"
                width: parent.width
                height: parent.height - boardTabs.height - parent.spacing
                clip: true
                spacing: Style.space(6)
                boundsBehavior: Flickable.StopAtBounds
                model: root.profileTasks.filter(root.taskMatches).slice().sort(function(a, b){ return ((a.done ? 1 : 0) - (b.done ? 1 : 0)) || ((a.createdAt || 0) - (b.createdAt || 0)) })
                section.property: "done"
                section.criteria: ViewSection.FullString
                section.delegate: Text {
                  width: todoList.width
                  text: section === "true" ? ("Completed · " + root.profileDoneCount) : ("Open · " + (root.profileTasks.length - root.profileDoneCount))
                  color: root.dimText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }
                delegate: Rectangle {
                  id: todoDelegate
                  required property var modelData
                  property var task: modelData
                  width: todoList.width
                  height: Math.max(34, todoInner.implicitHeight + Style.space(8))
                  radius: Style.cornerRadius / 2
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.03)
                  border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
                  border.width: 1
                  Row {
                    id: todoInner
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(8)
                    Text {
                      text: task.done ? "●" : "○"
                      color: task.done ? Color.accent : root.dimText
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.call("toggleDone", { id: task.id }) }
                    }
                    Text {
                      text: task.text
                      color: task.done ? root.dimText : Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.strikeout: task.done
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      width: parent.width - 24 - focusT.width - cycT.width - delT.width - parent.spacing * 4
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      id: focusT
                      text: task.id === root.timer.activeTaskId ? "●" : "○"
                      color: task.id === root.timer.activeTaskId ? Color.accent : root.dimText
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.call("setActiveTask", { id: task.id }) }
                    }
                    Text {
                      id: cycT
                      text: "→"
                      color: root.dimText
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                      MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.cycleTaskColumn(task) }
                    }
                    Text {
                      id: delT
                      text: "−"
                      color: Color.urgent
                      font.pixelSize: Style.font.body
                      font.bold: true
                      anchors.verticalCenter: parent.verticalCenter
                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          if (task.done || task.column === "done") root.askDeleteDone(task)
                          else root.askDeleteTask(task)
                        }
                      }
                    }
                  }
                }
              }
            }

            // ---- Setup view ----
            Flickable {
              visible: root.view === "settings"
              anchors.fill: parent
              contentHeight: setupCol.implicitHeight
              contentWidth: width
              clip: true
              flickableDirection: Flickable.VerticalFlick
              boundsBehavior: Flickable.StopAtBounds
              Column {
                id: setupCol
                width: parent.width
                spacing: Style.space(8)
                Text { text: "Pomodoro"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(12)
                  rowSpacing: Style.space(4)
                  OvStepper { width: (parent.width - parent.columnSpacing) / 2; label: "Work duration"; value: Math.round((root.ovSettings.workSec || 1500) / 60) + "m"; onDecrease: root.stepDuration("workSec", -1, 1, 60); onIncrease: root.stepDuration("workSec", 1, 1, 60) }
                  OvStepper { width: (parent.width - parent.columnSpacing) / 2; label: "Short break"; value: Math.round((root.ovSettings.shortBreakSec || 300) / 60) + "m"; onDecrease: root.stepDuration("shortBreakSec", -1, 1, 25); onIncrease: root.stepDuration("shortBreakSec", 1, 1, 25) }
                  OvStepper { width: (parent.width - parent.columnSpacing) / 2; label: "Long break"; value: Math.round((root.ovSettings.longBreakSec || 900) / 60) + "m"; onDecrease: root.stepDuration("longBreakSec", -1, 1, 60); onIncrease: root.stepDuration("longBreakSec", 1, 1, 60) }
                  OvStepper { width: (parent.width - parent.columnSpacing) / 2; label: "Long break every"; value: String(root.ovSettings.longBreakInterval || 4); onDecrease: root.stepDuration("longBreakInterval", -1, 1, 12); onIncrease: root.stepDuration("longBreakInterval", 1, 1, 12) }
                  OvToggle { width: (parent.width - parent.columnSpacing) / 2; label: "Auto-start"; description: "Breaks + work chained"; checked: root.ovSettings.autoStartBreaks && root.ovSettings.autoStartWork; onClicked: { var v = !(root.ovSettings.autoStartBreaks && root.ovSettings.autoStartWork); root.call("set", { key: "autoStartBreaks", value: v }); root.call("set", { key: "autoStartWork", value: v }) } }
                }
                Text { text: "Audio"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(12)
                  rowSpacing: Style.space(4)
                  OvToggle { width: (parent.width - parent.columnSpacing) / 2; label: "Tick sound"; description: "Tick every second"; checked: root.ovSettings.tickEnabled === true; onClicked: root.call("set", { key: "tickEnabled", value: !(root.ovSettings.tickEnabled === true) }) }
                  OvToggle { width: (parent.width - parent.columnSpacing) / 2; label: "Alarm sound"; description: "Chime on phase end"; checked: root.ovSettings.alarmEnabled !== false; onClicked: root.call("set", { key: "alarmEnabled", value: !(root.ovSettings.alarmEnabled !== false) }) }
                  OvToggle { width: (parent.width - parent.columnSpacing) / 2; label: "Mute all"; description: "Bell / M key"; checked: root.ovSettings.soundMuted === true; onClicked: root.call("mute") }
                  OvStepper { width: (parent.width - parent.columnSpacing) / 2; label: "Tick volume"; value: Math.round((root.ovSettings.tickVolume ?? 0.3) * 100) + "%"; onDecrease: root.stepVolume("tickVolume", -0.05); onIncrease: root.stepVolume("tickVolume", 0.05) }
                  OvStepper { width: (parent.width - parent.columnSpacing) / 2; label: "Alarm volume"; value: Math.round((root.ovSettings.alarmVolume ?? 0.5) * 100) + "%"; onDecrease: root.stepVolume("alarmVolume", -0.05); onIncrease: root.stepVolume("alarmVolume", 0.05) }
                }
                Text { text: "Board"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                Grid {
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(12)
                  rowSpacing: Style.space(4)
                  OvToggle { width: (parent.width - parent.columnSpacing) / 2; label: "Show pomodoros"; description: "🍅 on cards"; checked: root.ovSettings.showPomodoros !== false; onClicked: root.call("set", { key: "showPomodoros", value: !(root.ovSettings.showPomodoros !== false) }) }
                  OvToggle { width: (parent.width - parent.columnSpacing) / 2; label: "Notifications"; description: "Desktop on phase end"; checked: root.ovSettings.notificationsEnabled !== false; onClicked: root.call("set", { key: "notificationsEnabled", value: !(root.ovSettings.notificationsEnabled !== false) }) }
                }
                Text { text: "Vault sync"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                OvToggle { width: parent.width; label: "Notes export"; description: root.ovSettings.obsidianEnabled ? (root.ovSettings.obsidianVaultPath || "no path set") : "Obsidian / any notes app, on approve"; checked: root.ovSettings.obsidianEnabled === true; onClicked: root.call("set", { key: "obsidianEnabled", value: !(root.ovSettings.obsidianEnabled === true) }) }
                TextField {
                  id: notesPath
                  width: parent.width
                  visible: root.ovSettings.obsidianEnabled === true
                  placeholderText: "Notes folder e.g. ~/Documents/notes"
                  text: root.ovSettings.obsidianVaultPath || ""
                  onAccepted: root.call("set", { key: "obsidianVaultPath", value: text.trim().slice(0, 500) })
                  onEditingFinished: root.call("set", { key: "obsidianVaultPath", value: text.trim().slice(0, 500) })
                }
                Text {
                  visible: root.ovSettings.obsidianEnabled === true
                  width: parent.width
                  elide: Text.ElideMiddle
                  text: "→ " + root.vaultDestForActive()
                  color: root.dimText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Button {
                  visible: root.ovSettings.obsidianEnabled === true
                  width: parent.width
                  text: "Sync now (" + root.profilePendingPush + " pending)"
                  foreground: Color.accent
                  selected: true
                  enabled: root.profilePendingPush > 0 && !!root.ovSettings.obsidianVaultPath
                  onClicked: root.call("pushAll")
                }
              }
            }
          }
        }
      }
    }
  }

  function stepVolume(key, delta) {
    var cur = root.ovSettings[key]
    if (cur === undefined || cur === null) cur = 0.3
    var next = Math.round((cur + delta) * 20) / 20
    root.call("set", { key: key, value: Math.max(0, Math.min(1, next)) })
  }

  // Delete flows — same contract as the popup (plain confirm vs Done choice)
  property string delTaskId: ""
  property string delTaskText: ""
  property bool delDoneOpen: false

  function askDeleteTask(task) {
    if (!task) return
    root.delTaskId = task.id
    root.delTaskText = task.text
    confirmDeleteTask.opened = true
  }

  function askDeleteDone(task) {
    if (!task) return
    root.delTaskId = task.id
    root.delTaskText = task.text
    root.delDoneOpen = true
  }

  function closeDeleteDone() {
    root.delDoneOpen = false
    root.delTaskId = ""
    root.delTaskText = ""
  }

  // Compact toggle row (Setup view) — kit ToggleSwitch, theme tokens
  component OvToggle: Item {
    id: tog
    property string label: ""
    property string description: ""
    property bool checked: false
    signal clicked()
    implicitHeight: 36
    Row {
      anchors.fill: parent
      spacing: Style.space(8)
      Column {
        width: parent.width - tsw.width - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Text {
          text: label
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          visible: description !== ""
          text: description
          color: root.dimText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
      ToggleSwitch {
        id: tsw
        checked: tog.checked
        interactive: false
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tog.clicked() }
  }

  // Compact stepper row (Setup view)
  component OvStepper: Row {
    property string label: ""
    property string value: ""
    signal decrease()
    signal increase()
    spacing: Style.space(6)
    Text {
      text: label
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: parent.width - dec.width - val.width - inc.width - parent.spacing * 3
      anchors.verticalCenter: parent.verticalCenter
    }
    Button {
      id: dec
      text: "−"
      foreground: root.dimText
      fontSize: Style.font.caption
      horizontalPadding: Style.space(4)
      verticalPadding: Style.space(2)
      onClicked: decrease()
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: val
      text: value
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      width: 48
      horizontalAlignment: Text.AlignHCenter
      anchors.verticalCenter: parent.verticalCenter
    }
    Button {
      id: inc
      text: "+"
      foreground: root.dimText
      fontSize: Style.font.caption
      horizontalPadding: Style.space(4)
      verticalPadding: Style.space(2)
      onClicked: increase()
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Duration stepper — computes the absolute value, bar applies it.
  function stepDuration(key, delta, min, max) {
    var cur = key === "longBreakInterval"
      ? (root.ovSettings.longBreakInterval || 4)
      : Math.round((root.ovSettings[key] || 1500) / 60)
    var next = Math.max(min, Math.min(max, cur + delta))
    root.call("set", { key: key, value: key === "longBreakInterval" ? next : next * 60 })
  }

  function cycleView(dir) {
    var order = ["focus", "kanban", "todo"]
    var i = order.indexOf(root.view)
    if (i < 0) i = 0
    var d = (dir === undefined || dir >= 0) ? 1 : -1
    root.view = order[(i + d + order.length) % order.length]
  }
}
