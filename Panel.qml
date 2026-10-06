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
  property bool scanning: false
  property bool scanQueued: false
  property string scanError: ""
  property bool showingInfo: false
  property bool qrRequested: false
  property bool qrJustClosed: false
  property bool qrOpenAtPress: false

  readonly property string refreshGlyph: String.fromCodePoint(0xF0450)
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
  Component.onCompleted: refreshChoices()

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
              text: "Find AirPlay, Chromecast and Miracast devices on this Wi-Fi. Select a device to connect."
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
              text: "No AirPlay, Chromecast, or Miracast devices answered."
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
                readonly property bool chosen: root.receiverChoice === modelData.id
                width: deviceColumn.width
                height: deviceRow.implicitHeight + Style.space(16)
                color: chosen ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.12) : "transparent"

                RowLayout {
                  id: deviceRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(8)

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    RowLayout {
                      Layout.fillWidth: true
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
                        // Highlight means the row is chosen. The word means
                        // that device is the one this cast is using.
                        visible: chosen && (root.viewState === "live" || root.viewState === "starting")
                        text: "Mirroring"
                        color: root.ink
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.body
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      text: modelData.address
                      color: root.ink
                      opacity: 0.7
                      wrapMode: Text.WrapAnywhere
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.subtitle
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.receiverChoice = modelData.id
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
