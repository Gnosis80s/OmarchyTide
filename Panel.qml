import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Whitley Bay tide popup: next high/low in a hero, a rolling 6 h back + 18 h
// ahead tide wave with a NOW marker and a LOW→HIGH water gauge, plus the
// upcoming events. Data is fetched from the Open Waters tide API (North
// Shields reference station) and cached so the panel still works offline.
Panel {
  id: root
  moduleName: "whitleybay.tide"
  ipcTarget: "whitleybay.tide"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Data
  property var extremes: []
  property var timeline: []
  property bool dataLoaded: false
  property real nowMs: 0
  property int extremesRetries: 0
  property int timelineRetries: 0

  readonly property var nextEvent: Model.firstAfter(root.extremes, root.nowMs)
  readonly property var nextHighEvent: Model.firstHighAfter(root.extremes, root.nowMs)
  readonly property var nextLowEvent: Model.firstLowAfter(root.extremes, root.nowMs)
  readonly property var tideNow: Model.currentLevel(root.timeline, root.extremes, root.nowMs)
  readonly property var upcoming: Model.nextWindow(root.extremes, root.nowMs, 4)
  readonly property var phaseInfo: Model.flanking(root.extremes, root.nowMs, root.tideNow ? root.tideNow.level : NaN)

  readonly property int contentInset: Style.space(20)

  // Consumed by BarWidget.qml for the pill.
  readonly property string label: (function() {
    if (!root.dataLoaded) return "…"
    return Model.barLabel(root.extremes, root.nowMs, root.dataLoaded)
  })()

  readonly property string stateText: Model.tideState(root.nextEvent)
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var curveSamples: []
  property var phaseExtremes: []

  function tick() {
    root.nowMs = (new Date()).getTime()
    root.recomputeCurve()
  }

  function recomputeCurve() {
    root.curveSamples = Model.phaseSamples(root.timeline, root.extremes, root.nowMs, 6, 18)
    root.phaseExtremes = Model.extremesBetween(root.extremes, root.nowMs - 6 * 3600 * 1000, root.nowMs + 18 * 3600 * 1000)
  }

  function loadCaches() {
    extremesCacheFile.reload()
    timelineCacheFile.reload()
  }

  function refresh() {
    root.tick()
    extremesProc.command = root.fetchCommand(root.extremesBaseUrl, root.settingsDir + "/whitleybay-tide-extremes.json", 24, 72)
    timelineProc.command = root.fetchCommand(root.timelineBaseUrl, root.settingsDir + "/whitleybay-tide-timeline.json", 12, 36)
    if (!extremesProc.running) extremesProc.running = true
    if (!timelineProc.running) timelineProc.running = true
  }

  function onExtremesFetched(raw) {
    var parsed = Model.parseExtremes(raw)
    if (parsed.length === 0) {
      if (root.extremesRetries < 3) { root.extremesRetries++; extremesRetryTimer.restart() }
      return
    }
    root.extremesRetries = 0
    root.extremes = parsed
    root.dataLoaded = true
    root.tick()
  }

  function onTimelineFetched(raw) {
    var parsed = Model.parseTimeline(raw)
    if (parsed.length === 0) {
      if (root.timelineRetries < 3) { root.timelineRetries++; timelineRetryTimer.restart() }
      return
    }
    root.timelineRetries = 0
    root.timeline = parsed
    root.dataLoaded = true
    root.tick()
  }

  function open() {
    root.loadCaches()
    root.refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  onNowMsChanged: root.recomputeCurve()
  onExtremesChanged: root.recomputeCurve()
  onTimelineChanged: root.recomputeCurve()

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.tick()
  }

  // Live data keeps itself current: re-fetch extremes and the timeline every
  // ten minutes. The 60s timer above advances the NOW marker meanwhile.
  Timer {
    id: dataRefreshTimer
    interval: 10 * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // ---- Cached copies survive the network being gone; reloaded on open and
  //      refreshed by every successful fetch.
  readonly property string settingsDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"

  FileView {
    id: extremesCacheFile
    path: root.settingsDir + "/whitleybay-tide-extremes.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var parsed = Model.parseExtremes(text())
      if (parsed.length > 0) { root.extremes = parsed; root.dataLoaded = true }
    }
  }

  FileView {
    id: timelineCacheFile
    path: root.settingsDir + "/whitleybay-tide-timeline.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var parsed = Model.parseTimeline(text())
      if (parsed.length > 0) root.timeline = parsed
    }
  }

  // ---- Fetches. curl output is written to a temp file, swapped into the
  //      cache, then echoed so the collector can parse it; a failed request
  //      leaves the previous cache untouched. The start/end window is computed
  //      in bash (GNU date) on every fetch so it always spans the past (for the
  //      wave's back-half and the previous extreme) and plenty of future events.
  readonly property string extremesBaseUrl: "https://api.openwaters.io/tides/extremes?latitude=55.0456&longitude=-1.4443&units=meters"
  readonly property string timelineBaseUrl: "https://api.openwaters.io/tides/timeline?latitude=55.0456&longitude=-1.4443"

  function fetchCommand(urlBase, cachePath, backHours, aheadHours) {
    return ["bash", "-c",
      "start=$(date -u +%Y-%m-%dT%H:%M:%SZ -d \"-" + backHours + " hours\")\n" +
      "end=$(date -u +%Y-%m-%dT%H:%M:%SZ -d \"+" + aheadHours + " hours\")\n" +
      "url=\"" + urlBase + "&start=$start&end=$end\"\n" +
      "tmp=\"$0.$$.tmp\"\n" +
      "curl -fsS --max-time 8 \"$url\" -o \"$tmp\" || { rm -f \"$tmp\"; exit 1; }\n" +
      "mkdir -p \"$(dirname \"$0\")\" && mv -f \"$tmp\" \"$0\" && cat \"$0\"",
      cachePath]
  }

  Process {
    id: extremesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onExtremesFetched(text)
    }
  }

  Timer {
    id: extremesRetryTimer
    interval: 3000
    onTriggered: {
      extremesProc.command = root.fetchCommand(root.extremesBaseUrl, root.settingsDir + "/whitleybay-tide-extremes.json", 24, 72)
      if (!extremesProc.running) extremesProc.running = true
    }
  }

  Process {
    id: timelineProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onTimelineFetched(text)
    }
  }

  Timer {
    id: timelineRetryTimer
    interval: 4000
    onTriggered: {
      timelineProc.command = root.fetchCommand(root.timelineBaseUrl, root.settingsDir + "/whitleybay-tide-timeline.json", 12, 36)
      if (!timelineProc.running) timelineProc.running = true
    }
  }

  Component.onCompleted: {
    extremesProc.command = root.fetchCommand(root.extremesBaseUrl, root.settingsDir + "/whitleybay-tide-extremes.json", 24, 72)
    timelineProc.command = root.fetchCommand(root.timelineBaseUrl, root.settingsDir + "/whitleybay-tide-timeline.json", 12, 36)
    root.loadCaches()
    root.refresh()
    root.tick()
    root.recomputeCurve()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(tideColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: tideScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: tideColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: tideColumn
          width: tideScroll.width
          spacing: Style.space(16)

          // ---- Head
          Item {
            width: parent.width
            height: Math.max(headLeft.implicitHeight, headRight.implicitHeight)

            Row {
              id: headLeft
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "WHITLEY BAY"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.6
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "NORTH SEA · ST MARY'S"
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.1
              }
            }

            Text {
              id: headRight
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              text: root.stateText
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
              font.bold: true
            }
          }

          // ---- Hero: next event on the left, current level on the right.
          Item {
            width: parent.width
            height: Math.max(heroLeft.implicitHeight, heroRight.implicitHeight)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(14)

              Text {
                id: heroArrow
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 2
                text: root.nextEvent ? Model.arrow(root.nextEvent) : "—"
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: 40
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: root.nextEvent ? Model.formatTime(root.nextEvent.ms) : (root.dataLoaded ? "—" : "…")
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: 46
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.nextEvent
                    ? (root.nextEvent.high ? "HIGH " : "LOW ") + Model.heightText(root.nextEvent.level)
                    : ""
                  color: Qt.darker(root.contentForeground, 1.45)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1.2
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: "NOW"
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.tideNow ? Model.heightText(root.tideNow.level) : "—"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.stateText ? root.stateText.toLowerCase() : ""
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
          }

          // ---- Tide phase: a rolling wave chart with a clear NOW marker,
          //      plus a water gauge showing where now sits on the tide.
          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              height: Math.max(phaseHeaderTitle.implicitHeight, phaseHeaderNote.implicitHeight)

              Text {
                id: phaseHeaderTitle
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: root.contentInset
                anchors.verticalCenter: parent.verticalCenter
                text: "TIDE PHASE"
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
                font.bold: true
              }

              Text {
                id: phaseHeaderNote
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: root.contentInset
                anchors.verticalCenter: parent.verticalCenter
                text: "6 H BACK · 18 H AHEAD"
                color: Qt.darker(root.contentForeground, 2.2)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }

            // ---- Tide phase wave, drawn with QtQuick.Shapes (scene-graph
            //      rendering that scales and redraws reliably on this box),
            //      overlaid with plain items for grid, markers and labels.
            Item {
              id: wave
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              height: Style.space(148)

              property var samples: root.curveSamples
              property var markers: root.phaseExtremes
              property var nowMs: root.nowMs
              property color lineColor: Color.accent

              readonly property real padL: Style.spaceReal(40)
              readonly property real padR: Style.spaceReal(6)
              readonly property real padT: Style.spaceReal(30)
              readonly property real padB: Style.spaceReal(18)
              readonly property real x0: wave.padL
              readonly property real x1: wave.width - wave.padR
              readonly property real yTop: wave.padT
              readonly property real yBase: wave.height - wave.padB

              function domain() {
                var pts = wave.samples || []
                var n = pts.length
                if (n < 2) return null
                var minLv = Infinity
                var maxLv = -Infinity
                for (var i = 0; i < n; i++) {
                  var lv = pts[i].level
                  if (lv < minLv) minLv = lv
                  if (lv > maxLv) maxLv = lv
                }
                var pad = (maxLv - minLv) * 0.10
                minLv -= pad
                maxLv += pad
                return {
                  startMs: pts[0].ms,
                  endMs: pts[n - 1].ms,
                  spanMs: (pts[n - 1].ms - pts[0].ms) || 1,
                  minLv: minLv,
                  maxLv: maxLv,
                  lvSpan: (maxLv - minLv) || 1
                }
              }

              function xx(t) {
                var d = wave.domain()
                return d ? wave.x0 + (t - d.startMs) / d.spanMs * (wave.x1 - wave.x0) : 0
              }

              function yOf(lv) {
                var d = wave.domain()
                return d ? wave.yBase - (lv - d.minLv) / d.lvSpan * (wave.yBase - wave.yTop) : 0
              }

              function lvText(l) {
                return l.toFixed(1) + " m"
              }

              function points(fromIdx, toIdx, closeArea) {
                var pts = wave.samples || []
                var d = wave.domain()
                var out = []
                if (d && fromIdx <= toIdx) {
                  for (var i = fromIdx; i <= toIdx; i++) {
                    out.push(Qt.point(wave.xx(pts[i].ms), wave.yOf(pts[i].level)))
                  }
                  if (closeArea) {
                    out.push(Qt.point(wave.x1, wave.yBase))
                    out.push(Qt.point(wave.x0, wave.yBase))
                  }
                }
                return out
              }

              readonly property int nowIdx: (function() {
                var pts = wave.samples || []
                var ms = wave.nowMs
                var i = 0
                while (i < pts.length && pts[i].ms < ms) i++
                return Math.min(pts.length - 1, Math.max(1, i))
              })()

              readonly property var polyPast: wave.points(0, wave.nowIdx, false)
              readonly property var polyFuture: wave.points(wave.nowIdx, (wave.samples ? wave.samples.length : 1) - 1, false)
              readonly property var polyArea: wave.points(0, (wave.samples ? wave.samples.length : 1) - 1, true)

              readonly property var gridLevels: (function() {
                var d = wave.domain()
                if (!d) return []
                return [ d.minLv, (d.minLv + d.maxLv) / 2, d.maxLv ]
              })()

              readonly property var ticks: (function() {
                var out = []
                var ms = wave.nowMs
                for (var o = -6; o <= 18; o += 6) {
                  var tx = wave.xx(ms + o * 3600 * 1000)
                  if (tx < wave.x0 - Style.spaceReal(2) || tx > wave.x1 + Style.spaceReal(2)) continue
                  out.push({ x: tx, label: o === 0 ? "NOW" : Model.formatTime(ms + o * 3600 * 1000), now: o === 0 })
                }
                return out
              })()

              readonly property var marks: (function() {
                var out = []
                var m = wave.markers || []
                for (var i = 0; i < m.length; i++) {
                  var ev = m[i]
                  var mx = wave.xx(ev.ms)
                  if (mx < wave.x0 || mx > wave.x1) continue
                  out.push({ x: mx, y: wave.yOf(ev.level), high: ev.high, label: (ev.high ? "▲ " : "▼ ") + Model.formatTime(ev.ms) })
                }
                return out
              })()

              readonly property real xNow: wave.xx(wave.nowMs)
              readonly property real yNow: (function() {
                var lvl = Model.levelAtSamples(wave.samples || [], wave.nowMs)
                return wave.yOf(isNaN(lvl) ? NaN : lvl)
              })()

              // ---- translucent water under the wave, drawn live with QtQuick.Shapes.
              Shape {
                anchors.fill: parent
                antialiasing: true

                ShapePath {
                  strokeColor: "transparent"
                  fillColor: "transparent"
                  fillGradient: LinearGradient {
                    x1: 0
                    y1: wave.yTop
                    x2: 0
                    y2: wave.yBase
                    GradientStop {
                      position: 0
                      color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.03)
                    }
                    GradientStop {
                      position: 0.55
                      color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.14)
                    }
                    GradientStop {
                      position: 1
                      color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.30)
                    }
                  }
                  PathPolyline { path: wave.polyArea }
                }

                ShapePath {
                  strokeColor: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.35)
                  strokeWidth: 1.4
                  fillColor: "transparent"
                  capStyle: ShapePath.RoundCap
                  joinStyle: ShapePath.RoundJoin
                  PathPolyline { path: wave.polyPast }
                }

                ShapePath {
                  strokeColor: wave.lineColor
                  strokeWidth: 1.9
                  fillColor: "transparent"
                  capStyle: ShapePath.RoundCap
                  joinStyle: ShapePath.RoundJoin
                  PathPolyline { path: wave.polyFuture }
                }
              }

              // ---- grid: three horizontal level lines with labels.
              Repeater {
                model: wave.gridLevels
                delegate: Item {
                  required property real modelData
                  Rectangle {
                    x: wave.x0
                    y: wave.yOf(parent.modelData)
                    width: wave.x1 - wave.x0
                    height: 1
                    color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.10)
                  }
                  Text {
                    x: wave.x0 - Style.spaceReal(6) - implicitWidth
                    y: wave.yOf(parent.modelData) - implicitHeight / 2
                    text: wave.lvText(parent.modelData)
                    color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.55)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.spaceReal(10)
                    font.bold: true
                  }
                }
              }

              // ---- time ticks along the bottom.
              Repeater {
                model: wave.ticks
                delegate: Item {
                  required property var modelData
                  Rectangle {
                    x: parent.modelData.x - width / 2
                    y: wave.yTop
                    width: 1
                    height: wave.yBase - wave.yTop
                    color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, parent.modelData.now ? 0.28 : 0.10)
                  }
                  Text {
                    x: parent.modelData.x - implicitWidth / 2
                    y: wave.yBase + Style.spaceReal(3)
                    text: parent.modelData.label
                    color: parent.modelData.now ? wave.lineColor : Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.spaceReal(10)
                    font.bold: true
                  }
                }
              }

              // ---- high/low event markers with time labels.
              Repeater {
                model: wave.marks
                delegate: Item {
                  required property var modelData
                  Rectangle {
                    x: parent.modelData.x - Style.spaceReal(2.4)
                    y: parent.modelData.y - Style.spaceReal(2.4)
                    width: Style.spaceReal(4.8)
                    height: Style.spaceReal(4.8)
                    radius: width / 2
                    color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.5)
                  }
                  Text {
                    x: parent.modelData.x - implicitWidth / 2
                    y: parent.modelData.high
                      ? parent.modelData.y - Style.spaceReal(13) - implicitHeight
                      : parent.modelData.y + Style.spaceReal(13)
                    text: parent.modelData.label
                    color: parent.modelData.high ? wave.lineColor : Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.55)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.spaceReal(10)
                    font.bold: true
                  }
                }
              }

              // ---- NOW marker: hairline plus a glowing dot on the wave.
              Rectangle {
                x: wave.xNow - width / 2
                y: wave.yTop
                width: 1
                height: wave.yBase - wave.yTop
                color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.28)
              }

              Rectangle {
                x: wave.xNow - Style.spaceReal(8.5)
                y: wave.yNow - Style.spaceReal(8.5)
                width: Style.spaceReal(17)
                height: Style.spaceReal(17)
                radius: width / 2
                color: "transparent"
                border.width: 1.4
                border.color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.28)
              }

              Rectangle {
                x: wave.xNow - Style.spaceReal(4.4)
                y: wave.yNow - Style.spaceReal(4.4)
                width: Style.spaceReal(8.8)
                height: Style.spaceReal(8.8)
                radius: width / 2
                color: wave.lineColor
              }

              Text {
                x: wave.xNow - implicitWidth / 2
                y: wave.yTop - Style.spaceReal(2) - implicitHeight
                text: "NOW"
                color: wave.lineColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.spaceReal(11)
                font.bold: true
              }
            }

            // ---- Water gauge: the current half-cycle laid out as a bar from
            //      LOW water (left) to HIGH water (right), knob at now.
            Item {
              width: parent.width
              property real barTop: captions.height + Style.space(8)
              height: barTop + Style.space(13) + Style.space(8) + summaryText.implicitHeight

              Item {
                id: captions
                anchors.left: parent.left
                anchors.leftMargin: root.contentInset
                anchors.right: parent.right
                anchors.rightMargin: root.contentInset
                height: Math.max(captionsLow.implicitHeight, captionsHigh.implicitHeight)

                Text {
                  id: captionsLow
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.phaseInfo
                    ? "LOW ▼ " + Model.formatTime(root.phaseInfo.low.ms) + "  ·  " + Model.heightText(root.phaseInfo.low.level)
                    : "LOW"
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Text {
                  id: captionsHigh
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  horizontalAlignment: Text.AlignRight
                  text: root.phaseInfo
                    ? "HIGH ▲ " + Model.formatTime(root.phaseInfo.high.ms) + "  ·  " + Model.heightText(root.phaseInfo.high.level)
                    : "HIGH"
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }

              Rectangle {
                id: gaugeTrack
                anchors.left: parent.left
                anchors.leftMargin: root.contentInset
                anchors.right: parent.right
                anchors.rightMargin: root.contentInset
                y: parent.barTop
                height: Style.space(13)
                radius: height / 2
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.10)
              }

              Rectangle {
                id: gaugeFill
                anchors.left: gaugeTrack.left
                anchors.top: gaugeTrack.top
                anchors.bottom: gaugeTrack.bottom
                width: root.phaseInfo ? gaugeTrack.width * root.phaseInfo.fraction : 0
                radius: gaugeTrack.radius
                gradient: Gradient {
                  orientation: Gradient.Vertical
                  GradientStop { position: 0.0; color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55) }
                  GradientStop { position: 1.0; color: Color.accent }
                }
              }

              Rectangle {
                id: gaugeKnob
                width: Style.space(17)
                height: Style.space(17)
                radius: width / 2
                color: Color.accent
                x: root.phaseInfo
                  ? Math.max(gaugeTrack.x, Math.min(gaugeTrack.x + gaugeTrack.width * root.phaseInfo.fraction - width / 2, gaugeTrack.x + gaugeTrack.width - width))
                  : gaugeTrack.x
                y: gaugeTrack.y + gaugeTrack.height / 2 - height / 2
              }

              Text {
                id: summaryText
                textFormat: Text.PlainText
                anchors.top: gaugeTrack.bottom
                anchors.topMargin: Style.space(8)
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.phaseInfo
                  ? root.stateText + "  ·  " + Math.round(root.phaseInfo.fraction * 100) + "% OF RANGE  ·  NOW " + Model.heightText(root.phaseInfo.level)
                  : "…"
                color: Qt.darker(root.contentForeground, 1.45)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }
            }
          }

          // ---- Upcoming events.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              text: "COMING UP"
              color: Qt.darker(root.contentForeground, 1.7)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.4
              font.bold: true
            }

            Item { width: parent.width; height: Style.space(6) }

            Repeater {
              model: root.upcoming

              Item {
                required property var modelData
                required property int index
                width: parent.width - Style.space(40)
                height: Style.space(26)

                readonly property bool firstRow: index === 0
                readonly property color rowForeground: firstRow ? root.contentForeground : Qt.darker(root.contentForeground, 1.35)
                readonly property color rowAccent: firstRow ? Color.accent : Qt.darker(Color.accent, 1.15)

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(128)
                  text: Model.formatDayTime(modelData.ms)
                  color: parent.rowForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: parent.firstRow
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(140)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(24)
                  text: Model.arrow(modelData)
                  color: parent.rowAccent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(72)
                  horizontalAlignment: Text.AlignRight
                  text: Model.heightText(modelData.level)
                  color: parent.rowForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }

          // ---- Footer
          Item {
            width: parent.width
            height: Math.max(footLeft.implicitHeight, footRight.implicitHeight) + Style.space(12)

            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              anchors.top: parent.top
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.10
            }

            Row {
              id: footLeft
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.top: parent.top
              anchors.topMargin: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: "NORTH SHIELDS GAUGE"
                color: Qt.darker(root.contentForeground, 1.9)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }

            Text {
              id: footRight
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              anchors.top: parent.top
              anchors.topMargin: Style.space(10)
              text: "OPENWATERS.IO"
              color: Qt.darker(root.contentForeground, 1.9)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }
        }
      }
    }
  }
}