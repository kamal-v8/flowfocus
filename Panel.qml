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
  readonly property var nextUp: Model.nextTask(state)
  readonly property bool kanbanMode: ffSettings.kanbanMode === true

  // ---- UI state ----
  property string newTaskText: ""
  property bool settingsVisible: false

  // ---- Layout ----
  readonly property int basePanelWidth: Style.space(340)
  readonly property int kanbanPanelWidth: Style.space(520)
  readonly property int panelWidth: root.kanbanMode ? kanbanPanelWidth : basePanelWidth

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
          color: Color.muted
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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.ff.toggleTimer()
    }

    // Content goes directly here — KeyboardPanel's contentHolder is the
    // default property, and the card BorderSurface is already drawn by
    // KeyboardPanel itself.
    Column {
      id: content
      anchors.fill: parent
      anchors.topMargin: Style.space(4)
      spacing: Style.space(4)

      // breathing room so progress ring doesn't clip card border
      Item { width: parent.width; height: Style.space(4) }

      // ---- Header row: timer info + settings gear ----
      Row {
        width: parent.width
        spacing: Style.spacing.controlPaddingX
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
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2
          width: parent.width - timerRingSlot.width - gearBtn.width - Style.spacing.controlPaddingX * 2

          Text {
            text: Model.phaseLabel(root.phase)
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
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
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }

        // Settings gear icon
        Button {
          id: gearBtn
          text: "\uf013"
          foreground: root.settingsVisible ? Color.accent : Color.muted
          onClicked: root.settingsVisible = !root.settingsVisible
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // ---- Timer controls ----
      Row {
        width: parent.width
        spacing: Style.spacing.controlPaddingX

        Button {
          text: root.isRunning ? "Pause" : (root.isPaused ? "Resume" : "Start")
          foreground: Color.accent
          onClicked: root.ff.toggleTimer()
        }

        Button {
          text: "Reset"
          foreground: Color.muted
          onClicked: root.ff.resetTimer()
        }

        Button {
          text: "Skip"
          foreground: Color.muted
          onClicked: root.ff.skipPhase()
        }

        // Kanban toggle — quick access in the timer row
        Button {
          text: root.kanbanMode ? "Board" : "List"
          foreground: root.kanbanMode ? Color.accent : Color.muted
          onClicked: {
            root.ff.state.settings.kanbanMode = !root.ffSettings.kanbanMode
            root.ff.saveState()
            root.ff.applyTickState()
          }
        }
      }

      // ---- Cycle info ----
      Text {
        text: "Cycle " + (Math.floor(root.timer.completedWorkPhases / root.ffSettings.longBreakInterval) + 1) +
              " — " + root.timer.completedWorkPhases + " pomodoros done"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSeparator {}

      // ---- Settings section (collapsible) — compact grid so panel doesn't become tall ----
      Column {
        width: parent.width
        spacing: Style.space(3)
        visible: root.settingsVisible

        PanelSectionHeader { text: "Settings" }

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
              Text { text: "Tick vol"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 52 }
              PanelSlider { bar: root.bar; minimum: 0; maximum: 1; step: 0.05; value: root.ffSettings.tickVolume; onMoved: function(v){ root.ff.state.settings.tickVolume = v; root.ff.saveState() } ; onReleased: function(v){ root.ff.state.settings.tickVolume = v; root.ff.saveState(); root.ff.applyTickState() }; width: 95 }
            }
            Row {
              visible: root.ffSettings.alarmEnabled !== false
              spacing: Style.spacing.controlPaddingX
              Text { text: "Alarm vol"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 52 }
              PanelSlider { bar: root.bar; minimum: 0; maximum: 1; step: 0.05; value: root.ffSettings.alarmVolume; onMoved: function(v){ root.ff.state.settings.alarmVolume = v; root.ff.saveState() }; onReleased: function(v){ root.ff.state.settings.alarmVolume = v; root.ff.saveState(); root.ff.applyTickState() }; width: 95 }
            }
          }
        }

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
            onClicked: { root.ff.state.settings.kanbanMode = !root.ffSettings.kanbanMode; root.ff.saveState(); root.ff.applyTickState() }
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
            Text { text: "Work (" + Math.round(root.ffSettings.workSec / 60) + "m)"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 54 }
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
            Text { text: "Break (" + Math.round(root.ffSettings.shortBreakSec / 60) + "m)"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; width: 54 }
            PanelSlider {
              bar: root.bar; minimum: 1; maximum: 25; step: 1; integer: true
              value: root.ffSettings.shortBreakSec / 60
              onMoved: function(v){ root.ff.state.settings.shortBreakSec = Math.floor(v*60); if(root.ff.isStopped && root.ff.phase===Model.PHASE_SHORT_BREAK){ root.ff.state.timer.remainingSec=root.ff.state.settings.shortBreakSec; root.ff.state.timer.phaseDurationSec=root.ff.state.settings.shortBreakSec } root.ff.saveState(); root.ff.applyTickState() }
              onReleased: function(v){ root.ff.state.settings.shortBreakSec = Math.floor(v*60); if(root.ff.isStopped && root.ff.phase===Model.PHASE_SHORT_BREAK){ root.ff.state.timer.remainingSec=root.ff.state.settings.shortBreakSec; root.ff.state.timer.phaseDurationSec=root.ff.state.settings.shortBreakSec } root.ff.saveState(); root.ff.applyTickState() }
              width: 95
            }
          }
        }

        // Vault — optional Obsidian export (manual approve)
        PanelSeparator {}
        Text { text: "Vault"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
        SmallToggle {
          width: parent.width
          label: "Obsidian export"
          description: root.ffSettings.obsidianEnabled ? (root.ffSettings.obsidianVaultPath || "no path set") : "Push done tasks on approve"
          checked: root.ffSettings.obsidianEnabled === true
          onClicked: { root.ff.state.settings.obsidianEnabled = !root.ffSettings.obsidianEnabled; root.ff.saveState(); root.ff.applyTickState() }
        }
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.ffSettings.obsidianEnabled === true
          Row {
            width: parent.width
            spacing: Style.spacing.controlPaddingX
            TextField {
              width: parent.width - fileField.width - Style.spacing.controlPaddingX
              placeholderText: "Vault path e.g. ~/ObsidianVault"
              text: root.ffSettings.obsidianVaultPath || ""
              onAccepted: { root.ff.state.settings.obsidianVaultPath = text.trim().slice(0,500); root.ff.saveState(); root.ff.applyTickState() }
              onEditingFinished: { root.ff.state.settings.obsidianVaultPath = text.trim().slice(0,500); root.ff.saveState(); root.ff.applyTickState() }
            }
            TextField {
              id: fileField
              width: 110
              placeholderText: "FlowFocus.md"
              text: root.ffSettings.obsidianFile || "FlowFocus.md"
              onAccepted: { root.ff.state.settings.obsidianFile = text.trim().slice(0,100) || "FlowFocus.md"; root.ff.saveState(); root.ff.applyTickState() }
              onEditingFinished: { root.ff.state.settings.obsidianFile = text.trim().slice(0,100) || "FlowFocus.md"; root.ff.saveState(); root.ff.applyTickState() }
            }
          }
          Row {
            width: parent.width
            spacing: Style.spacing.controlPaddingX
            Button {
              text: "Push all"
              foreground: Color.accent
              enabled: (root.state.tasks.filter(function(t){return !t.pushedToObsidian || t.pushedColumn !== t.column}).length > 0) && !!root.ffSettings.obsidianVaultPath
              onClicked: root.ff.pushAllDoneToObsidian()
            }
            Text {
              text: {
                var pending = root.state.tasks.filter(function(t){return !t.pushedToObsidian || t.pushedColumn !== t.column}).length
                var total = root.state.tasks.length
                if (!root.ffSettings.obsidianVaultPath) return "set vault path"
                if (pending === 0 && total > 0) return "all pushed ✓ · " + (root.ffSettings.obsidianFile || "FlowFocus.md")
                return pending + "/" + total + " pending · " + (root.ffSettings.obsidianFile || "FlowFocus.md")
              }
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              width: parent.width - 110 - parent.spacing
            }
          }
        }

        PanelSeparator {}
      }

      // ---- Tasks section ----
      PanelSectionHeader {
        text: root.kanbanMode ? "Kanban" : "Tasks"
      }

      Text {
        visible: !root.kanbanMode
        text: "☐ done   ○ focus / ● active   → move column   ✕ delete   · Space to start/pause"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        width: parent.width
      }

      Text {
        visible: root.kanbanMode
        text: "Click card to focus (●) · Use ← → to move between Backlog → To Do → Doing → Done"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        width: parent.width
      }

      // New task input
      Row {
        width: parent.width
        spacing: Style.spacing.controlPaddingX

        TextField {
          id: taskInput
          width: parent.width - addButton.implicitWidth - Style.spacing.controlPaddingX
          placeholderText: "Add a task..."
          text: root.newTaskText
          maximumLength: 200
          onTextChanged: root.newTaskText = text.slice(0, 200)
          onAccepted: root.addTaskFromInput()
        }

        Button {
          id: addButton
          text: "+"
          foreground: Color.accent
          onClicked: root.addTaskFromInput()
        }
      }

      // Task list / kanban board
      Item {
        width: parent.width
        height: root.kanbanMode ? kanbanContainer.height : plainList.height
        implicitHeight: root.kanbanMode ? kanbanContainer.implicitHeight : plainList.implicitHeight

        // Plain list mode — vertical scroll when many tasks (cap so panel doesn't blow tall)
        ListView {
          id: plainList
          visible: !root.kanbanMode
          width: parent.width
          height: Math.min(contentHeight, Style.space(root.settingsVisible ? 220 : 320))
          interactive: true
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.state.tasks
          spacing: 4

          delegate: Rectangle {
            width: plainList.width
            height: taskRow.implicitHeight + Style.space(4)
            radius: Style.cornerRadius / 2
            color: task.done ? Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.08) : "transparent"
            border.color: Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.15)
            border.width: 0

            required property var modelData
            property var task: modelData

            Row {
              id: taskRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(2)
              anchors.rightMargin: Style.space(2)
              spacing: Style.spacing.controlPaddingX

              // Custom checkbox — avoids broken QtQuick.Controls CheckBox styling
              Rectangle {
                id: checkBox
                width: 18
                height: 18
                radius: 4
                color: task.done ? Color.accent : "transparent"
                border.color: task.done ? Color.accent : Color.muted
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
                color: task.done ? Color.muted : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.strikeout: task.done
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                width: parent.width - checkBox.width - focusBtn.width - moveBtn.width - vaultBtn.width - delBtn.width - parent.spacing * 5
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: focusBtn
                text: task.id === root.timer.activeTaskId ? "●" : "○"
                foreground: task.id === root.timer.activeTaskId ? Color.accent : Color.muted
                onClicked: root.ff.setActiveTask(task.id)
                anchors.verticalCenter: parent.verticalCenter
              }

              Button {
                id: moveBtn
                text: "→"
                foreground: Color.muted
                onClicked: root.cycleTaskColumn(task)
                anchors.verticalCenter: parent.verticalCenter
              }

              // Vault push — any column, manual approve; shows ✓ when already pushed in this column (re-push allowed after moving to Done)
              Text {
                id: vaultBtn
                visible: root.ffSettings.obsidianEnabled === true
                text: (task.pushedToObsidian && task.pushedColumn === task.column) ? "✓" : "⬆"
                color: (task.pushedToObsidian && task.pushedColumn === task.column) ? Color.muted : Color.accent
                font.pixelSize: Style.font.body
                font.bold: true
                width: visible ? 18 : 0
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -4
                  cursorShape: (task.pushedToObsidian && task.pushedColumn === task.column) ? Qt.ArrowCursor : Qt.PointingHandCursor
                  enabled: parent.visible && !(task.pushedToObsidian && task.pushedColumn === task.column)
                  onClicked: root.ff.pushTaskToObsidian(task.id)
                }
              }

              Button {
                id: delBtn
                text: "✕"
                foreground: Color.urgent
                onClicked: root.ff.deleteTask(task.id)
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // Kanban mode — horizontal scroll for columns + per-column vertical scroll for overflow (todo with many cards)
        // Outer keeps horizontal flick; vertical overflow is per-column Flickable so todo's extra cards aren't clipped.
        Flickable {
          id: kanbanContainer
          visible: root.kanbanMode
          width: parent.width
          height: Math.min(contentHeight, Style.space(root.settingsVisible ? 200 : 300))
          contentWidth: kanbanRow.implicitWidth
          contentHeight: kanbanRow.implicitHeight
          clip: true
          flickableDirection: Flickable.HorizontalFlick
          boundsBehavior: Flickable.StopAtBounds

          Row {
            id: kanbanRow
            spacing: Style.space(4)

            Repeater {
              model: Model.COLUMNS

              delegate: Column {
                required property string modelData
                property string colId: modelData

                width: 124
                spacing: Style.space(3)

                Text {
                  text: Model.COLUMN_LABELS[colId] + " (" + Model.tasksByColumn(root.state, colId).length + ")"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                // Per-column vertical scroll so todo with 20+ cards isn't invisible beyond 180px cap
                Flickable {
                  width: parent.width
                  height: Math.min(colTasks.implicitHeight, Style.space(root.settingsVisible ? 150 : 240))
                  contentHeight: colTasks.implicitHeight
                  contentWidth: width
                  clip: true
                  flickableDirection: Flickable.VerticalFlick
                  boundsBehavior: Flickable.StopAtBounds

                  Column {
                    id: colTasks
                    width: parent.width
                    spacing: 4

                    Repeater {
                      model: Model.tasksByColumn(root.state, colId)

                  delegate: Rectangle {
                    required property var modelData
                    property var task: modelData
                    width: parent.width
                    height: taskCardCol.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius
                    color: task.id === root.timer.activeTaskId ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12) : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.06)
                    border.color: task.id === root.timer.activeTaskId ? Color.accent : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                    border.width: task.id === root.timer.activeTaskId ? 1.5 : 1

                    Column {
                      id: taskCardCol
                      anchors.fill: parent
                      anchors.margins: Style.space(2)
                      spacing: 2

                      Text {
                        text: task.text
                        color: Color.popups.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.Wrap
                        width: parent.width
                      }

                      Row {
                        spacing: 4

                        Text {
                          visible: root.ffSettings.showPomodoros !== false
                          text: task.pomodorosSpent + "/" + task.pomodorosEstimated + " 🍅"
                          color: Color.muted
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }

                        Text {
                          visible: task.id === root.timer.activeTaskId
                          text: "●"
                          color: Color.accent
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Item {
                        width: parent.width
                        height: 22

                        Row {
                          id: kanbanMoveRow
                          spacing: 4
                          anchors.left: parent.left
                          anchors.verticalCenter: parent.verticalCenter

                          Button {
                            text: "←"
                            foreground: colId === "backlog" ? Color.muted : Color.accent
                            enabled: colId !== "backlog"
                            onClicked: {
                              var idx = Model.COLUMNS.indexOf(colId)
                              if (idx > 0) root.ff.moveTask(task.id, Model.COLUMNS[idx - 1])
                            }
                          }

                          Button {
                            text: "→"
                            foreground: colId === "done" ? Color.muted : Color.accent
                            enabled: colId !== "done"
                            onClicked: {
                              var idx = Model.COLUMNS.indexOf(colId)
                              if (idx < Model.COLUMNS.length - 1) root.ff.moveTask(task.id, Model.COLUMNS[idx + 1])
                            }
                          }
                        }

                        // Vault push — any column, manual approve; shows ✓ when already pushed in this column (re-push allowed after moving to Done)
                        Text {
                          visible: root.ffSettings.obsidianEnabled === true
                          text: (task.pushedToObsidian && task.pushedColumn === task.column) ? "✓" : "⬆"
                          color: (task.pushedToObsidian && task.pushedColumn === task.column) ? Color.muted : Color.accent
                          font.pixelSize: Style.font.body
                          font.bold: true
                          anchors.right: parent.right
                          anchors.rightMargin: 18
                          anchors.verticalCenter: parent.verticalCenter
                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: (task.pushedToObsidian && task.pushedColumn === task.column) ? Qt.ArrowCursor : Qt.PointingHandCursor
                            enabled: parent.visible && !(task.pushedToObsidian && task.pushedColumn === task.column)
                            onClicked: root.ff.pushTaskToObsidian(task.id)
                          }
                        }
                        // X = delete task (kanban) — anchored right, not overflowing
                        Text {
                          text: "✕"
                          color: Color.urgent
                          font.pixelSize: Style.font.body
                          anchors.right: parent.right
                          anchors.rightMargin: 2
                          anchors.verticalCenter: parent.verticalCenter

                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.ff.deleteTask(task.id)
                          }
                        }
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

  // ---- Helpers ----
  function addTaskFromInput() {
    var text = root.newTaskText.trim()
    if (!text) return
    root.ff.addTask(text, "todo")
    root.newTaskText = ""
    taskInput.text = ""
  }

  function cycleTaskColumn(task) {
    var cols = Model.COLUMNS
    var idx = cols.indexOf(task.column)
    var next = cols[(idx + 1) % cols.length]
    root.ff.moveTask(task.id, next)
  }
  function switchPanel(direction) {
    root.ff.state.settings.kanbanMode = !root.ffSettings.kanbanMode
    root.ff.saveState()
    root.ff.applyTickState()
  }
}
