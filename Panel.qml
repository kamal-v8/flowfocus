import QtQuick
import QtQuick.Controls
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
      spacing: Style.spacing.controlPaddingY

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

      // ---- Settings section (collapsible) ----
      Column {
        width: parent.width
        spacing: Style.spacing.controlPaddingY
        visible: root.settingsVisible

        PanelSectionHeader {
          text: "Settings"
        }

        Toggle {
          label: "Tick sound"
          description: "Play a soft tick every second while running"
          checked: root.ffSettings.tickEnabled
          onClicked: {
            root.ff.state.settings.tickEnabled = !root.ffSettings.tickEnabled
            root.ff.saveState()
            root.ff.applyTickState()
          }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.controlPaddingX
          visible: root.ffSettings.tickEnabled

          Text {
            text: "Volume"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Slider {
            id: volumeSlider
            from: 0
            to: 1
            value: root.ffSettings.tickVolume
            onMoved: {
              root.ff.state.settings.tickVolume = value
              root.ff.saveState()
            }
            width: 140
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Toggle {
          label: "Kanban board"
          description: "Show tasks as columns (Backlog / To Do / Doing / Done)"
          checked: root.kanbanMode
          onClicked: {
            root.ff.state.settings.kanbanMode = !root.ffSettings.kanbanMode
            root.ff.saveState()
            root.ff.applyTickState()
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

        // Plain list mode
        ListView {
          id: plainList
          visible: !root.kanbanMode
          width: parent.width
          height: contentHeight
          interactive: false
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
                width: parent.width - checkBox.width - focusBtn.width - moveBtn.width - delBtn.width - parent.spacing * 4
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

        // Kanban mode — wider columns, breathing room, horizontal scroll
        Flickable {
          id: kanbanContainer
          visible: root.kanbanMode
          width: parent.width
          height: Math.min(contentHeight, Style.space(280))
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
                  text: Model.COLUMN_LABELS[colId]
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

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
}
