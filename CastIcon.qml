import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons

// Line and pixel drawings use currentColor, so they are tinted to the bar.
// The Tokyo drawings already carry the Tokyo Night colors.
// The panel header and the tray both rasterize at Style.space(32). Scaling a
// smaller bar texture up is what made the tray copy look soft.
Item {
  id: icon

  property bool on: false
  property color tint: "#e6e6e6"
  property string themeName: ""

  readonly property string styleName: {
    var name = themeName.toLowerCase()
    if (name.indexOf("tokyo") >= 0)
      return "tokyo"
    if (name.indexOf("pixel") >= 0)
      return "pixel"
    return "line"
  }
  readonly property bool colored: styleName === "tokyo"
  readonly property int box: Style.space(32)
  readonly property int raster: Math.round(box * Screen.devicePixelRatio)
  readonly property url sourceUrl: Qt.resolvedUrl("icons/screen-cast-" + (on ? "on" : "off") + "-" + styleName + ".svg")

  clip: false

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: icon.themeName = String(text()).trim()
    onFileChanged: reload()
    onLoadFailed: icon.themeName = ""
  }

  Image {
    id: picture
    anchors.centerIn: parent
    width: icon.box
    height: icon.box
    source: icon.sourceUrl
    fillMode: Image.PreserveAspectFit
    smooth: icon.styleName !== "pixel"
    mipmap: false
    visible: icon.colored
    sourceSize.width: icon.raster
    sourceSize.height: icon.raster
  }

  Image {
    id: mono
    anchors.centerIn: parent
    width: icon.box
    height: icon.box
    source: icon.sourceUrl
    fillMode: Image.PreserveAspectFit
    smooth: icon.styleName !== "pixel"
    mipmap: false
    visible: false
    layer.enabled: !icon.colored
    layer.smooth: false
    sourceSize.width: icon.raster
    sourceSize.height: icon.raster
  }

  MultiEffect {
    anchors.centerIn: parent
    width: icon.box
    height: icon.box
    source: mono
    visible: !icon.colored
    colorization: 1.0
    colorizationColor: icon.tint
  }
}
