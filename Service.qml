import QtQuick
import Quickshell
import Quickshell.Io

// Process-wide status for the ScreenMirror user service. The capture itself
// stays in systemd; this object only asks the screenmirror command.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property bool screenmirrorService: true
  property string streamState: "stopped"
  property string url: ""
  property string detail: ""
  property bool previewOn: false
  property int generation: 0
  property int probeGeneration: 0
  property int consumedGeneration: -1
  property bool refreshQueued: false
  property string queuedAction: ""

  function refresh() {
    if (probe.running) {
      refreshQueued = true
      return
    }
    generation += 1
    probeGeneration = generation
    probe.running = true
  }

  function consume(text, gen) {
    if (gen !== probeGeneration || gen === consumedGeneration)
      return
    consumedGeneration = gen
    var trimmed = String(text || "").trim()
    if (trimmed === "") {
      streamState = "missing"
      url = ""
      detail = "screencast is not installed. Run install.sh from the plugin directory."
      previewOn = false
      return
    }
    var data = null
    try {
      data = JSON.parse(trimmed)
    } catch (e) {
      data = null
    }
    if (!data || typeof data.state !== "string") {
      streamState = "failed"
      detail = trimmed.substring(0, 160)
      previewOn = false
      return
    }
    var next = data.state
    if (next !== "missing" && next !== "stopped" && next !== "starting" && next !== "live" && next !== "failed")
      next = "failed"
    streamState = next
    url = String(data.url || "")
    detail = String(data.detail || "").substring(0, 160)
    previewOn = data.preview === true
  }

  function runAction(name) {
    if (name !== "start" && name !== "stop" && name !== "copy")
      return
    if (action.running) {
      queuedAction = name
      return
    }
    action.command = ["screencast", name]
    action.running = true
  }

  function start() { runAction("start") }
  function stop() { runAction("stop") }
  function copy() { runAction("copy") }

  Process {
    id: probe
    command: ["screencast", "status", "--json"]
    stdout: StdioCollector {
      id: probeOut
      waitForEnd: true
      onStreamFinished: root.consume(text, root.probeGeneration)
    }
    onExited: function(exitCode) {
      root.consume(probeOut.text, root.probeGeneration)
      if (root.refreshQueued) {
        root.refreshQueued = false
        root.refresh()
      }
    }
  }

  Process {
    id: action
    command: ["screencast", "status", "--json"]
    onExited: function(exitCode) {
      if (root.queuedAction !== "") {
        var next = root.queuedAction
        root.queuedAction = ""
        root.runAction(next)
        return
      }
      root.refresh()
    }
  }

  Timer {
    interval: root.streamState === "missing" ? 15000
            : (root.streamState === "live" || root.streamState === "starting" ? 2000 : 5000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "fpaulcris.screenmirror"

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        state: root.streamState,
        url: root.url,
        detail: root.detail,
        preview: root.previewOn
      })
    }

    function start(): string {
      root.start()
      return "ok"
    }

    function stop(): string {
      root.stop()
      return "ok"
    }

    function copy(): string {
      root.copy()
      return "ok"
    }
  }
}
