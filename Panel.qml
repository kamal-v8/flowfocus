import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// FocusFlow popup panel — timer controls + task list (plain or kanban).
//
// Content goes directly into KeyboardPanel's contentHolder (its default
// property) — KeyboardPanel already draws the card BorderSurface, so we
// must NOT add another one here (that was causing the double border).
Panel {
  id: root
  moduleName: "flowfocus"
  ipcTarget: "flowfocus"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var focusflow: null

  // ---- Convenience accessors ----
  readonly property var ff: focusflow
  readonly property var state: ff ? ff.state : Model.defaultState()
  readonly property var timer: state.timer
  readonly property var ffSettings: state.settings
  readonly property bool isRunning: timer.status === Model.STATUS_RUNNING
  readonly property bool isPaused: timer.status === Model.STATUS_PAUSED
  readonly property bool isStopped: timer.status === Model.STATUS_STOPPED
  readonly property string phase: timer.phase
  readonly property int remainingSec: timer.remainingSec
  readonly property real timerProgress: Model.progress(state)
  // Theme-safe secondary tone. Color.muted is a raw theme value that can be
  // near-invisible (e.g. rose-pine light sets muted near-white on a
  // near-white background); first-party shell code never uses it for text.
  // Deriving from foreground keeps contrast in dark AND light modes.
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
  readonly property var nextUp: Model.nextTask(state, state.activeKanbanProfileId)
  readonly property bool kanbanMode: ffSettings.kanbanMode === true
  readonly property string activeProfileId: state.activeKanbanProfileId || "default"
  readonly property var profiles: state.kanbanProfiles || []
  readonly property var activeProfile: Model.getActiveProfile(state)
  // Live per-space aggregates for the focus strip + sync dot
  readonly property var profileTasks: Model.tasksForProfile(root.state, root.activeProfileId)
  readonly property int profileDoneCount: profileTasks.filter(function(t){ return t.done }).length
  readonly property int profileFocusedCount: profileTasks.reduce(function(a, t){ return a + (t.pomodorosSpent || 0) }, 0)
  readonly property int profilePendingPush: profileTasks.filter(function(t){ return !t.pushedToObsidian || t.pushedColumn !== t.column }).length

  // ---- UI state ----
  // Active view: focus | kanban | todo | settings. Ephemeral (resets to
  // focus per shell session); kanbanMode persists the kanban/todo choice.
  property string view: "focus"
  property string viewBeforeSettings: "focus"
  property string searchText: ""
  property string newTaskText: ""
  property string newProfileName: ""
  property bool showProfileCreator: false
  property bool isRenaming: false
  property bool showHelp: false

  // Board users land on Board once state arrives after a fresh shell
  // start; everyone else lands on Focus. Fires once (ff is injected once).
  onFfChanged: {
    if (root.ff && root.kanbanMode && root.view === "focus") root.view = "kanban"
  }

  // ---- Layout ----
  readonly property int basePanelWidth: Style.space(340)
  readonly property int kanbanPanelWidth: Style.space(520)
  readonly property int panelWidth: root.view === "kanban" ? kanbanPanelWidth : basePanelWidth

  // Ultra-compact toggle — dense row (32px) without BorderSurface card chrome
  // so Settings doesn't eat 4×54px cards. Uses same ToggleSwitch but inline.
  component SmallToggle: Item {
    property string label: ""
    property string description: ""
    property bool checked: false
    signal clicked()
    implicitHeight: 32
    implicitWidth: Style.space(240)
    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      spacing: Style.spacing.rowPaddingX
      Column {
        width: parent.width - _switch.width - parent.spacing
        spacing: 0
        anchors.verticalCenter: parent.verticalCenter
        Text {
          text: parent.parent.parent.label
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          visible: parent.parent.parent.description !== ""
          text: parent.parent.parent.description
          color: root.dimText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
      ToggleSwitch {
        id: _switch
        checked: parent.parent.checked
        interactive: false
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
  }

  // Compact − value + stepper row for durations/counts (focus view).
  component Stepper: Row {
    property string label: ""
    property string value: ""
    signal decrease()
    signal increase()
    spacing: Style.space(6)
    Text {
      text: parent?.label ?? ""
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      width: parent.width - decBtn.width - valText.width - incBtn.width - parent.spacing * 3
      anchors.verticalCenter: parent.verticalCenter
    }
    Button {
      id: decBtn
      text: "−"
      foreground: root.dimText
      fontSize: Style.font.caption
      horizontalPadding: Style.space(3)
      verticalPadding: Style.space(1)
      onClicked: parent.decrease()
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      id: valText
      text: parent?.value ?? ""
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      width: 44
      horizontalAlignment: Text.AlignHCenter
      anchors.verticalCenter: parent.verticalCenter
    }
    Button {
      id: incBtn
      text: "+"
      foreground: root.dimText
      fontSize: Style.font.caption
      horizontalPadding: Style.space(3)
      verticalPadding: Style.space(1)
      onClicked: parent.increase()
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Block shell key handling while typing so Space/h/l don't trigger timer/nav.
      // Dialogs are handled via signals below (not blocked) so Esc/Enter/Tab route to them.
      blocked: taskInput.activeFocus || profileInput.activeFocus
      onCloseRequested: {
        if (confirmDeleteDone.opened) confirmDeleteDone.closeDialog()
        else if (confirmDeleteTask.opened) confirmDeleteTask.canceled()
        else if (confirmDeleteProfile.opened) confirmDeleteProfile.canceled()
        else if (root.showHelp) root.showHelp = false
        else root.close()
      }
      onTabRequested: function(direction) {
        if (confirmDeleteDone.opened) confirmDeleteDone.cycleSelection(direction)
        else if (confirmDeleteTask.opened) confirmDeleteTask.selectedIndex = confirmDeleteTask.selectedIndex === 0 ? 1 : 0
        else if (confirmDeleteProfile.opened) confirmDeleteProfile.selectedIndex = confirmDeleteProfile.selectedIndex === 0 ? 1 : 0
        else if (root.showHelp) return
        else root.cycleView(direction)
      }
      onMoveRequested: function(dx, dy) {
        // Arrow/h/l navigation doubles as dialog Left/Right toggle when a confirm is open.
        if (dx !== 0 && confirmDeleteDone.opened) { confirmDeleteDone.cycleSelection(dx); return }
        if (dx !== 0 && confirmDeleteTask.opened) { confirmDeleteTask.selectedIndex = confirmDeleteTask.selectedIndex === 0 ? 1 : 0; return }
        if (dx !== 0 && confirmDeleteProfile.opened) { confirmDeleteProfile.selectedIndex = confirmDeleteProfile.selectedIndex === 0 ? 1 : 0; return }
      }
      onReturnRequested: {
        if (confirmDeleteDone.opened) confirmDeleteDone.activateSelected()
        else if (confirmDeleteTask.opened) { if (confirmDeleteTask.selectedIndex === 0) confirmDeleteTask.canceled(); else confirmDeleteTask.confirmed() }
        else if (confirmDeleteProfile.opened) { if (confirmDeleteProfile.selectedIndex === 0) confirmDeleteProfile.canceled(); else confirmDeleteProfile.confirmed() }
        else if (root.showHelp) root.showHelp = false
      }
      onActivateRequested: {
        if (confirmDeleteDone.opened) confirmDeleteDone.activateSelected()
        else if (confirmDeleteTask.opened) { if (confirmDeleteTask.selectedIndex === 0) confirmDeleteTask.canceled(); else confirmDeleteTask.confirmed() }
        else if (confirmDeleteProfile.opened) { if (confirmDeleteProfile.selectedIndex === 0) confirmDeleteProfile.canceled(); else confirmDeleteProfile.confirmed() }
        else if (root.showHelp) root.showHelp = false
        else if (root.ff) root.ff.toggleTimer()
      }
      onDeleteRequested: {
        // 'x' key — ignore while a confirm dialog is open (user must click).
      }
      onTextKey: function(t) {
        if (confirmDeleteDone.opened || confirmDeleteTask.opened || confirmDeleteProfile.opened || root.showHelp) return
        if ((t === "m" || t === "M") && root.ff) root.ff.toggleMute()
      }
    }

    // Alt+H / Alt+L to cycle kanban profiles — wrapped in a zero-size Item
    // because KeyboardPanel's contentItem list only takes QQuickItem
    // (same pattern as hyprmoncfg). ApplicationShortcut context beats
    // PanelKeyCatcher's h/l swallow (it doesn't check Alt modifier).
    Item {
      width: 0
      height: 0
      Shortcut {
        sequence: "Alt+H"
        context: Qt.ApplicationShortcut
        enabled: root.opened && !confirmDeleteDone.opened && !confirmDeleteTask.opened && !confirmDeleteProfile.opened && !root.showHelp && !keyCatcher.blocked
        onActivated: if (root.ff) root.ff.cycleProfile(-1)
      }
      Shortcut {
        sequence: "Alt+L"
        context: Qt.ApplicationShortcut
        enabled: root.opened && !confirmDeleteDone.opened && !confirmDeleteTask.opened && !confirmDeleteProfile.opened && !root.showHelp && !keyCatcher.blocked
        onActivated: if (root.ff) root.ff.cycleProfile(1)
      }
    }

    // Content goes directly here — KeyboardPanel's contentHolder is the
    // default property, and the card BorderSurface is already drawn by
    // KeyboardPanel itself.
    Column {
      id: content
      anchors.fill: parent
      anchors.topMargin: Style.space(4)
      spacing: Style.space(4)
      clip: true

      // breathing room so progress ring doesn't clip card border
      Item { width: parent.width; height: Style.space(4) }

      // ---- TopBar: mark + view switcher + sync status ----
      Column {
        width: parent.width
        spacing: Style.space(2)

        Row {
          width: parent.width
          spacing: Style.space(4)
          Text {
            id: markGlyph
            text: "\uf254"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: appName
            text: "FocusFlow"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            width: Math.max(0, parent.width - markGlyph.width - appName.width - syncDotBtn.width - parent.spacing * 3)
            height: 1
          }
          // Tiny sync indicator — dot opens Vault sync section
          Button {
            id: syncDotBtn
            text: "●"
            fontSize: Style.font.caption
            foreground: !root.ffSettings.obsidianEnabled ? root.dimText : (root.profilePendingPush > 0 ? Color.accent : root.dimText)
            tooltipText: !root.ffSettings.obsidianEnabled ? "Notes export off — open Vault sync" : (root.profilePendingPush > 0 ? (root.profilePendingPush + " pending — open Vault sync") : "Synced ✓ — open Vault sync")
            horizontalPadding: Style.space(2)
            verticalPadding: Style.space(1)
            onClicked: root.setView("settings")
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Four-way view switcher — Focus | Board | Todo | Setup
        Rectangle {
          id: viewSegBox4
          width: parent.width
          height: viewSegRow4.implicitHeight + Style.space(6)
          radius: height / 2
          color: "transparent"
          border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.22)
          border.width: 1
          Row {
            id: viewSegRow4
            anchors.centerIn: parent
            spacing: 0
            Button {
              text: "Focus"
              width: (viewSegBox4.width - Style.space(6)) / root.enabledViewCount
              foreground: root.view === "focus" ? Color.accent : root.dimText
              selected: root.view === "focus"
              radius: height / 2
              fontSize: Style.font.caption
              horizontalPadding: Style.space(2)
              verticalPadding: Style.space(2)
              onClicked: root.setView("focus")
            }
            Button {
              text: "Board"
              visible: root.viewEnabled("kanban")
              width: (viewSegBox4.width - Style.space(6)) / root.enabledViewCount
              foreground: root.view === "kanban" ? Color.accent : root.dimText
              selected: root.view === "kanban"
              radius: height / 2
              fontSize: Style.font.caption
              horizontalPadding: Style.space(2)
              verticalPadding: Style.space(2)
              onClicked: root.setView("kanban")
            }
            Button {
              text: "Todo"
              visible: root.viewEnabled("todo")
              width: (viewSegBox4.width - Style.space(6)) / root.enabledViewCount
              foreground: root.view === "todo" ? Color.accent : root.dimText
              selected: root.view === "todo"
              radius: height / 2
              fontSize: Style.font.caption
              horizontalPadding: Style.space(2)
              verticalPadding: Style.space(2)
              onClicked: root.setView("todo")
            }
            Button {
              text: "Setup"
              width: (viewSegBox4.width - Style.space(6)) / root.enabledViewCount
              foreground: root.view === "settings" ? Color.accent : root.dimText
              selected: root.view === "settings"
              radius: height / 2
              fontSize: Style.font.caption
              horizontalPadding: Style.space(2)
              verticalPadding: Style.space(2)
              tooltipText: "Settings"
              onClicked: root.toggleSettings()
            }
          }
        }
      }

      // ---- Header: timer hero + transport (Focus view) ----
      Column {
        visible: root.view === "focus"
        width: parent.width
        spacing: Style.space(3)

        Row {
          width: parent.width
          spacing: Style.space(4)
          topPadding: Style.space(2)
          bottomPadding: Style.space(1)

        // Progress ring + icon
        Item {
          id: timerRingSlot
          width: Style.space(36)
          height: width
          anchors.verticalCenter: parent.verticalCenter

          Canvas {
            id: timerRing
            anchors.fill: parent
            property real progress: root.timerProgress
            property color ringColor: root.phaseColor
            property real ringWidth: Math.max(2, Style.space(1.5))
            onProgressChanged: requestPaint()
            onRingColorChanged: requestPaint()
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
          }

          Text {
            anchors.centerIn: parent
            text: "\uf254"
            color: root.phaseColor
            font.family: Style.font.family
            font.pixelSize: parent.width * 0.4
          }
        }

        Column {
          id: timerInfoCol
          anchors.verticalCenter: parent.verticalCenter
          spacing: 1
          // Fills the hero row after ring + bell + gear; transport lives on
          // its own row below so the time stays dominant at any width.
          width: Math.max(70, parent.width - timerRingSlot.width - bellBtn.width - gearBtn.width - Style.space(4) * 3)

          Text {
            text: ("Phase · " + Model.phaseLabel(root.phase)).toUpperCase()
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }

          Text {
            text: root.displayText
            color: root.phaseColor
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
          }

          Text {
            text: root.activeTask ? root.activeTask.text : (root.nextUp ? "Next: " + root.nextUp.text : "No tasks")
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }

        // Spacer keeps bell + gear at far right; absorbs only rounding slack
        // since timerInfoCol already fills the row.
        Item {
          id: headerSpacer
          width: Math.max(0, parent.width - timerRingSlot.width - timerInfoCol.width - bellBtn.width - gearBtn.width - Style.space(4) * 3)
          height: 1
        }

        // Master mute bell — immediately silences tick + alarm (M key does the same)
        Button {
          id: bellBtn
          text: root.ffSettings.soundMuted ? "\uf1f6" : "\uf0f3"
          foreground: root.ffSettings.soundMuted ? Color.urgent : root.dimText
          horizontalPadding: Style.space(2)
          verticalPadding: Style.space(2)
          tooltipText: root.ffSettings.soundMuted ? "Unmute all sound (M)" : "Mute all sound (M)"
          onClicked: if (root.ff) root.ff.toggleMute()
          anchors.verticalCenter: parent.verticalCenter
        }

        // Settings gear icon
        Button {
          id: gearBtn
          text: ""
          foreground: root.view === "settings" ? Color.accent : root.dimText
          horizontalPadding: Style.space(2)
          verticalPadding: Style.space(2)
          onClicked: root.toggleSettings()
          anchors.verticalCenter: parent.verticalCenter
        }
        }

        // Transport + view row: pill action group + segmented List/Board
        Row {
          width: parent.width
          spacing: Style.space(4)

          // Pill transport group — primary action takes the accent fill.
          // Auto-width: never clips "Resume" etc. at any theme scale.
          Rectangle {
            id: transportBox
            width: transportRow.implicitWidth + Style.space(8)
            height: transportRow.implicitHeight + Style.space(8)
            radius: height / 2
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
            border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
            border.width: 1
            anchors.verticalCenter: parent.verticalCenter

            Row {
              id: transportRow
              anchors.centerIn: parent
              spacing: Style.space(1)
              Button {
                text: root.isRunning ? "Pause" : (root.isPaused ? "Resume" : "Start")
                foreground: Color.accent
                selected: true
                radius: height / 2
                fontSize: Style.font.caption
                horizontalPadding: Style.space(4)
                verticalPadding: Style.space(2)
                onClicked: root.ff.toggleTimer()
              }
              Button {
                text: "Reset"
                foreground: root.dimText
                radius: height / 2
                fontSize: Style.font.caption
                horizontalPadding: Style.space(4)
                verticalPadding: Style.space(2)
                onClicked: root.ff.resetTimer()
              }
              Button {
                text: "Skip"
                foreground: root.dimText
                radius: height / 2
                fontSize: Style.font.caption
                horizontalPadding: Style.space(4)
                verticalPadding: Style.space(2)
                onClicked: root.ff.skipPhase()
              }
            }
          }

        // Transport pill — primary action takes the accent fill.
        // (View switching moved to the TopBar 4-way segmented control.)
        }
      }

      // ---- Slim timer strip (other views): time + phase + mini transport ----
      Row {
        visible: root.view !== "focus"
        width: parent.width
        spacing: Style.space(6)
        Text {
          id: slimTime
          text: root.displayText
          color: root.phaseColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          id: slimPhase
          text: Model.phaseLabel(root.phase)
          color: root.dimText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
        Item {
          width: Math.max(0, parent.width - slimTime.width - slimPhase.width - slimPause.width - slimSkip.width - parent.spacing * 4)
          height: 1
        }
        Button {
          id: slimPause
          text: root.isRunning ? "Pause" : (root.isPaused ? "Resume" : "Start")
          foreground: Color.accent
          fontSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(1)
          onClicked: root.ff.toggleTimer()
          anchors.verticalCenter: parent.verticalCenter
        }
        Button {
          id: slimSkip
          text: "Skip"
          foreground: root.dimText
          fontSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(1)
          onClicked: root.ff.skipPhase()
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // ---- Focus view body: session strip + progress + duration steppers ----
      Column {
        visible: root.view === "focus"
        width: parent.width
        spacing: Style.space(3)

        // Session strip — live settings, nothing decorative
        Row {
          width: parent.width
          spacing: Style.space(4)
          Text {
            id: sessWorkDot
            text: "●"
            color: Color.accent
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: sessWorkVal
            text: "Work " + Math.round((root.ffSettings.workSec || 1500) / 60) + "m"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: sessBreakDot
            text: "●"
            color: root.dimText
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: sessBreakVal
            text: "Break " + Math.round((root.ffSettings.shortBreakSec || 300) / 60) + "m"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            width: Math.max(0, parent.width - sessWorkDot.width - sessWorkVal.width - sessBreakDot.width - sessBreakVal.width - sessCycle.width - parent.spacing * 5)
            height: 1
          }
          Text {
            id: sessCycle
            text: "1/" + (root.ffSettings.longBreakInterval || 4)
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Progress strip — done/total + focused pomodoros, active space
        Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            id: progLabel
            text: root.profileDoneCount + "/" + root.profileTasks.length + " done"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Item {
            id: progTrack
            width: Math.max(0, parent.width - progLabel.width - progCount.width - parent.spacing * 2)
            height: 4
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
              anchors.fill: parent
              radius: 2
              color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
            }
            Rectangle {
              height: parent.height
              width: parent.width * (root.profileTasks.length > 0 ? root.profileDoneCount / root.profileTasks.length : 0)
              radius: 2
              color: Color.accent
            }
          }
          Text {
            id: progCount
            text: root.profileFocusedCount + " 🍅"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // Duration steppers — same setters as the Setup sliders
        Stepper {
          width: parent.width
          label: "Work duration"
          value: Math.round((root.ffSettings.workSec || 1500) / 60) + "m"
          onDecrease: root.adjustDuration("workSec", -1, 1, 60)
          onIncrease: root.adjustDuration("workSec", 1, 1, 60)
        }
        Stepper {
          width: parent.width
          label: "Short break"
          value: Math.round((root.ffSettings.shortBreakSec || 300) / 60) + "m"
          onDecrease: root.adjustDuration("shortBreakSec", -1, 1, 25)
          onIncrease: root.adjustDuration("shortBreakSec", 1, 1, 25)
        }
        Stepper {
          width: parent.width
          label: "Long break"
          value: Math.round((root.ffSettings.longBreakSec || 900) / 60) + "m"
          onDecrease: root.adjustDuration("longBreakSec", -1, 1, 60)
          onIncrease: root.adjustDuration("longBreakSec", 1, 1, 60)
        }
        Stepper {
          width: parent.width
          label: "Long break every"
          value: String(root.ffSettings.longBreakInterval || 4)
          onDecrease: root.adjustDuration("longBreakInterval", -1, 1, 12)
          onIncrease: root.adjustDuration("longBreakInterval", 1, 1, 12)
        }
      }

      PanelSeparator {}

      // ---- Settings section (collapsible) — compact grid so panel doesn't become tall ----
      Column {
        width: parent.width
        spacing: Style.space(3)
        visible: root.view === "settings"

        PanelSectionHeader { text: "Settings" }

        // ---- Audio group ----
        Text { text: "Audio"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
        // Sound row — always 2-across even on 340px (166px each) to halve height
        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.spacing.controlPaddingX
          rowSpacing: Style.space(2)
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Tick sound"
            description: "Tick every second"
            checked: root.ffSettings.tickEnabled
            onClicked: { root.ff.state.settings.tickEnabled = !root.ffSettings.tickEnabled; root.ff.saveState(); root.ff.applyTickState() }
          }
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Alarm sound"
            description: "Dun on phase end"
            checked: root.ffSettings.alarmEnabled !== false
            onClicked: { root.ff.state.settings.alarmEnabled = !(root.ffSettings.alarmEnabled !== false); root.ff.saveState(); root.ff.applyTickState() }
          }
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Mute all"
            description: "Bell / M key · kills sound"
            checked: root.ffSettings.soundMuted === true
            onClicked: if (root.ff) root.ff.toggleMute()
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.ffSettings.tickEnabled || root.ffSettings.alarmEnabled !== false
          Grid {
            columns: (root.panelWidth >= 500 && root.ffSettings.tickEnabled && root.ffSettings.alarmEnabled !== false) ? 2 : 1
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(2)
            width: parent.width
            Row {
              visible: root.ffSettings.tickEnabled
              spacing: Style.spacing.controlPaddingX
              Text { text: "Tick vol"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 52 }
              PanelSlider { bar: root.bar; minimum: 0; maximum: 1; step: 0.05; value: root.ffSettings.tickVolume; onMoved: function(v){ root.ff.state.settings.tickVolume = v; root.ff.saveState() } ; onReleased: function(v){ root.ff.state.settings.tickVolume = v; root.ff.saveState(); root.ff.applyTickState() }; width: 95 }
              Text { text: Math.round((root.ffSettings.tickVolume || 0) * 100) + "%"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 32 }
            }
            Row {
              visible: root.ffSettings.alarmEnabled !== false
              spacing: Style.spacing.controlPaddingX
              Text { text: "Alarm vol"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 52 }
              PanelSlider { bar: root.bar; minimum: 0; maximum: 1; step: 0.05; value: root.ffSettings.alarmVolume; onMoved: function(v){ root.ff.state.settings.alarmVolume = v; root.ff.saveState() }; onReleased: function(v){ root.ff.state.settings.alarmVolume = v; root.ff.saveState(); root.ff.applyTickState() }; width: 95 }
              Text { text: Math.round((root.ffSettings.alarmVolume || 0) * 100) + "%"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 32 }
            }
          }
        }

        // ---- Board & timing group ----
        Text { text: "Board & timing"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
        // Board / Pomodoros / Continuous — always 2-across
        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.spacing.controlPaddingX
          rowSpacing: Style.space(2)
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Kanban board"
            description: "Backlog/To Do/Doing/Done"
            checked: root.kanbanMode
            onClicked: root.setKanbanMode(!root.kanbanMode)
          }
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Show pomodoros"
            description: "🍅 on cards"
            checked: root.ffSettings.showPomodoros !== false
            onClicked: { root.ff.state.settings.showPomodoros = !(root.ffSettings.showPomodoros !== false); root.ff.saveState(); root.ff.applyTickState() }
          }
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Continuous"
            description: "Auto-start breaks/work"
            checked: root.ffSettings.autoStartBreaks && root.ffSettings.autoStartWork
            onClicked: { var v = !(root.ffSettings.autoStartBreaks && root.ffSettings.autoStartWork); root.ff.state.settings.autoStartBreaks = v; root.ff.state.settings.autoStartWork = v; root.ff.saveState(); root.ff.applyTickState() }
          }
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "To-Do view"
            description: "Todo section enabled"
            checked: root.ffSettings.todoEnabled !== false
            onClicked: { root.ff.state.settings.todoEnabled = !(root.ffSettings.todoEnabled !== false); if (root.ff.state.settings.todoEnabled === false && root.view === "todo") root.setView("focus"); root.ff.saveState(); root.ff.applyTickState() }
          }
          SmallToggle {
            width: (parent.width - parent.columnSpacing)/2
            label: "Kanban view"
            description: "Board section enabled"
            checked: root.ffSettings.kanbanEnabled !== false
            onClicked: { root.ff.state.settings.kanbanEnabled = !(root.ffSettings.kanbanEnabled !== false); if (root.ff.state.settings.kanbanEnabled === false && root.view === "kanban") root.setView("focus"); root.ff.saveState(); root.ff.applyTickState() }
          }
          Item { width: (parent.width - parent.columnSpacing)/2; height: 32 } // spacer to keep grid even
        }

        // Timing — two 110px sliders side-by-side when wide, stacked when narrow
        Grid {
          width: parent.width
          columns: root.panelWidth >= 500 ? 2 : 1
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(2)
          Row {
            spacing: Style.spacing.controlPaddingX
            Text { text: "Work (" + Math.round(root.ffSettings.workSec / 60) + "m)"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 54 }
            PanelSlider {
              bar: root.bar; minimum: 1; maximum: 60; step: 1; integer: true
              value: root.ffSettings.workSec / 60
              onMoved: function(v){ root.ff.state.settings.workSec = Math.floor(v*60); if(root.ff.isStopped && root.ff.phase===Model.PHASE_WORK){ root.ff.state.timer.remainingSec=root.ff.state.settings.workSec; root.ff.state.timer.phaseDurationSec=root.ff.state.settings.workSec } root.ff.saveState(); root.ff.applyTickState() }
              onReleased: function(v){ root.ff.state.settings.workSec = Math.floor(v*60); if(root.ff.isStopped && root.ff.phase===Model.PHASE_WORK){ root.ff.state.timer.remainingSec=root.ff.state.settings.workSec; root.ff.state.timer.phaseDurationSec=root.ff.state.settings.workSec } root.ff.saveState(); root.ff.applyTickState() }
              width: 95
            }
          }
          Row {
            spacing: Style.spacing.controlPaddingX
            Text { text: "Break (" + Math.round(root.ffSettings.shortBreakSec / 60) + "m)"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 54 }
            PanelSlider {
              bar: root.bar; minimum: 1; maximum: 25; step: 1; integer: true
              value: root.ffSettings.shortBreakSec / 60
              onMoved: function(v){ root.ff.state.settings.shortBreakSec = Math.floor(v*60); if(root.ff.isStopped && root.ff.phase===Model.PHASE_SHORT_BREAK){ root.ff.state.timer.remainingSec=root.ff.state.settings.shortBreakSec; root.ff.state.timer.phaseDurationSec=root.ff.state.settings.shortBreakSec } root.ff.saveState(); root.ff.applyTickState() }
              onReleased: function(v){ root.ff.state.settings.shortBreakSec = Math.floor(v*60); if(root.ff.isStopped && root.ff.phase===Model.PHASE_SHORT_BREAK){ root.ff.state.timer.remainingSec=root.ff.state.settings.shortBreakSec; root.ff.state.timer.phaseDurationSec=root.ff.state.settings.shortBreakSec } root.ff.saveState(); root.ff.applyTickState() }
              width: 95
            }
          }
        }

        // ---- Vault sync group (notes export) ----
        PanelSeparator {}
        Text { text: "Vault sync"; color: root.dimText; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
        SmallToggle {
          width: parent.width
          label: "Notes export"
          description: root.ffSettings.obsidianEnabled ? (root.ffSettings.obsidianVaultPath || "no path set") : "Obsidian / any notes app, on approve"
          checked: root.ffSettings.obsidianEnabled === true
          onClicked: { root.ff.state.settings.obsidianEnabled = !root.ffSettings.obsidianEnabled; root.ff.saveState(); root.ff.applyTickState() }
        }
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.ffSettings.obsidianEnabled === true
          TextField {
            width: parent.width
              placeholderText: "Notes folder e.g. ~/Documents/notes — saves to <folder>/focusflow/<Space>.md"
            text: root.ffSettings.obsidianVaultPath || ""
            onAccepted: { root.ff.state.settings.obsidianVaultPath = text.trim().slice(0,500); root.ff.saveState(); root.ff.applyTickState() }
            onEditingFinished: { root.ff.state.settings.obsidianVaultPath = text.trim().slice(0,500); root.ff.saveState(); root.ff.applyTickState() }
          }
          // Path card — resolved destination for the active space + copy.
          Rectangle {
            id: pathCard
            visible: !!root.ffSettings.obsidianVaultPath
            width: parent.width
            height: pathCardRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.05)
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)
            border.width: 1
            Row {
              id: pathCardRow
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(6)
              Text {
                text: root.vaultDestForActive()
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                width: parent.width - copyPathBtn.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
              }
              Button {
                id: copyPathBtn
                text: "Copy"
                fontSize: Style.font.caption
                tooltipText: "Copy notes path to clipboard"
                onClicked: root.copyVaultPath()
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
          // Sync status for the active space
          Text {
            text: {
              var all = Model.tasksForProfile(root.state, root.activeProfileId)
              var pending = all.filter(function(t){return !t.pushedToObsidian || t.pushedColumn !== t.column}).length
              var total = all.length
              var space = root.activeProfile ? root.activeProfile.name : "Default"
              if (!root.ffSettings.obsidianVaultPath) return "set vault path"
              if (pending === 0 && total > 0) return "Synced ✓ · " + space
              return "Sync status: " + pending + "/" + total + " pending · " + space
            }
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
          // Full-width sync action
          Button {
            width: parent.width
            text: "Sync now"
            foreground: Color.accent
            selected: true
            fontSize: Style.font.caption
            enabled: (Model.tasksForProfile(root.state, root.activeProfileId).filter(function(t){return !t.pushedToObsidian || t.pushedColumn !== t.column}).length > 0) && !!root.ffSettings.obsidianVaultPath
            onClicked: root.ff.pushAllDoneToObsidian()
          }
        }

        PanelSeparator {}
      }

      // ---- Tasks section (Board + Todo views) ----
      Row {
        visible: root.view === "kanban" || root.view === "todo"
        width: parent.width
        spacing: Style.space(6)
        PanelSectionHeader {
          width: parent.width - helpBtn.width - parent.spacing
          text: (root.kanbanMode ? "Kanban" : "Tasks") + " — " + (root.activeProfile ? root.activeProfile.name : "Default")
          elide: Text.ElideRight
        }
        Button {
          id: helpBtn
          text: "?"
          foreground: Color.urgent
          fontSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(1)
          tooltipText: "Bindings & tips"
          onClicked: root.showHelp = !root.showHelp
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // Spaces switchboard — visible in Todo AND Board (profiles scope both).
      // Alt+H / Alt+L and ◀ ▶ cycle from either view.
      Column {
        visible: root.view === "kanban" || root.view === "todo"
        width: parent.width
        spacing: Style.space(3)

        Row {
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Spaces:"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          // ◀ ▶ cycle buttons — mouse/touch alternative to Alt+H/L
          Button {
            id: prevProfileBtn
            text: "◀"
            foreground: root.dimText
            fontSize: Style.font.caption
            horizontalPadding: Style.space(3)
            verticalPadding: Style.space(2)
            tooltipText: "Previous space (Alt+H)"
            onClicked: if (root.ff) root.ff.cycleProfile(-1)
          }
          Button {
            id: nextProfileBtn
            text: "▶"
            foreground: root.dimText
            fontSize: Style.font.caption
            horizontalPadding: Style.space(3)
            verticalPadding: Style.space(2)
            tooltipText: "Next space (Alt+L)"
            onClicked: if (root.ff) root.ff.cycleProfile(1)
          }

          Flickable {
            // Hug the pills instead of filling the row, so "+" parks right
            // after the last space instead of stranding ~360px of dead
            // scroller interior. Still caps at available width + scrolls.
            width: Math.min(parent.width - 52 - prevProfileBtn.width - nextProfileBtn.width - addProfileBtn.width - Style.space(4)*4 - Style.spacing.controlPaddingX, Math.max(profileRow.implicitWidth, 1))
            height: 28
            contentWidth: profileRow.implicitWidth
            contentHeight: 28
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
              id: profileRow
              spacing: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter

              Repeater {
                model: root.profiles
                delegate: Button {
                  required property var modelData
                  property var profile: modelData
                  text: profile.name
                  foreground: profile.id === root.activeProfileId ? Color.accent : root.dimText
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(2)
                  tooltipText: profile.id === root.activeProfileId ? ("Active space — " + profile.name) : ("Switch to " + profile.name)
                  onClicked: root.ff.setActiveProfile(profile.id)
                }
              }
            }
          }

          Button {
            id: addProfileBtn
            text: "+"
            foreground: Color.accent
            fontSize: Style.font.caption
            horizontalPadding: Style.space(4)
            verticalPadding: Style.space(2)
            tooltipText: "New space"
            onClicked: { root.isRenaming = false; root.showProfileCreator = !root.showProfileCreator; if (root.showProfileCreator) Qt.callLater(function() { profileInput.forceActiveFocus() }) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.showProfileCreator

          Row {
            width: parent.width
            spacing: Style.spacing.controlPaddingX

            TextField {
              id: profileInput
              width: parent.width - createBtn.width - cancelBtn.width - Style.spacing.controlPaddingX*2
              placeholderText: root.isRenaming ? "Rename space…" : "New space name…"
              text: root.newProfileName
              maximumLength: 30
              onTextChanged: root.newProfileName = text.slice(0,30)
              onAccepted: root.confirmProfileName()
              Keys.onEscapePressed: function(event) { profileInput.focus = false; keyCatcher.forceActiveFocus(); event.accepted = true }
            }

            Button {
              id: createBtn
              text: root.isRenaming ? "Save" : "Create"
              foreground: Color.accent
              fontSize: Style.font.caption
              enabled: root.newProfileName.trim().length > 0
              onClicked: root.confirmProfileName()
            }

            Button {
              id: cancelBtn
              text: "✕"
              foreground: root.dimText
              fontSize: Style.font.caption
              onClicked: { root.showProfileCreator = false; root.isRenaming = false; root.newProfileName = ""; profileInput.text = "" }
            }
          }
        }

        // Active space management — ALWAYS visible so Remove is discoverable
        // (previously hidden inside the creator, which is why removal felt missing).
        Row {
          width: parent.width
          spacing: Style.spacing.controlPaddingX
          visible: root.activeProfile && root.activeProfile.id !== "default"

          Text {
            text: "Active: " + (root.activeProfile ? root.activeProfile.name : "") + " (" + Model.tasksForProfile(root.state, root.activeProfileId).length + ")"
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            width: parent.width - renameBtn.width - deleteProfileBtn.width - parent.spacing*2
          }

          Button {
            id: renameBtn
            text: "Rename"
            foreground: Color.accent
            fontSize: Style.font.caption
            tooltipText: "Rename this space"
            onClicked: {
              root.newProfileName = root.activeProfile ? root.activeProfile.name : ""
              profileInput.text = root.newProfileName
              root.isRenaming = true
              root.showProfileCreator = true
              Qt.callLater(function() { profileInput.forceActiveFocus(); profileInput.selectAll() })
            }
          }

          Button {
            id: deleteProfileBtn
            text: "Remove"
            foreground: Color.urgent
            fontSize: Style.font.caption
            tooltipText: "Remove this space (asks Yes/No)"
            onClicked: { confirmDeleteProfile.opened = true; keyCatcher.forceActiveFocus() }
          }
        }
      }

      // New task input — scoped to active profile heading
      Row {
        visible: root.view === "kanban" || root.view === "todo"
        width: parent.width
        spacing: Style.spacing.controlPaddingX

        TextField {
          id: taskInput
          width: parent.width - addButton.implicitWidth - Style.spacing.controlPaddingX
          placeholderText: root.activeProfile ? ("Add to " + root.activeProfile.name + "…") : "Add a task..."
          text: root.newTaskText
          maximumLength: 200
          onTextChanged: root.newTaskText = text.slice(0, 200)
          onAccepted: root.addTaskFromInput()
          Keys.onEscapePressed: function(event) { taskInput.focus = false; keyCatcher.forceActiveFocus(); event.accepted = true }
        }

        Button {
          id: addButton
          text: "+"
          foreground: Color.accent
          onClicked: root.addTaskFromInput()
        }
      }

      // Task search — filters Board columns + Todo list by title
      TextField {
        visible: root.view === "kanban" || root.view === "todo"
        width: parent.width
        placeholderText: "Search tasks…"
        text: root.searchText
        maximumLength: 100
        onTextChanged: root.searchText = text.slice(0, 100)
        Keys.onEscapePressed: function(event) { searchField.focus = false; keyCatcher.forceActiveFocus(); event.accepted = true }
        id: searchField
      }

      // Task list / kanban board
      Item {
        visible: root.view === "kanban" || root.view === "todo"
        width: parent.width
        height: root.kanbanMode ? kanbanContainer.height : plainList.height
        implicitHeight: height
        clip: true

        // Plain list mode — Open / Completed sections, scoped to active profile
        ListView {
          id: plainList
          visible: root.view === "todo"
          width: parent.width
          height: Math.min(contentHeight, Style.space(320))
          interactive: true
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: Model.tasksForProfile(root.state, root.activeProfileId).filter(root.taskMatches).sort(function(a, b){ return ((a.done ? 1 : 0) - (b.done ? 1 : 0)) || ((a.createdAt || 0) - (b.createdAt || 0)) })
          section.property: "done"
          section.criteria: ViewSection.FullString
          section.delegate: Text {
            width: plainList.width
            text: section === "true" ? ("Completed · " + root.profileDoneCount) : ("Open · " + (root.profileTasks.length - root.profileDoneCount))
            color: root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
          spacing: 8

          delegate: Rectangle {
            id: plainDelegate
            width: plainList.width
            height: taskRow.implicitHeight + Style.space(8)
            radius: Style.cornerRadius / 2
            color: plainDelegate.isHovered ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.07)
                  : task.done ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08) : "transparent"
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
            border.width: 0

            required property var modelData
            property var task: modelData
            property bool isHovered: false
            HoverHandler { id: plainHover; onHoveredChanged: plainDelegate.isHovered = hovered }

            Row {
              id: taskRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(2)
              anchors.rightMargin: Style.space(6) // reserve for top-corner delete
              spacing: Style.spacing.controlPaddingX

              // Custom checkbox — avoids broken QtQuick.Controls CheckBox styling
              Rectangle {
                id: checkBox
                width: 18
                height: 18
                radius: 4
                color: task.done ? Color.accent : "transparent"
                border.color: task.done ? Color.accent : root.dimText
                border.width: 1.5
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  text: "✓"
                  color: Color.popups.background
                  font.pixelSize: 11
                  font.bold: true
                  visible: task.done
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.ff.toggleTaskDone(task.id)
                }
              }

              Text {
                id: taskText
                text: task.text
                color: task.done ? root.dimText : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.strikeout: task.done
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                // Constant width — hover actions float above in a pill, so the
                // row never jumps/resizes on hover.
                width: parent.width - checkBox.width - focusBtn.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: focusBtn
                text: task.id === root.timer.activeTaskId ? "●" : "○"
                foreground: task.id === root.timer.activeTaskId ? Color.accent : root.dimText
                onClicked: root.ff.setActiveTask(task.id)
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            // Hover action pill — → move column, ▲ ▼ prioritize, ⬆/↩ vault, - delete.
            // Parked left of the focus dot so ○ is never covered; resting row stays airy.
            Rectangle {
              id: hoverPill
              visible: plainDelegate.isHovered
              // Positioned via x/y (not anchors): parks left of the focus dot
              // so ○ is never covered. No anchor to nested items involved.
              x: parent.width - width - focusBtn.width - Style.space(8)
              y: Math.round((parent.height - height) / 2)
              width: hoverRow.implicitWidth + Style.space(14)
              height: hoverRow.implicitHeight + Style.space(7)
              radius: Style.cornerRadius / 2
              color: Color.popups.background
              border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
              border.width: 1
              Row {
                id: hoverRow
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  text: "→"
                  color: root.dimText
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.cycleTaskColumn(task)
                  }
                }
                Text {
                  text: "▲"
                  color: root.dimText
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.ff.moveTaskUp(task.id)
                  }
                }
                Text {
                  text: "▼"
                  color: root.dimText
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.ff.moveTaskDown(task.id)
                  }
                }
                Text {
                  visible: root.ffSettings.obsidianEnabled === true
                  text: (task.pushedToObsidian && task.pushedColumn === task.column) ? "↩" : "⬆"
                  color: (task.pushedToObsidian && task.pushedColumn === task.column) ? Color.urgent : Color.accent
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    enabled: parent.visible
                    onClicked: {
                      if (task.pushedToObsidian && task.pushedColumn === task.column) root.ff.undoPushToObsidian(task.id)
                      else root.ff.pushTaskToObsidian(task.id)
                    }
                  }
                }
                Text {
                  text: "-"
                  color: Color.urgent
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requestDeleteTask(task)
                  }
                }
              }
            }
          }
        }

        // Kanban mode — horizontal scroll for columns + per-column vertical scroll for overflow (todo with many cards)
        // Outer keeps horizontal flick; vertical overflow is per-column Flickable so todo's extra cards aren't clipped.
        Flickable {
          id: kanbanContainer
          visible: root.view === "kanban"
          width: parent.width
          onWidthChanged: console.warn("[ff-dbg] W viewport=" + width + " rowImplicit=" + kanbanRow.implicitWidth + " kb=" + root.kanbanMode + " ffNull=" + (root.ff === null))
          height: Math.min(contentHeight, Style.space(300))
          contentWidth: kanbanRow.implicitWidth
          contentHeight: kanbanRow.implicitHeight
          clip: true
          flickableDirection: Flickable.HorizontalFlick
          boundsBehavior: Flickable.StopAtBounds

          Row {
            id: kanbanRow
            spacing: Style.space(12)
            Component.onCompleted: console.warn("[ff-dbg] panelWidth=" + root.panelWidth + " viewport=" + kanbanContainer.width + " rowImplicit=" + implicitWidth + " col0=" + (children.length > 0 ? children[0].width : -1) + " cardW=" + panel.contentWidth)

            Repeater {
              model: Model.COLUMNS

              delegate: Item {
                required property string modelData
                property string colId: modelData

                // Adaptive: the 4 columns always share the viewport exactly,
                // so no dead strip on the right at any theme scale. Falls back
                // to 120px + horizontal scroll on very narrow viewports.
                // (No binding loop: viewport width comes from layout, and
                // contentWidth only follows implicitWidth one way.)
                width: Math.max(120, Math.floor((kanbanContainer.width - Style.space(12) * 3) / 4))
                implicitHeight: colInner.implicitHeight + Style.space(12)
                // Explicit height too: positioners lay out width/height, and
                // colInner anchors.fill needs a concrete parent height.
                height: colInner.implicitHeight + Style.space(12)

                // Shaded column container — theme-safe foreground wash
                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.045)
                  border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                  border.width: 1
                }

                Column {
                  id: colInner
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  spacing: Style.space(8)

                // Header with pill count badge — accent when non-zero
                Row {
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    text: String(Model.COLUMN_LABELS[colId]).toUpperCase()
                    color: root.dimText
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }
                  Rectangle {
                    property int count: Model.tasksByColumn(root.state, colId, root.activeProfileId).filter(root.taskMatches).length
                    width: countText.implicitWidth + Style.space(8)
                    height: Style.space(14)
                    radius: height/2
                    color: count > 0 ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10)
                    Text {
                      id: countText
                      anchors.centerIn: parent
                      text: String(parent.count)
                      color: parent.count > 0 ? Color.accent : root.dimText
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption - 1
                      font.bold: true
                    }
                  }
                }
                Rectangle { width: parent.width; height: 1; color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.10); radius: 1 }

                // Per-column vertical scroll so todo with 20+ cards isn't invisible beyond 180px cap
                Flickable {
                  width: parent.width
                  height: Math.min(colTasks.implicitHeight, Style.space(260))
                  contentHeight: colTasks.implicitHeight
                  contentWidth: width
                  clip: true
                  flickableDirection: Flickable.VerticalFlick
                  boundsBehavior: Flickable.StopAtBounds

                  Column {
                    id: colTasks
                    width: parent.width
                    spacing: 8

                    Repeater {
                      model: Model.tasksByColumn(root.state, colId).filter(root.taskMatches)

                  delegate: Rectangle {
                    id: kanbanCard
                    required property var modelData
                    property var task: modelData
                    property bool isHovered: false
                    width: parent.width
                    height: taskCardCol.implicitHeight + Style.space(6)
                    radius: Style.cornerRadius
                    clip: true
                    color: task.id === root.timer.activeTaskId ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.14) : Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.04)
                    border.color: task.id === root.timer.activeTaskId ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.20)
                    border.width: task.id === root.timer.activeTaskId ? 1.5 : 1
                    HoverHandler { id: kanbanHover; onHoveredChanged: kanbanCard.isHovered = hovered }

                    // Left accent for active task — stable, not floating
                    Rectangle {
                      visible: task.id === root.timer.activeTaskId
                      width: 3
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      color: Color.accent
                      radius: 1
                    }

                    Column {
                      id: taskCardCol
                      anchors.fill: parent
                      anchors.margins: Style.space(4)
                      anchors.leftMargin: task.id === root.timer.activeTaskId ? Style.space(6) : Style.space(4)
                      anchors.topMargin: Style.space(5) // reserve for top-right delete
                      anchors.rightMargin: Style.space(4)
                      spacing: 6

                      Row {
                        width: parent.width - 14 // reserve for top-right delete
                        spacing: 4
                        Text {
                          visible: task.id === root.timer.activeTaskId
                          text: "●"
                          color: Color.accent
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                          text: task.text
                          color: task.id === root.timer.activeTaskId ? Color.accent : Color.popups.text
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          font.bold: task.id === root.timer.activeTaskId
                          wrapMode: Text.Wrap
                          width: parent.width - (task.id === root.timer.activeTaskId ? 12 : 0)
                        }
                      }

                      // Pomodoro mini-widget — tomato + progress toward estimate
                      Row {
                        visible: root.ffSettings.showPomodoros !== false
                        spacing: Style.space(4)
                        anchors.left: parent.left
                        property int spent: task.pomodorosSpent || 0
                        property int est: task.pomodorosEstimated || 0

                        Text {
                          text: "🍅"
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Item {
                          width: 56
                          height: 4
                          anchors.verticalCenter: parent.verticalCenter
                          Rectangle {
                            anchors.fill: parent
                            radius: 2
                            color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
                          }
                          Rectangle {
                            height: parent.height
                            width: parent.width * Math.max(0, Math.min(1, parent.parent.est > 0 ? parent.parent.spent / parent.parent.est : 0))
                            radius: 2
                            color: Color.accent
                          }
                        }
                        Text {
                          text: parent.spent + "/" + parent.est
                          color: root.dimText
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      Item {
                        width: parent.width
                        height: 22
                        clip: true

                        Row {
                          id: kanbanMoveRow
                          spacing: 6
                          anchors.left: parent.left
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            text: "←"
                            color: colId === "backlog" ? root.dimText : Color.accent
                            font.pixelSize: Style.font.body
                            opacity: colId === "backlog" ? 0.35 : 1
                            MouseArea {
                              anchors.fill: parent
                              anchors.margins: -4
                              cursorShape: colId === "backlog" ? Qt.ArrowCursor : Qt.PointingHandCursor
                              enabled: colId !== "backlog"
                              onClicked: {
                                var idx = Model.COLUMNS.indexOf(colId)
                                if (idx > 0) root.ff.moveTask(task.id, Model.COLUMNS[idx - 1])
                              }
                            }
                          }

                          Text {
                            text: "→"
                            color: colId === "done" ? root.dimText : Color.accent
                            font.pixelSize: Style.font.body
                            opacity: colId === "done" ? 0.35 : 1
                            MouseArea {
                              anchors.fill: parent
                              anchors.margins: -4
                              cursorShape: colId === "done" ? Qt.ArrowCursor : Qt.PointingHandCursor
                              enabled: colId !== "done"
                              onClicked: {
                                var idx = Model.COLUMNS.indexOf(colId)
                                if (idx < Model.COLUMNS.length - 1) root.ff.moveTask(task.id, Model.COLUMNS[idx + 1])
                              }
                            }
                          }
                        }

                        // Hover-only up/down to prioritize — visible only when hovered
                        Row {
                          visible: kanbanCard.isHovered
                          spacing: 4
                          anchors.centerIn: parent
                          Text {
                            text: "▲"
                            color: root.dimText
                            font.pixelSize: Style.font.caption
                            MouseArea {
                              anchors.fill: parent
                              anchors.margins: -4
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.ff.moveTaskUp(task.id)
                            }
                          }
                          Text {
                            text: "▼"
                            color: root.dimText
                            font.pixelSize: Style.font.caption
                            MouseArea {
                              anchors.fill: parent
                              anchors.margins: -4
                              cursorShape: Qt.PointingHandCursor
                              onClicked: root.ff.moveTaskDown(task.id)
                            }
                          }
                        }

                        // Vault push — any column, manual approve; ↩ undoes (removes from vault + clears flag)
                        Text {
                          visible: root.ffSettings.obsidianEnabled === true
                          text: (task.pushedToObsidian && task.pushedColumn === task.column) ? "↩" : "⬆"
                          color: (task.pushedToObsidian && task.pushedColumn === task.column) ? Color.urgent : Color.accent
                          font.pixelSize: Style.font.body
                          font.bold: true
                          anchors.right: parent.right
                          anchors.rightMargin: 2
                          anchors.verticalCenter: parent.verticalCenter
                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            enabled: parent.visible
                            onClicked: {
                              if (task.pushedToObsidian && task.pushedColumn === task.column) root.ff.undoPushToObsidian(task.id)
                              else root.ff.pushTaskToObsidian(task.id)
                            }
                          }
                        }
                      }
                    }
                    // – at right-hand top corner to remove task (kanban) — asks Yes/No before removing
                    Text {
                      text: "-"
                      color: Color.urgent
                      font.pixelSize: 12
                      font.bold: true
                      z: 10
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.rightMargin: 6
                      anchors.topMargin: 2

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        z: 10
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        onClicked: root.requestDeleteTask(task)
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      // don't steal clicks from the move/delete buttons
                      enabled: false
                    }

                    // Separate area for focusing, above buttons
                    MouseArea {
                      x: 0; y: 0
                      width: parent.width
                      height: parent.height - 22
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.ff.setActiveTask(task.id)
                    }
                  }
                }
              }
            }
          }
        }
        }
        }
      }
    }

    }

    // Confirm dialogs — MUST be direct children of KeyboardPanel (same
    // PanelWindow focus scope) so they actually render above content.
    // Previously at root Panel level they were invisible, making "-" do nothing.
    ConfirmDialog {
      id: confirmDeleteTask
      anchors.fill: parent
      z: 100
      property string taskId: ""
      property string taskText: ""
      message: "Delete task \"" + taskText + "\"? Also removes from notes if pushed. This cannot be undone."
      confirmText: "Delete"
      cancelText: "Cancel"
      onConfirmed: { if (taskId && root.ff) root.ff.deleteTask(taskId); opened = false; taskId = ""; taskText = "" }
      onCanceled: { opened = false; taskId = ""; taskText = "" }
    }

    // Done-task delete choice — deleting from Done means finished. Offer:
    // Archive (save "- [x]" in notes + remove from board) vs Delete
    // everywhere (also remove the notes line). ConfirmDialog only supports
    // 2 buttons, so this is a custom 3-button overlay in the same style.
    Item {
      id: confirmDeleteDone
      anchors.fill: parent
      z: 110
      visible: opened
      property bool opened: false
      property string taskId: ""
      property string taskText: ""
      // 0 = Cancel, 1 = Archive [x], 2 = Delete everywhere
      property int selectedIndex: 1

      function openFor(task) {
        taskId = task.id
        taskText = task.text
        selectedIndex = 1 // default to Archive — the safe, non-destructive choice
        opened = true
      }
      function closeDialog() { opened = false; taskId = ""; taskText = ""; selectedIndex = 1 }
      function cycleSelection(dir) {
        var d = (dir === undefined || dir === 0) ? 1 : (dir > 0 ? 1 : -1)
        selectedIndex = (selectedIndex + d + 3) % 3
      }
      function activateSelected() {
        if (!opened) return
        if (selectedIndex === 0) closeDialog()
        else if (selectedIndex === 1) { if (taskId && root.ff) root.ff.archiveDoneTask(taskId); closeDialog() }
        else { if (taskId && root.ff) root.ff.deleteTask(taskId); closeDialog() }
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.7)
        MouseArea { anchors.fill: parent; onClicked: confirmDeleteDone.closeDialog() }

        BorderSurface {
          id: doneCard
          width: Math.min(parent.width - Style.space(32), Style.space(370))
          height: contentTopInset + contentBottomInset + doneMsg.implicitHeight + Style.space(16) + Style.space(34)
          anchors.centerIn: parent
          color: Color.background
          borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
          padding: Style.space(18)
          radius: Style.cornerRadius
          MouseArea { anchors.fill: parent; onClicked: {} }

          Item {
            anchors.fill: parent
            anchors.topMargin: doneCard.contentTopInset
            anchors.rightMargin: doneCard.contentRightInset
            anchors.bottomMargin: doneCard.contentBottomInset
            anchors.leftMargin: doneCard.contentLeftInset

            Text {
              id: doneMsg
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              text: "Done — \"" + confirmDeleteDone.taskText + "\" is finished. Archive as - [x] in notes and remove from board, or delete everywhere (also removes from notes)?"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              wrapMode: Text.WordWrap
            }

            Row {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(8)

              Repeater {
                model: ["Cancel", "Archive [x]", "Delete all"]
                delegate: BorderSurface {
                  required property int index
                  required property string modelData
                  readonly property bool selected: confirmDeleteDone.selectedIndex === index
                  readonly property bool destructive: index === 2
                  width: index === 1 ? Style.space(96) : Style.space(80)
                  height: Style.space(34)
                  color: selected
                    ? (destructive ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.22) : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.08))
                    : "transparent"
                  borderSpec: Border.flat(destructive
                    ? (selected ? Color.urgent : Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.56))
                    : (selected ? Color.accent : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.38)), Style.normalBorderWidth)
                  radius: 0
                  Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: destructive ? (selected ? Color.urgent : Color.foreground) : (selected ? Color.accent : Color.foreground)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: confirmDeleteDone.selectedIndex = index
                    onClicked: { confirmDeleteDone.selectedIndex = index; confirmDeleteDone.activateSelected() }
                  }
                }
              }
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: confirmDeleteProfile
      anchors.fill: parent
      z: 100
      message: "Remove space \"" + (root.activeProfile ? root.activeProfile.name : "") + "\" and " + Model.tasksForProfile(root.state, root.activeProfileId).length + " tasks? Vault file kept. This cannot be undone."
      confirmText: "Remove"
      cancelText: "Cancel"
      onConfirmed: { if (root.ff) root.ff.deleteProfile(root.activeProfileId); opened = false }
      onCanceled: opened = false
    }

    // Bindings & tips cheat-sheet — opened by the ? button in the section header.
    // Overlay like the confirms (direct KeyboardPanel child), below them at z:90.
    Item {
      id: helpOverlay
      anchors.fill: parent
      z: 90
      visible: root.showHelp

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.72)
        MouseArea { anchors.fill: parent; onClicked: root.showHelp = false }
      }

      Rectangle {
        id: helpCard
        width: Math.min(parent.width - Style.space(32), Style.space(400))
        height: helpCol.implicitHeight + Style.space(24)
        anchors.centerIn: parent
        radius: Style.cornerRadius
        color: Color.popups.background
        border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)
        border.width: 1
        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          id: helpCol
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(4)

          Text {
            text: "Bindings & tips"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Repeater {
            model: [
              { key: "Space", desc: "start / pause timer" },
              { key: "M", desc: "mute / unmute all sound (🔔)" },
              { key: "Tab", desc: "cycle Focus → Board → Todo" },
              { key: "Alt+H / Alt+L", desc: "previous / next space" },
              { key: "○ / ●", desc: "focus a task (shows as Next)" },
              { key: "☐", desc: "toggle done" },
              { key: "← →", desc: "move card between columns" },
              { key: "hover", desc: "▲ ▼ prioritize · ⬆ push to notes · − delete" },
              { key: "search", desc: "filter Board + Todo by title" },
              { key: "− on Done", desc: "archive [x] in notes or delete everywhere" },
              { key: "Esc", desc: "unfocus input · close popup · close panel" }
            ]
            delegate: Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: modelData.key
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                width: 92
                elide: Text.ElideRight
              }
              Text {
                text: modelData.desc
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: parent.width - 100
              }
            }
          }

          Item { width: parent.width; height: Style.space(2) }

          Button {
            text: "Close"
            foreground: Color.accent
            fontSize: Style.font.caption
            anchors.horizontalCenter: parent.horizontalCenter
            onClicked: root.showHelp = false
          }
        }
      }
    }
  }

  // ---- Helpers ----
  function addTaskFromInput() {
    var text = root.newTaskText.trim()
    if (!text) return
    root.ff.addTask(text, "todo")
    root.newTaskText = ""
    taskInput.text = ""
  }

  // Shortened per-profile vault destination for the active space,
  // e.g. ~/Documents/Obsidian-Vault/sync/focusflow/freelance.md
  // Full (unshortened) per-profile vault destination for the active space
  function vaultFullDestForActive() {
    var name = root.activeProfile ? root.activeProfile.name : "Default"
    return Model.obsidianFilePathForProfile(root.ffSettings, root.ffSettings.obsidianVaultPath, root.activeProfileId, name) || ""
  }

  // Shortened for display (~/…).
  function vaultDestForActive() {
    var p = vaultFullDestForActive()
    if (!p) return ""
    var home = Quickshell.env("HOME") || ""
    if (home && p.indexOf(home) === 0) p = "~" + p.slice(home.length)
    return p
  }

  // Copies the resolved notes path for the active space (wl-copy, no shell).
  function copyVaultPath() {
    var p = vaultFullDestForActive()
    if (!p) return
    Quickshell.execDetached(["wl-copy", "--", p])
  }

  function confirmProfileName() {
    var name = root.newProfileName.trim()
    if (!name) return
    if (root.isRenaming) root.ff.renameProfile(root.activeProfileId, name)
    else root.ff.createProfile(name)
    root.newProfileName = ""
    profileInput.text = ""
    root.showProfileCreator = false
    root.isRenaming = false
  }

  function cycleTaskColumn(task) {
    var cols = Model.COLUMNS
    var idx = cols.indexOf(task.column)
    var next = cols[(idx + 1) % cols.length]
    root.ff.moveTask(task.id, next)
  }

  function isNotesLinked() {
    return root.ffSettings.obsidianEnabled === true && !!(root.ffSettings.obsidianVaultPath || "").trim()
  }

  // Deleting a Done task means finished: when notes are linked, ask whether
  // to Archive ([x] in notes + remove from board) or Delete everywhere
  // (also removes the notes line). Anything else uses the plain confirm.
  function requestDeleteTask(task) {
    if (!task) return
    var isDone = task.done === true || task.column === "done"
    if (isDone && isNotesLinked()) {
      if (confirmDeleteTask.opened) { confirmDeleteTask.opened = false; confirmDeleteTask.taskId = ""; confirmDeleteTask.taskText = "" }
      confirmDeleteDone.openFor(task)
    } else {
      if (confirmDeleteDone.opened) confirmDeleteDone.closeDialog()
      confirmDeleteTask.taskId = task.id
      confirmDeleteTask.taskText = task.text
      confirmDeleteTask.opened = true
    }
    keyCatcher.forceActiveFocus()
  }

  function setKanbanMode(v) {
    if (!root.ff) return
    root.ff.state.settings.kanbanMode = v
    root.ff.saveState()
    root.ff.applyTickState()
  }

  // View switching — kanban/todo views keep the persisted kanbanMode in
  // sync (same contract as the old List/Board toggle); focus/settings are
  // display-only and leave it alone.
  function viewEnabled(v) {
    if (v === "kanban") return root.ffSettings.kanbanEnabled !== false
    if (v === "todo") return root.ffSettings.todoEnabled !== false
    return true
  }

  readonly property int enabledViewCount: 2 + (root.viewEnabled("kanban") ? 1 : 0) + (root.viewEnabled("todo") ? 1 : 0)

  function setView(v) {
    if (!root.viewEnabled(v)) v = "focus"
    if (v === "settings" && root.view !== "settings") root.viewBeforeSettings = root.view
    root.view = v
    if (v === "kanban") setKanbanMode(true)
    else if (v === "todo") setKanbanMode(false)
  }

  function cycleView(direction) {
    var order = ["focus", "kanban", "todo"].filter(root.viewEnabled)
    if (order.length === 0) return
    var i = order.indexOf(root.view)
    if (i < 0) i = 0
    var d = (direction === undefined || direction >= 0) ? 1 : -1
    setView(order[(i + d + order.length) % order.length])
  }

  // Live title search across Board columns + Todo list
  function taskMatches(task) {
    var q = root.searchText.trim().toLowerCase()
    if (!q || !task) return true
    return (task.text || "").toLowerCase().indexOf(q) !== -1
  }

  function toggleSettings() {
    if (root.view === "settings") setView(root.viewBeforeSettings || "focus")
    else setView("settings")
  }

  // Minute stepper for durations — mirrors the slider commit logic so the
  // stopped-timer display follows immediately.
  function adjustDuration(key, delta, min, max) {
    if (!root.ff) return
    var s = root.ff.state.settings
    if (key === "longBreakInterval") {
      var cur = s.longBreakInterval || 4
      s.longBreakInterval = Math.max(min, Math.min(max, cur + delta))
    } else {
      var curMin = Math.round((s[key] || 1500) / 60)
      var nextMin = Math.max(min, Math.min(max, curMin + delta))
      s[key] = nextMin * 60
      if (root.ff.isStopped) {
        var ph = root.ff.phase
        if ((key === "workSec" && ph === Model.PHASE_WORK)
          || (key === "shortBreakSec" && ph === Model.PHASE_SHORT_BREAK)
          || (key === "longBreakSec" && ph === Model.PHASE_LONG_BREAK)) {
          root.ff.state.timer.remainingSec = s[key]
          root.ff.state.timer.phaseDurationSec = s[key]
        }
      }
    }
    root.ff.saveState()
    root.ff.applyTickState()
  }
}
