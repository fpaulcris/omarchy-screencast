import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "fpaulcris.screenmirror"

  property var mirror: null
  property string localState: "stopped"
  property string localUrl: ""
  property string localDetail: ""
  property bool localPreview: false
  property int localGeneration: 0
  property int localProbeGeneration: 0
  property int localConsumedGeneration: -1
  property bool localRefreshQueued: false

  readonly property bool hosted: mirror && mirror.screenmirrorService === true
  readonly property string viewState: hosted ? mirror.streamState : localState
  readonly property string viewUrl: hosted ? mirror.url : localUrl
  readonly property string viewDetail: hosted ? mirror.detail : localDetail
  readonly property bool previewOn: hosted ? mirror.previewOn === true : localPreview

  readonly property string glyph: {
    if (viewState === "live")
      return String.fromCodePoint(0xF0119)
    if (viewState === "failed")
      return String.fromCodePoint(0xF078A)
    return String.fromCodePoint(0xF0118)
  }

  function lookupService() {
    var host = root.bar
    if (!host || !host.shell || typeof host.shell.serviceFor !== "function")
      return null
    var found = host.shell.serviceFor(root.moduleName)
    if (found && found.screenmirrorService === true)
      return found
    return null
  }

  function consumeLocal(text, gen) {
    if (gen !== localProbeGeneration || gen === localConsumedGeneration)
      return
    localConsumedGeneration = gen
    var trimmed = String(text || "").trim()
    if (trimmed === "") {
      localState = "missing"
      localUrl = ""
      localDetail = "screencast is not installed. Run install.sh from the plugin directory."
      localPreview = false
      return
    }
    var data = null
    try {
      data = JSON.parse(trimmed)
    } catch (e) {
      data = null
    }
    if (!data || typeof data.state !== "string") {
      localState = "failed"
      localDetail = trimmed.substring(0, 160)
      localPreview = false
      return
    }
    var next = data.state
    if (next !== "missing" && next !== "stopped" && next !== "starting" && next !== "live" && next !== "failed")
      next = "failed"
    localState = next
    localUrl = String(data.url || "")
    localDetail = String(data.detail || "").substring(0, 160)
    localPreview = data.preview === true
  }

  function refreshLocal() {
    if (hosted)
      return
    if (localProbe.running) {
      localRefreshQueued = true
      return
    }
    localGeneration += 1
    localProbeGeneration = localGeneration
    localProbe.running = true
  }

  function doStart() {
    if (hosted && mirror.start) {
      mirror.start()
      return
    }
    if (!localAction.running)
      localAction.command = ["screencast", "start"]
    if (!localAction.running)
      localAction.running = true
  }

  function doStop() {
    if (hosted && mirror.stop) {
      mirror.stop()
      return
    }
    if (!localAction.running)
      localAction.command = ["screencast", "stop"]
    if (!localAction.running)
      localAction.running = true
  }

  function doCopy() {
    if (hosted && mirror.copy) {
      mirror.copy()
      return
    }
    if (!localAction.running)
      localAction.command = ["screencast", "copy"]
    if (!localAction.running)
      localAction.running = true
  }

  function doRefresh() {
    if (hosted && mirror.refresh)
      mirror.refresh()
    else
      refreshLocal()
  }

  function toggleStream() {
    if (viewState === "live" || viewState === "starting")
      doStop()
    else if (viewState !== "missing")
      doStart()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target)
      return
    if ("bar" in target)
      target.bar = root.bar
    if ("settings" in target)
      target.settings = root.settings
    if ("anchorItem" in target)
      target.anchorItem = button
    if ("hostWidget" in target)
      target.hostWidget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open)
      panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close)
      panelLoader.item.close()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
  }

  function togglePanel() {
    if (opened)
      close()
    else
      open()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    mirror = lookupService()
    injectPanel()
  }
  onSettingsChanged: injectPanel()

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var next = root.lookupService()
      if (next !== root.mirror)
        root.mirror = next
    }
  }

  Timer {
    interval: root.localState === "missing" ? 15000
            : (root.localState === "live" || root.localState === "starting" ? 2000 : 5000)
    running: !root.hosted
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLocal()
  }

  Process {
    id: localProbe
    command: ["screencast", "status", "--json"]
    stdout: StdioCollector {
      id: localOut
      waitForEnd: true
      onStreamFinished: root.consumeLocal(text, root.localProbeGeneration)
    }
    onExited: function(exitCode) {
      root.consumeLocal(localOut.text, root.localProbeGeneration)
      if (root.localRefreshQueued) {
        root.localRefreshQueued = false
        root.refreshLocal()
      }
    }
  }

  Process {
    id: localAction
    command: ["screencast", "status", "--json"]
    onExited: function(exitCode) {
      root.refreshLocal()
    }
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    iconComponent: trayIcon
    tooltipText: "Screen Cast (" + root.viewState + "). Left click opens the panel. Right click starts or stops. Middle click refreshes."

    Component {
      id: trayIcon
      CastIcon {
        anchors.fill: parent
        // The mark is painted above the button's mouse area. Keep it out of
        // hit testing so a left click reaches the button and opens the panel.
        enabled: false
        on: root.viewState === "live" || root.viewState === "starting"
        tint: button.foreground
      }
    }

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton)
        root.toggleStream()
      else if (mouseButton === Qt.MiddleButton)
        root.doRefresh()
      else
        root.togglePanel()
    }
  }
}
