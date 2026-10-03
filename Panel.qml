import QtQuick
import Quickshell
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
  readonly property string sameWifi: hostWidget ? hostWidget.sameWifi : ""
  readonly property string browserNote: hostWidget ? hostWidget.browserNote : ""

  readonly property bool canStart: viewState === "stopped" || viewState === "failed"
  readonly property bool canStop: viewState === "live" || viewState === "starting"
  readonly property bool canCopy: viewUrl !== ""
  readonly property bool canOpenWindow: viewState !== "missing"
  readonly property color ink: bar ? bar.barForeground : Color.foreground

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

  function openWindow() {
    Quickshell.execDetached([
      "foot", "--app-id=screenmirror", "--title=ScreenMirror", "-e", "screenmirror", "ui"
    ])
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

        Text {
          width: parent.width
          text: "ScreenMirror"
          color: root.ink
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.stateLabel
          color: root.ink
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
        }

        Text {
          width: parent.width
          visible: root.viewDetail !== ""
          text: root.viewDetail
          wrapMode: Text.WordWrap
          color: root.ink
          opacity: 0.8
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: root.viewUrl !== ""
          text: root.viewUrl
          wrapMode: Text.WrapAnywhere
          color: root.ink
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.sameWifi
          wrapMode: Text.WordWrap
          color: root.ink
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          text: root.browserNote
          wrapMode: Text.WordWrap
          color: root.ink
          opacity: 0.85
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Row {
          spacing: Style.space(8)
          Button {
            text: "Start"
            enabled: root.canStart
            focusable: true
            onClicked: if (root.hostWidget) root.hostWidget.doStart()
          }
          Button {
            text: "Stop"
            enabled: root.canStop
            focusable: true
            onClicked: if (root.hostWidget) root.hostWidget.doStop()
          }
          Button {
            text: "Copy address"
            enabled: root.canCopy
            focusable: true
            onClicked: if (root.hostWidget) root.hostWidget.doCopy()
          }
        }

        Button {
          text: "Open window"
          enabled: root.canOpenWindow
          focusable: true
          onClicked: root.openWindow()
        }
      }
    }
  }
}
