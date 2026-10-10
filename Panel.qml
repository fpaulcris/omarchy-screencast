import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "fpaulcris.screenmirror"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string viewState: hostWidget ? hostWidget.viewState : "stopped"
  readonly property string viewUrl: hostWidget ? hostWidget.viewUrl : ""
  readonly property string viewDetail: hostWidget ? hostWidget.viewDetail : ""
  readonly property bool previewFromHost: hostWidget ? hostWidget.previewOn === true : false
  onPreviewFromHostChanged: applyHostPreview()
  readonly property bool canStart: viewState === "stopped" || viewState === "failed"
  readonly property bool canStop: viewState === "live" || viewState === "starting"
  readonly property bool canCopy: viewUrl !== ""
  readonly property color ink: bar ? bar.barForeground : Color.foreground

  property string mode: "browser"
  property string workspaceChoice: ""
  property string sizeChoice: "auto"
  property var desktopOptions: []
  property var queuedCast: []
  property string qrSource: ""
  property string qrMessage: ""
  property var receivers: []
  property string receiverChoice: ""
  property var mirrorSessions: []
  property var mirrorQueue: []
  property bool mirrorPollQueued: false
  property bool scanning: false
  property bool scanQueued: false
  property string scanError: ""
  property bool showingInfo: false
  property bool previewOn: false
  property bool previewHold: false
  property bool previewWant: false
  property bool previewQueued: false
  property bool qrRequested: false
  property bool qrJustClosed: false
  property bool qrOpenAtPress: false

  readonly property string refreshGlyph: String.fromCodePoint(0xF0450)
  readonly property string infoGlyph: String.fromCodePoint(0xF02FD)
  readonly property string toggleOnGlyph: String.fromCodePoint(0xF0521)
  readonly property string toggleOffGlyph: String.fromCodePoint(0xF0522)
  readonly property var resolutionOptions: [
    { value: "auto", label: "Auto" },
    { value: "1280x720", label: "1280×720" },
    { value: "1920x1080", label: "1920×1080" },
    { value: "2560x1440", label: "2560×1440" },
    { value: "3840x2160", label: "3840×2160" }
  ]
  readonly property var chosenReceiver: {
    for (var i = 0; i < receivers.length; i++) {
      if (receivers[i] && receivers[i].id === receiverChoice)
        return receivers[i]
    }
    return null
  }
  readonly property string headerMeta: {
    if (viewState === "live")
      return "Casting"
    if (viewState === "starting")
      return "Starting"
    if (viewState === "failed")
      return "Failed"
    if (viewState === "missing")
      return "Not installed"
    return "Stopped"
  }
  function refreshChoices() {
    if (!desktopProc.running)
      desktopProc.running = true
    if (!castReadProc.running)
      castReadProc.running = true
  }

  function applyHostPreview() {
    if (previewHold && previewFromHost !== previewWant)
      return
    previewHold = false
    previewOn = previewFromHost
  }

  function setPreview(want) {
    previewWant = want
    previewHold = true
    previewOn = want
    if (previewProc.running) {
      previewQueued = true
      return
    }
    previewProc.command = ["screencast", "preview", want ? "on" : "off"]
    previewProc.running = true
  }

  function saveCast(args) {
    if (castWriteProc.running) {
      queuedCast = args
      return
    }
    castWriteProc.command = ["screencast"].concat(args)
    castWriteProc.running = true
  }

  function showQr() {
    if (qrSource !== "") {
      qrPopup.open()
      return
    }
    qrRequested = true
    if (!qrProc.running)
      qrProc.running = true
  }

  function scanReceivers() {
    if (scanProc.running) {
      scanQueued = true
      return
    }
    scanning = true
    scanProc.running = true
  }

  function chooseReceivers() {
    mode = "receivers"
    scanReceivers()
    pollMirror()
  }

  function pollMirror() {
    if (mirrorStatusProc.running) {
      mirrorPollQueued = true
      return
    }
    mirrorStatusProc.running = true
  }

  function sessionFor(id) {
    for (var i = 0; i < mirrorSessions.length; i++) {
      var item = mirrorSessions[i]
      if (item && item.id === id)
        return item
    }
    return null
  }

  function sessionOn(id) {
    var item = sessionFor(id)
    return !!item && (item.state === "live" || item.state === "starting")
  }

  function setSession(id, state, detail) {
    var next = []
    var found = false
    for (var i = 0; i < mirrorSessions.length; i++) {
      var item = mirrorSessions[i]
      if (!item)
        continue
      if (item.id === id) {
        found = true
        if (state === "stopped")
          continue
        next.push({
          id: id,
          name: item.name || "",
          state: state,
          detail: detail || "",
          url: item.url || ""
        })
      } else {
        next.push(item)
      }
    }
    if (!found && state !== "stopped") {
      next.push({
        id: id,
        name: "",
        state: state,
        detail: detail || "",
        url: ""
      })
    }
    mirrorSessions = next
  }

  function runMirror(args) {
    var queued = mirrorQueue.slice()
    queued.push(args)
    mirrorQueue = queued
    pumpMirror()
  }

  function pumpMirror() {
    if (mirrorCmdProc.running || mirrorQueue.length === 0)
      return
    var args = mirrorQueue[0]
    mirrorQueue = mirrorQueue.slice(1)
    mirrorCmdProc.command = ["screencast"].concat(args)
    mirrorCmdProc.running = true
  }

  function toggleDevice(device) {
    if (!device || device.canMirror !== true || !device.id)
      return
    if (sessionOn(device.id)) {
      setSession(device.id, "stopped", "")
      runMirror(["mirror", "stop", device.id])
    } else {
      setSession(device.id, "starting", "Connecting.")
      runMirror(["mirror", device.id])
    }
  }

  function extraProtocols(device) {
    if (!device || !device.protocols)
      return ""
    var extra = []
    for (var i = 0; i < device.protocols.length; i++) {
      var item = device.protocols[i]
      if (item && item.name && item.name !== device.protocol)
        extra.push(item.name)
    }
    return extra.length === 0 ? "" : "Also " + extra.join(", ")
  }

  function deviceDetail(device) {
    if (!device)
      return ""
    var lines = []
    var proto = device.protocol || ""
    var model = device.model || ""
    var headline = ""
    if (proto !== "" && model !== "")
      headline = proto + " · " + model
    else
      headline = proto || model || (device.address || "")
    if (headline !== "")
      lines.push(headline)
    var extra = extraProtocols(device)
    if (extra !== "")
      lines.push(extra)
    var note = device.note || ""
    if (note !== "")
      lines.push(note)
    return lines.join("\n")
  }

  function refreshAll() {
    if (hostWidget && hostWidget.doRefresh)
      hostWidget.doRefresh()
    refreshChoices()
    if (mode === "receivers")
      scanReceivers()
  }

  onOpenedChanged: {
    if (!root.opened)
      return
    refreshChoices()
    if (root.mode === "receivers")
      scanReceivers()
  }
  Component.onCompleted: {
    applyHostPreview()
    refreshChoices()
  }

  readonly property string stateLabel: {
    if (viewState === "missing")
      return "Not installed"
    if (viewState === "starting")
      return "Starting"
    if (viewState === "live")
      return "Live"
    if (viewState === "failed")
      return "Failed"
    return "Stopped"
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root.barIdentity, direction)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          foreground: root.ink
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          title: "Screen Cast"
          meta: root.headerMeta
          iconComponent: screenCastMark
          trailingControl: headerTools
        }

        Component {
          id: screenCastMark
          CastIcon {
            width: Style.space(32)
            height: Style.space(32)
            on: root.viewState === "live" || root.viewState === "starting"
            tint: root.ink
          }
        }

        Component {
          id: headerTools
          Row {
            spacing: Style.space(8)

            Button {
              bordered: false
              focusable: true
              foreground: root.ink
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              iconText: root.refreshGlyph
              iconSpinning: root.scanning
              tooltipText: "Refresh"
              onClicked: root.refreshAll()
            }

            ToggleSwitch {
              checked: root.canStop
              busy: root.viewState === "starting"
              foreground: root.ink
              enabled: root.viewState !== "missing"
              onToggled: if (root.hostWidget && root.hostWidget.toggleStream) root.hostWidget.toggleStream()
            }
          }
        }

        Flickable {
          id: infoPage
          visible: root.showingInfo
          width: parent.width
          height: visible ? Math.min(infoBody.implicitHeight, Style.space(360)) : 0
          contentWidth: width
          contentHeight: infoBody.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: infoBody
            width: infoPage.width
            spacing: Style.space(8)

            Button {
              bordered: true
              focusable: true
              foreground: root.ink
              text: "Back"
              onClicked: root.showingInfo = false
            }
            Text {
              width: parent.width
              text: "Find Devices"
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              width: parent.width
              text: "Chromecast, AirPlay, and a Miracast receiver on this Wi-Fi each have a switch. The switch sends this screen, and several can be on at once. The switch at the top stops the stream and every screen. A Fire TV switch sends this desktop to that TV's player. If the player refuses, the row says why. screencast dial lists those apps and can launch one, for example YouTube. Android TV Remote sends keys after pairing. A Miracast TV that only uses Wi-Fi Direct stays off this list."
              wrapMode: Text.WordWrap
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              topPadding: Style.space(14)
              text: "Browser"
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              width: parent.width
              text: "Open the address in a browser on your TV or phone, connected to the same Wi-Fi. This option is not listed in the TV's cast menu."
              wrapMode: Text.WordWrap
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              leftPadding: Style.space(12)
              topPadding: Style.space(10)
              text: "Desktop"
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              width: parent.width
              leftPadding: Style.space(12)
              text: "Follow Screen shares your current desktop. Choose a desktop number to use as an extended display."
              wrapMode: Text.WordWrap
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              leftPadding: Style.space(12)
              topPadding: Style.space(10)
              text: "Resolution"
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              width: parent.width
              leftPadding: Style.space(12)
              text: "Auto matches the resolution of the device casting the screen. A fixed resolution applies when the selected desktop is on its own screen."
              wrapMode: Text.WordWrap
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              leftPadding: Style.space(12)
              topPadding: Style.space(10)
              text: "Frame rate and delay"
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              width: parent.width
              leftPadding: Style.space(12)
              text: "The switch shows frames per second on the picture, and how many milliseconds of picture are still waiting. The same control sits in the corner of the picture."
              wrapMode: Text.WordWrap
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }

        Row {
          visible: !root.showingInfo
          spacing: Style.space(8)

          Button {
            bordered: true
            focusable: true
            foreground: root.ink
            text: "Find Devices"
            selected: root.mode === "receivers"
            onClicked: root.chooseReceivers()
          }

          Button {
            bordered: true
            focusable: true
            foreground: root.ink
            text: "Browser"
            selected: root.mode === "browser"
            onClicked: root.mode = "browser"
          }
        }

        Rectangle {
          visible: !root.showingInfo && root.mode === "receivers"
          width: parent.width
          implicitHeight: deviceColumn.implicitHeight
          radius: Style.cornerRadius
          color: "transparent"
          border.color: Color.popups.border
          border.width: Math.max(1, Style.space(1))
          clip: true

          Column {
            id: deviceColumn
            width: parent.width

            Text {
              width: parent.width
              leftPadding: Style.space(12)
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
              visible: root.scanning
              text: "Looking for devices"
              color: root.ink
              opacity: 0.8
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              leftPadding: Style.space(12)
              rightPadding: Style.space(12)
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
              visible: root.scanError !== ""
              text: root.scanError
              wrapMode: Text.WordWrap
              color: root.ink
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              leftPadding: Style.space(12)
              rightPadding: Style.space(12)
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
              visible: !root.scanning && root.scanError === "" && root.receivers.length === 0
              text: "No receivers answered."
              wrapMode: Text.WordWrap
              color: root.ink
              opacity: 0.8
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.receivers
              delegate: Rectangle {
                required property var modelData
                readonly property var session: root.sessionFor(modelData.id)
                readonly property bool casting: session && (session.state === "live" || session.state === "starting")
                readonly property bool failed: session && session.state === "failed" && String(session.detail || "") !== ""
                readonly property bool chosen: root.receiverChoice === modelData.id
                property bool infoHot: false
                width: deviceColumn.width
                height: deviceBody.implicitHeight + Style.space(16)
                color: casting || chosen ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12) : "transparent"

                Text {
                  id: infoMeasure
                  visible: false
                  textFormat: Text.PlainText
                  text: root.deviceDetail(modelData)
                  font.family: infoTip.fontFamily
                  font.pixelSize: infoTip.fontSize
                  wrapMode: Text.NoWrap
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.receiverChoice = modelData.id
                }

                Column {
                  id: deviceBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(4)

                RowLayout {
                  id: deviceRow
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    Layout.fillWidth: true
                    text: modelData.name
                    color: root.ink
                    elide: Text.ElideRight
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    visible: casting
                    text: session && session.state === "starting" ? "Connecting" : "Mirroring"
                    color: root.ink
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }

                  ToggleSwitch {
                    visible: modelData.canMirror === true
                    checked: casting
                    interactive: modelData.canMirror === true
                    foreground: root.ink
                    Layout.alignment: Qt.AlignVCenter
                    onToggled: root.toggleDevice(modelData)
                  }

                  PanelActionButton {
                    id: deviceInfoButton
                    visible: root.deviceDetail(modelData) !== ""
                    iconText: root.infoGlyph
                    foreground: root.ink
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    Layout.alignment: Qt.AlignVCenter
                    onHovered: function(isHovered) { infoHot = isHovered }

                    PanelToolTip {
                      id: infoTip
                      visible: infoHot && text !== ""
                      text: root.deviceDetail(modelData)
                      fontFamily: deviceInfoButton.fontFamily
                      readonly property real textLimit: Style.space(280)
                      readonly property real padL: Border.left(panelBorderSpec) + Style.spacing.controlPaddingX
                      readonly property real padR: Border.right(panelBorderSpec) + Style.spacing.controlPaddingX
                      readonly property real bodyWidth: Math.min(infoMeasure.implicitWidth, textLimit)
                      width: bodyWidth + padL + padR
                      x: parent ? parent.width - width : 0

                      contentItem: Text {
                        textFormat: Text.PlainText
                        text: infoTip.text
                        color: infoTip.panelForeground
                        font.family: infoTip.fontFamily
                        font.pixelSize: infoTip.fontSize
                        wrapMode: Text.WordWrap
                        width: infoTip.width
                        leftPadding: infoTip.padL
                        rightPadding: infoTip.padR
                        topPadding: Border.top(infoTip.panelBorderSpec) + Style.spacing.controlPaddingY
                        bottomPadding: Border.bottom(infoTip.panelBorderSpec) + Style.spacing.controlPaddingY
                      }
                    }
                  }
                }

                  Text {
                    width: parent.width
                    visible: failed
                    text: session ? String(session.detail || "") : ""
                    wrapMode: Text.WordWrap
                    color: root.ink
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }
        }

        Column {
          width: parent.width
          visible: !root.showingInfo && root.mode === "browser"
          spacing: Style.spacing.labelGap

          // The shared Dropdown paints its label at caption size. These
          // names sit with the field value and the buttons, so they use body.
          Text {
            text: "Desktop"
            color: root.ink
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Dropdown {
            width: parent.width
            showLabel: false
            value: root.workspaceChoice
            options: root.desktopOptions
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(value) {
              root.workspaceChoice = value
              root.saveCast(["cast", "--workspace", value])
            }
          }
        }

        Column {
          width: parent.width
          visible: !root.showingInfo && root.mode === "browser"
          spacing: Style.spacing.labelGap

          Text {
            text: "Resolution"
            color: root.ink
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Dropdown {
            width: parent.width
            showLabel: false
            value: root.sizeChoice
            options: root.resolutionOptions
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function(value) {
              root.sizeChoice = value
              root.saveCast(["cast", "--size", value])
            }
          }
        }

        RowLayout {
          width: parent.width
          visible: !root.showingInfo && root.mode === "browser"
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Frame rate and delay"
            color: root.ink
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            Layout.alignment: Qt.AlignVCenter
          }

          ToggleSwitch {
            checked: root.previewOn
            foreground: root.ink
            Layout.alignment: Qt.AlignVCenter
            onToggled: root.setPreview(!root.previewOn)
          }
        }

        RowLayout {
          width: parent.width
          visible: !root.showingInfo && root.mode === "browser" && root.viewUrl !== ""
          spacing: Style.space(6)

          Text {
            text: "Watch at"
            color: root.ink
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            Layout.alignment: Qt.AlignBaseline
          }

          Text {
            Layout.fillWidth: true
            text: root.viewUrl
            wrapMode: Text.WrapAnywhere
            color: root.ink
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            Layout.alignment: Qt.AlignBaseline
          }
        }

        Column {
          width: parent.width
          visible: !root.showingInfo && root.mode === "browser"
          spacing: Style.space(10)

          Row {
            spacing: Style.space(8)
            Button {
              bordered: true
              focusable: true
              foreground: root.ink
              text: "Copy address"
              enabled: root.canCopy
              onClicked: if (root.hostWidget) root.hostWidget.doCopy()
            }
            Button {
              id: qrButton
              bordered: true
              focusable: true
              foreground: root.ink
              text: "QR code"
              enabled: root.viewUrl !== ""
              onClicked: {
                if (qrPopup.opened) {
                  root.qrRequested = false
                  qrPopup.close()
                } else {
                  root.showQr()
                }
              }

              QQC.Popup {
                id: qrPopup
                // The panel sits on the bottom bar, so a downward popup runs off the screen.
                padding: Style.space(12)
                width: Style.space(220)
                x: {
                  var origin = qrButton.mapToItem(null, 0, 0)
                  if (!origin)
                    return 0
                  var room = panel.screenW - width - Style.space(8)
                  return origin.x > room ? room - origin.x : 0
                }
                y: -(padding * 2 + qrBody.implicitHeight) - Style.space(6)
                modal: false
                focus: true
                // Outside the frame closes it. The button is the popup's parent,
                // so a second click on QR code is not treated as an outside click.
                closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutsideParent
                onClosed: root.qrRequested = false

                background: Rectangle {
                  color: Color.popups.background
                  border.color: Color.popups.border
                  border.width: Math.max(1, Style.space(1))
                  radius: Style.cornerRadius
                }

                contentItem: Column {
                  id: qrBody
                  spacing: Style.space(8)
                  Image {
                    width: Style.space(196)
                    height: Style.space(196)
                    fillMode: Image.PreserveAspectFit
                    cache: false
                    visible: root.qrSource !== ""
                    source: root.qrSource
                  }
                  Text {
                    width: parent.width
                    visible: root.qrMessage !== ""
                    text: root.qrMessage
                    wrapMode: Text.WordWrap
                    color: root.ink
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }

            Button {
              id: infoButton
              bordered: true
              focusable: true
              foreground: root.ink
              text: "Info"
              onClicked: root.showingInfo = true
          }
        }

      }
    }
  }
  }

  Process {
    id: desktopProc
    command: ["screencast", "desktops", "--json"]
    stdout: StdioCollector {
      id: desktopOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var data = null
      try {
        data = JSON.parse(String(desktopOut.text || ""))
      } catch (e) {
        data = null
      }
      if (data && data.desktops)
        root.desktopOptions = data.desktops
    }
  }

  Process {
    id: castReadProc
    command: ["screencast", "cast", "--json"]
    stdout: StdioCollector {
      id: castReadOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var data = null
      try {
        data = JSON.parse(String(castReadOut.text || ""))
      } catch (e) {
        data = null
      }
      if (!data)
        return
      if (data.follow)
        root.workspaceChoice = "follow"
      else if (data.workspace)
        root.workspaceChoice = String(data.workspace)
      if (data.auto === true || data.size === "auto")
        root.sizeChoice = "auto"
      else if (data.size)
        root.sizeChoice = String(data.size)
    }
  }

  Process {
    id: previewProc
    command: ["screencast", "preview", "off"]
    onExited: function(exitCode) {
      if (root.previewQueued) {
        root.previewQueued = false
        previewProc.command = ["screencast", "preview", root.previewWant ? "on" : "off"]
        previewProc.running = true
        return
      }
      if (exitCode !== 0) {
        root.previewHold = false
        root.previewOn = root.previewFromHost
      }
      if (root.hostWidget && root.hostWidget.doRefresh)
        root.hostWidget.doRefresh()
    }
  }

  Process {
    id: castWriteProc
    command: ["screencast", "cast", "--json"]
    onExited: function(exitCode) {
      if (root.queuedCast.length > 0) {
        var next = root.queuedCast
        root.queuedCast = []
        root.saveCast(next)
        return
      }
      if (root.hostWidget && root.hostWidget.doRefresh)
        root.hostWidget.doRefresh()
    }
  }

  Process {
    id: qrProc
    command: ["screencast", "qr"]
    stdout: StdioCollector {
      id: qrOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (!root.qrRequested)
        return
      root.qrRequested = false
      if (exitCode !== 0) {
        root.qrSource = ""
        root.qrMessage = "Install qrencode to show a QR code."
        qrPopup.open()
        return
      }
      var path = String(qrOut.text || "").trim()
      root.qrMessage = ""
      root.qrSource = ""
      Qt.callLater(function() {
        if (root.qrJustClosed)
          return
        root.qrSource = path === "" ? "" : "file://" + path
        qrPopup.open()
      })
    }
  }

  Timer {
    interval: 2000
    running: root.opened && root.mode === "receivers"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollMirror()
  }

  Process {
    id: mirrorCmdProc
    command: ["screencast", "mirror", "status"]
    onExited: function(exitCode) {
      if (root.mirrorQueue.length > 0) {
        root.pumpMirror()
        return
      }
      root.pollMirror()
    }
  }

  Process {
    id: mirrorStatusProc
    command: ["screencast", "mirror", "status"]
    stdout: StdioCollector {
      id: mirrorStatusOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var busy = root.mirrorCmdProc.running || root.mirrorQueue.length > 0
      if (!busy) {
        var data = null
        try {
          data = JSON.parse(String(mirrorStatusOut.text || ""))
        } catch (e) {
          data = null
        }
        var next = []
        var list = data && data.sessions ? data.sessions : []
        for (var i = 0; i < list.length; i++) {
          var item = list[i]
          if (!item || !item.id)
            continue
          var state = String(item.state || "stopped")
          if (state === "stopped")
            continue
          next.push({
            id: String(item.id),
            name: String(item.name || ""),
            state: state,
            detail: String(item.detail || ""),
            url: String(item.url || "")
          })
        }
        root.mirrorSessions = next
      }
      if (root.mirrorPollQueued) {
        root.mirrorPollQueued = false
        if (!root.mirrorCmdProc.running)
          root.pollMirror()
      }
    }
  }

  Process {
    id: scanProc
    command: ["screencast", "receivers"]
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.scanning = false
      var data = null
      try {
        data = JSON.parse(String(scanOut.text || ""))
      } catch (e) {
        data = null
      }
      if (!data) {
        root.scanError = "The receiver search did not answer."
      } else {
        root.scanError = data.error ? String(data.error) : ""
        root.receivers = data.receivers || []
        var stillThere = false
        for (var i = 0; i < root.receivers.length; i++) {
          if (root.receivers[i] && root.receivers[i].id === root.receiverChoice)
            stillThere = true
        }
        if (!stillThere)
          root.receiverChoice = ""
      }
      if (root.scanQueued) {
        root.scanQueued = false
        root.scanReceivers()
      }
    }
  }
}
