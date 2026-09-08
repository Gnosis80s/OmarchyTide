import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Whitley Bay tide pill: a mini water gauge (level between LOW and HIGH of
// the current half-cycle) next to the next high ("▲ 13:22") or low ("▼ 07:09"),
// with a tide-curve popup owned by Panel.qml. Left click opens the panel,
// middle click refreshes, right click toggles nothing yet.
BarWidget {
  id: root
  moduleName: "whitleybay.tide"

  readonly property var panel: panelLoader.item
  readonly property real phaseFraction: panel && panel.phaseInfo ? panel.phaseInfo.fraction : 0
  readonly property bool hasData: panel ? panel.label !== "" && panel.label !== "…" : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item && panelLoader.item.label !== ""
  implicitWidth: pillRow.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: panelLoader.item ? panelLoader.item.label : ""
    hasVisualContent: text !== ""
    labelVisible: false
    horizontalMargin: 7
    verticalPadding: 7
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }

  // ---- Pill body: a mini water gauge + the next-event time.
  Item {
    id: pillBody
    anchors.centerIn: button
    width: pillRow.implicitWidth
    height: pillRow.implicitHeight

    Row {
      id: pillRow
      spacing: Style.space(5)

      // Mini gauge: a little tide column filling between LOW and HIGH water.
      Item {
        width: Style.space(9)
        height: Style.space(16)
        visible: root.hasData

        Rectangle {
          anchors.fill: parent
          radius: Style.spaceReal(2.5)
          color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.16)
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(Style.spaceReal(2), parent.height * root.phaseFraction)
          radius: Style.spaceReal(2.5)
          color: Color.accent
        }
      }

      Text {
        textFormat: Text.PlainText
        text: panelLoader.item ? panelLoader.item.label : ""
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
    }
  }
}