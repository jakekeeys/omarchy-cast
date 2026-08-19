import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cast the desktop (with audio) to a Google Cast device.
//
// Clicking a device row SELECTS it as the target; the hero toggle is the one
// control that starts/stops casting to the selected target. Left click on the
// bar icon opens the panel, right click quick-toggles the cast, middle click
// rescans. "Cast area…" picks a window/region/monitor with the same picker
// the built-in screen recorder uses.
//
// Backed by cast-backend in this folder: gpu-screen-recorder → HLS → catt.
// The firewall rule for the stream port is added when the widget first loads
// (pkexec, once) and removed when the plugin is disabled or removed from the
// bar layout.

Panel {
  id: root
  moduleName: "jakekeeys.cast"
  ipcTarget: "jakekeeys.cast"
  manageIpc: false

  property bool casting: false
  property string castDevice: ""
  property double castSince: 0
  property string castTarget: ""
  property bool scanning: false
  property bool starting: false
  property bool stopping: false
  property var devices: []
  property string lastError: ""
  property int elapsedSeconds: 0
  property bool cursorActive: false
  property int deviceIndex: 0

  // resolve the backend relative to this QML file so the plugin works from
  // wherever it is installed
  readonly property string backend: String(Qt.resolvedUrl("cast-backend")).replace(/^file:\/\//, "")
  readonly property string selectedDeviceName: String(setting("lastDevice", ""))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: casting ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property bool busy: starting || stopping
  readonly property bool canCast: selectedDeviceName !== "" || casting
  readonly property string targetLabel: castTarget.indexOf("monitor:") === 0
    ? castTarget.substring(8)
    : (castTarget !== "" ? "area" : "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function formatDuration(totalSeconds) {
    var h = Math.floor(totalSeconds / 3600)
    var m = Math.floor((totalSeconds % 3600) / 60)
    var s = totalSeconds % 60
    var mm = m < 10 ? "0" + m : String(m)
    var ss = s < 10 ? "0" + s : String(s)
    return (h > 0 ? h + ":" + mm : String(m)) + ":" + ss
  }

  function persistSelectedDevice(name) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.lastDevice = String(name || "")
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function backendOpts() {
    return [
      "--fps", String(setting("fps", 30)),
      "--resolution", String(setting("resolution", "1920x1080")),
      "--bitrate", String(setting("bitrate", 8000)),
      "--port", String(setting("port", 8089))
    ]
  }

  function startScan() {
    if (scanning) return
    scanning = true
    lastError = ""
    scanProcess.command = [backend, "scan"]
    scanProcess.running = true
  }

  function refreshStatus() {
    if (statusProcess.running) return
    statusProcess.command = [backend, "status"]
    statusProcess.running = true
  }

  function startCast(pick) {
    var device = selectedDeviceName
    if (device === "" || starting) return
    starting = true
    lastError = ""
    var cmd = [backend, "start", device].concat(backendOpts())
    if (pick === true) {
      cmd.push("--pick")
      close()
    }
    startProcess.command = cmd
    startProcess.running = true
  }

  function stopCast() {
    if (stopping) return
    stopping = true
    stopProcess.command = [backend, "stop"]
    stopProcess.running = true
  }

  function toggleCast() {
    if (busy) return
    if (casting) stopCast()
    else startCast(false)
  }

  function selectDevice(device) {
    if (!device) return
    persistSelectedDevice(device.name)
  }

  function cursorDevice() {
    if (devices.length === 0) return null
    return devices[Math.max(0, Math.min(deviceIndex, devices.length - 1))]
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (devices.length === 0) return
    if (dy > 0) deviceIndex = Math.min(devices.length - 1, deviceIndex + 1)
    else if (dy < 0) deviceIndex = Math.max(0, deviceIndex - 1)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Firewall lifecycle: rule appears when the enabled widget first loads…
  Component.onCompleted: {
    firewallProcess.command = [backend, "ensure-firewall", "--port", String(setting("port", 8089))]
    firewallProcess.running = true
  }

  // …and goes away when the plugin leaves the bar layout. On shell restarts
  // and code reloads the plugin is still in the layout, so this is a no-op.
  Component.onDestruction: {
    Quickshell.execDetached([backend, "teardown-if-disabled"])
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    refreshStatus()
    if (devices.length === 0) startScan()
  }

  Timer {
    interval: 1000
    running: root.casting
    repeat: true
    triggeredOnStart: true
    onTriggered: root.elapsedSeconds = Math.max(0, Math.floor(Date.now() / 1000 - root.castSince))
  }

  Timer {
    // catch pipeline death or external stops
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Process {
    id: firewallProcess
    running: false
    command: []
    stderr: StdioCollector { id: firewallStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var err = String(firewallStderr.text || "").trim()
        root.lastError = err !== "" ? err : "Firewall setup failed — casting may not reach the TV"
      }
    }
  }

  Process {
    id: scanProcess
    running: false
    command: []
    stdout: StdioCollector { id: scanStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.scanning = false
      if (exitCode !== 0) {
        root.lastError = "Scan failed — is catt installed?"
        return
      }
      try {
        var parsed = JSON.parse(String(scanStdout.text || "[]"))
        root.devices = parsed
        if (root.deviceIndex >= parsed.length) root.deviceIndex = Math.max(0, parsed.length - 1)
      } catch (e) {
        root.lastError = "Could not parse scan results"
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var s = JSON.parse(String(statusStdout.text || "{}"))
        root.casting = s.casting === true
        root.castDevice = String(s.device || "")
        root.castSince = Number(s.since || 0)
        root.castTarget = String(s.target || "")
      } catch (e) {}
    }
  }

  Process {
    id: startProcess
    running: false
    command: []
    stderr: StdioCollector { id: startStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.starting = false
      if (exitCode === 0) {
        root.lastError = ""
      } else {
        var err = String(startStderr.text || "").trim()
        if (err !== "cancelled") root.lastError = err !== "" ? err : "Failed to start casting"
      }
      root.refreshStatus()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.stopping = false
      root.refreshStatus()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(device: string): string {
      root.persistSelectedDevice(device)
      root.startCast(false)
      return "ok"
    }
    function stop(): string { root.stopCast(); return "ok" }
    function status(): string { return root.casting ? "casting to " + root.castDevice : "idle" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          // md-cast / md-cast-connected
          text: root.casting ? "󰄙" : "󰄘"
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.space(11)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleCast()
      else if (buttonCode === Qt.MiddleButton) root.startScan()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.selectDevice(root.cursorDevice())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.startScan()
        else if (t === "t" || t === "T") root.toggleCast()
        else if (t === "a" || t === "A") { if (!root.busy && root.selectedDeviceName !== "") root.startCast(true) }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: root.casting
            ? root.castDevice
            : (root.selectedDeviceName !== "" ? root.selectedDeviceName : "Cast")
          meta: root.casting
            ? "Casting " + (root.targetLabel !== "" ? root.targetLabel + " · " : "") + root.formatDuration(root.elapsedSeconds)
            : (root.starting
                ? "Starting…"
                : (root.selectedDeviceName !== "" ? "Ready to cast" : "Select a device below"))
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.casting ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: root.casting ? "󰄙" : "󰄘"
              color: root.casting ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          // The one control that starts/stops the cast to the selected target.
          trailingControl: Component {
            ToggleSwitch {
              id: castSwitch
              visible: root.canCast
              checked: root.casting
              busy: root.busy
              foreground: hero.foreground
              onToggled: root.toggleCast()

              PanelToolTip {
                visible: castSwitch.containsMouse
                text: root.casting ? "Stop casting" : "Cast to " + root.selectedDeviceName
                fontFamily: hero.fontFamily
              }
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Cast a picked window / region / monitor instead of the focused screen
        CursorSurface {
          id: areaRow
          visible: root.selectedDeviceName !== "" && !root.busy
          width: parent.width
          foreground: root.foreground
          fill: root.hoverFill
          implicitHeight: areaInner.implicitHeight + Style.spacing.xl

          Row {
            id: areaInner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(8)

            Text {
              text: "󰩭" // md-select-drag
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: Style.space(22)
              horizontalAlignment: Text.AlignHCenter
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.casting ? "Recast an area or window…" : "Cast an area or window…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            id: areaMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.startCast(true)
          }

          PanelToolTip {
            visible: areaMouse.containsMouse
            text: "Pick a window, region, or monitor to cast to " + root.selectedDeviceName
            fontFamily: root.fontFamily
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          RowLayout {
            width: parent.width

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "DEVICES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PanelActionButton {
              iconText: "󰑐" // md-refresh
              tooltipText: root.scanning ? "Scanning…" : "Rescan"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.scanning
              onClicked: root.startScan()

              NumberAnimation on rotation {
                running: root.scanning
                from: 0; to: 360
                duration: 900
                loops: Animation.Infinite
              }
              onRotationChanged: if (!root.scanning && rotation !== 0) rotation = 0
            }
          }

          Text {
            visible: root.scanning && root.devices.length === 0
            width: parent.width
            text: "Scanning for Google Cast devices…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: !root.scanning && root.devices.length === 0
            width: parent.width
            text: "No Google Cast devices found on this network."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: deviceColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.devices
              DeviceRow {
                required property var modelData
                required property int index
                width: deviceColumn.width
                device: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  component DeviceRow: CursorSurface {
    id: deviceRow
    property var device: null
    property int rowIndex: 0
    readonly property string deviceName: device ? String(device.name || "Unknown") : "Unknown"
    readonly property string deviceModel: device ? String(device.model || "") : ""
    readonly property bool isSelected: root.selectedDeviceName === deviceName
    readonly property bool isCastingTo: root.casting && root.castDevice === deviceName

    hasCursor: root.cursorActive && root.deviceIndex === rowIndex
    current: isSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: deviceInner.implicitHeight + Style.spacing.xl

    Row {
      id: deviceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: deviceRow.isCastingTo ? "󰄙" : "󰔂" // cast-connected / television
        color: deviceRow.isSelected || deviceRow.isCastingTo ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(30)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: deviceRow.deviceName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: deviceRow.isSelected
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: deviceRow.isCastingTo ? deviceRow.deviceModel + " · casting" : deviceRow.deviceModel
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: deviceMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.deviceIndex = deviceRow.rowIndex }
      onClicked: root.selectDevice(deviceRow.device)
    }

    PanelToolTip {
      visible: deviceMouse.containsMouse && !deviceRow.isSelected
      text: "Select " + deviceRow.deviceName
      fontFamily: root.fontFamily
    }
  }
}
