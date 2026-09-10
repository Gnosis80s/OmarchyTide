import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Tide popup: a live location search picks any coastal place, and that
// place's high/low extremes drive a rolling 6 h back + 18 h ahead tide wave
// with a NOW marker, a LOW→HIGH water gauge, and the upcoming events. Data is
// fetched from the Open Waters tide API and cached per location so the panel
// still works offline.
Panel {
  id: root
  moduleName: "gnosis.tide"
  ipcTarget: "gnosis.tide"
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
  property bool dataFailed: false
  property real nowMs: 0
  property int extremesRetries: 0
  property int timelineRetries: 0
  property var sunTimes: null

  readonly property string settingsDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"

  // ---- Selected location. Persisted to a state file; empty until the user
  //      searches and picks a coastal place (coordinates are required — a name
  //      alone cannot resolve to tides).
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property bool hasLocation: !!root.configuredLocationState && root.configuredLocationState.name !== ""
  readonly property string displayLocationName: root.hasLocation ? String(root.configuredLocationState.name) : ""
  property bool editingLocation: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Guards against refetching when the persisted file re-fed the same place.
  property string appliedLocationKey: "\u0000"
  // Sanitized location name keys the per-location disk caches.
  property string cacheSlug: "nolocation"
  readonly property string locationFilePath: root.settingsDir + "/gnosis-tide-location.json"
  readonly property string extremesCachePath: root.settingsDir + "/gnosis-tide-" + root.cacheSlug + "-extremes.json"
  readonly property string timelineCachePath: root.settingsDir + "/gnosis-tide-" + root.cacheSlug + "-timeline.json"

  readonly property var nextEvent: Model.firstAfter(root.extremes, root.nowMs)
  readonly property var nextHighEvent: Model.firstHighAfter(root.extremes, root.nowMs)
  readonly property var nextLowEvent: Model.firstLowAfter(root.extremes, root.nowMs)
  readonly property var tideNow: Model.currentLevel(root.timeline, root.extremes, root.nowMs)
  readonly property var upcoming: Model.nextWindow(root.extremes, root.nowMs, 4)
  readonly property var phaseInfo: Model.flanking(root.extremes, root.nowMs, root.tideNow ? root.tideNow.level : NaN)

  readonly property int contentInset: Style.space(20)

  // Consumed by BarWidget.qml for the pill. Stays visible before any location
  // is picked so the panel stays reachable (opening it then starts the search).
  readonly property string label: (function() {
    if (!root.hasLocation) return "TIDE"
    if (!root.dataLoaded) return "…"
    return Model.barLabel(root.extremes, root.nowMs, root.dataLoaded)
  })()

  readonly property string stateText: Model.tideState(root.nextEvent)
  readonly property var moon: Model.moonInfo(root.nowMs)
  readonly property string moonPhase: root.moon ? root.moon.phase.toUpperCase() : ""
  readonly property string moonSubline: (function() {
    if (!root.moon) return ""
    return Math.round(root.moon.illumination * 100) + "% LIT · AGE " + root.moon.ageDays.toFixed(1) + " DAYS"
  })()
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var curveSamples: []
  property var phaseExtremes: []

  function tick() {
    root.nowMs = (new Date()).getTime()
    root.recomputeCurve()
  }

  // Paints the moon's visible disc: the lit shape (crescent lens or
  // disc-minus-shade) with the lit side on the sunward tack. A straight phase
  // graphic — waxing leans right, waning left, no sky tilt.
  function paintMoon(ctx) {
    if (!ctx) return
    var cw = moonCanvas.width, ch = moonCanvas.height
    var r = Math.min(cw, ch) / 2 - Style.spaceReal(2)
    var cx = cw / 2, cy = ch / 2
    ctx.clearRect(0, 0, cw, ch)

    var info = root.moon
    if (!info) return

    ctx.beginPath()
    ctx.arc(cx, cy, r, 0, 2 * Math.PI, false)
    ctx.lineWidth = 1
    ctx.strokeStyle = Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.28)
    ctx.stroke()

    ctx.save()
    ctx.translate(cx, cy)

    var lit = Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.92)
    var dark = Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.14)
    var k = Math.max(0, Math.min(1, info.illumination))
    var term = Math.abs(2 * k - 1) * r

    // Full disc first — lit when more than half lit, dark otherwise…
    ctx.beginPath()
    ctx.arc(0, 0, r, 0, 2 * Math.PI, false)
    ctx.fillStyle = (2 * k - 1) >= 0 ? lit : dark
    ctx.fill()

    // …then the lens between the limb and the elliptical terminator, built
    // from sampled points (Canvas ellipse() draws a disconnected blob, so it's
    // not used here). The overlay hugs the lit side on crescents and the
    // dark side past half, growing to nothing at new/full moon.
    var litRight = info.waxing
    var shade = (2 * k - 1) >= 0
    var side = litRight ? 1 : -1
    var overlay = shade ? -side : side
    var n = 48

    ctx.beginPath()
    ctx.moveTo(0, r)
    for (var i = 1; i <= n; i++) {
      var a = Math.PI / 2 + i / n * Math.PI * (overlay > 0 ? -1 : 1)
      ctx.lineTo(r * Math.cos(a), r * Math.sin(a))
    }
    for (var j = 0; j <= n; j++) {
      var b = -Math.PI / 2 + j / n * Math.PI * (overlay > 0 ? 1 : -1)
      ctx.lineTo(term * Math.cos(b), r * Math.sin(b))
    }
    ctx.closePath()
    ctx.fillStyle = shade ? dark : lit
    ctx.fill()

    ctx.restore()
  }

  function recomputeCurve() {
    root.curveSamples = Model.phaseSamples(root.timeline, root.extremes, root.nowMs, 6, 18)
    root.phaseExtremes = Model.extremesBetween(root.extremes, root.nowMs - 6 * 3600 * 1000, root.nowMs + 18 * 3600 * 1000)
  }

  function loadCaches() {
    extremesCacheFile.reload()
    timelineCacheFile.reload()
  }

  function clearData() {
    root.extremesRetries = 0
    root.timelineRetries = 0
    root.dataFailed = false
    root.extremes = []
    root.timeline = []
    root.sunTimes = null
    root.dataLoaded = false
    root.tick()
  }

  // Re-points the caches at the active location and — only when the location
  // actually changed — refetches. The persisted file and the in-memory state
  // can converge to an equal value, so cheap identical-key reloads are the
  // norm and refetches the exception.
  function applyLocation() {
    var key = root.hasLocation
      ? String(root.configuredLocationState.latitude) + "," + String(root.configuredLocationState.longitude)
      : ""
    root.cacheSlug = root.hasLocation ? Model.locationSlug(root.configuredLocationState.name) : "nolocation"

    if (key === root.appliedLocationKey) {
      root.loadCaches()
      return
    }
    root.appliedLocationKey = key
    root.clearData()
    if (!root.hasLocation) return
    root.loadCaches()
    root.refresh()
  }

  function refresh() {
    if (!root.hasLocation) return
    root.tick()
    extremesProc.command = root.fetchCommand(root.extremesBaseUrl, root.extremesCachePath, 24, 72)
    timelineProc.command = root.fetchCommand(root.timelineBaseUrl, root.timelineCachePath, 12, 36)
    if (!extremesProc.running) extremesProc.running = true
    if (!timelineProc.running) timelineProc.running = true
    root.fetchSun()
  }

  function onExtremesFetched(raw) {
    var parsed = Model.parseExtremes(raw)
    if (parsed.length === 0) {
      if (root.extremesRetries < 3) { root.extremesRetries++; extremesRetryTimer.restart() }
      else if (root.hasLocation) root.dataFailed = true
      return
    }
    root.extremesRetries = 0
    root.dataFailed = false
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
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
    if (!root.hasLocation) {
      // No place picked yet — put the search box in front.
      Qt.callLater(root.startEditingLocation)
      return
    }
    root.loadCaches()
    root.refresh()
  }

  function close() {
    if (root.editingLocation) root.cancelEditingLocation()
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

  // ---- Location editing. One tap on the location row swaps it for a live
  //      search field; picking a geocoded suggestion persists name +
  //      coordinates and triggers the refetch for that place.
  function startEditingLocation() {
    root.editingLocation = true
    root.locationSuggestions = []
    root.suggestionIndex = 0
    Qt.callLater(function() {
      if (!locationField) return
      locationField.text = root.hasLocation ? root.configuredLocationState.name : ""
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    root.editingLocation = false
    root.locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Enter with a highlighted suggestion commits; typing with no matches just
  // cancels back to the previous location rather than clearing it.
  function commitLocation() {
    var location = Model.locationCommit(locationField.text, root.locationSuggestions, root.suggestionIndex)
    if (location.name === "") { root.cancelEditingLocation(); return }
    root.forceLocation(location)
  }

  function pickSuggestion(suggestion) {
    if (suggestion) root.forceLocation(suggestion)
  }

  function forceLocation(location) {
    root.configuredLocationState = {
      name: String(location.name || ""),
      latitude: location.latitude === undefined || location.latitude === null ? null : Number(location.latitude),
      longitude: location.longitude === undefined || location.longitude === null ? null : Number(location.longitude)
    }
    root.persistLocation()
  }

  function clearLocation() {
    root.configuredLocationState = { name: "", latitude: null, longitude: null }
    root.persistLocation()
    root.cancelEditingLocation()
  }

  function persistLocation() {
    locationSaveProc.command = ["bash", "-c",
      "mkdir -p \"$0\" && printf '%s' \"$1\" > \"$2\"",
      root.settingsDir,
      JSON.stringify(root.configuredLocationState),
      root.locationFilePath]
    locationSaveProc.running = true
  }

  // Debounced lookups. One curl at a time; if the query moved on while a
  // fetch was in flight, the latest query runs right after.
  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) { root.locationSuggestions = []; return }
    root.geocodePendingQuery = query
    if (!geocodeProc.running) root.startGeocode()
  }

  function startGeocode() {
    root.geocodeActiveQuery = root.geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(root.geocodePendingQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  onConfiguredLocationStateChanged: {
    root.editingLocation = false
    root.locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    root.applyLocation()
    Qt.callLater(function() { if (moonCanvas) moonCanvas.requestPaint() })
  }

  onNowMsChanged: {
    root.recomputeCurve()
    if (moonCanvas) moonCanvas.requestPaint()
  }
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
  //      refreshed by every successful fetch. Keyed per location (cacheSlug).

  FileView {
    id: extremesCacheFile
    path: root.extremesCachePath
    watchChanges: false
    printErrors: false
    onLoaded: {
      var parsed = Model.parseExtremes(text())
      if (parsed.length > 0) { root.extremes = parsed; root.dataLoaded = true }
    }
  }

  FileView {
    id: timelineCacheFile
    path: root.timelineCachePath
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
  readonly property string extremesBaseUrl: root.hasLocation
    ? "https://api.openwaters.io/tides/extremes?latitude=" + encodeURIComponent(String(root.configuredLocationState.latitude))
      + "&longitude=" + encodeURIComponent(String(root.configuredLocationState.longitude))
      + "&units=meters"
    : ""
  readonly property string timelineBaseUrl: root.hasLocation
    ? "https://api.openwaters.io/tides/timeline?latitude=" + encodeURIComponent(String(root.configuredLocationState.latitude))
      + "&longitude=" + encodeURIComponent(String(root.configuredLocationState.longitude))
    : ""

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
      if (!root.hasLocation) return
      extremesProc.command = root.fetchCommand(root.extremesBaseUrl, root.extremesCachePath, 24, 72)
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
      if (!root.hasLocation) return
      timelineProc.command = root.fetchCommand(root.timelineBaseUrl, root.timelineCachePath, 12, 36)
      if (!timelineProc.running) timelineProc.running = true
    }
  }

  // ---- Sunrise / sunset (Open-Meteo daily API).  Fetched once per location
  //      change; the response covers today so a single call suffices.
  readonly property string sunUrl: root.hasLocation
    ? "https://api.open-meteo.com/v1/forecast?latitude=" + encodeURIComponent(String(root.configuredLocationState.latitude))
      + "&longitude=" + encodeURIComponent(String(root.configuredLocationState.longitude))
      + "&daily=sunrise,sunset&timezone=auto&forecast_days=1"
    : ""

  function fetchSun() {
    if (!root.hasLocation) return
    sunProc.command = ["bash", "-c",
      "tmp=\"$0.$$.tmp\"\n" +
      "curl -fsS --max-time 5 \"" + root.sunUrl + "\" -o \"$tmp\" || { rm -f \"$tmp\"; exit 1; }\n" +
      "cat \"$tmp\" && rm -f \"$tmp\"",
      root.settingsDir + "/gnosis-tide-" + root.cacheSlug + "-sun.json"]
    if (!sunProc.running) sunProc.running = true
  }

  Process {
    id: sunProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.sunTimes = Model.parseSunTimes(text) }
    }
  }

  // ---- Persisted location. watchChanges keeps the shell and any external
  //      editor (or another plugin instance) in sync.
  property FileView locationFile: FileView {
    path: root.locationFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configuredLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.configuredLocationState = Model.parseLocationFile("")
  }

  // The first read can race plugin load (observed in the weather panel); one
  // delayed reload self-corrects.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode === 0) locationFile.reload()
    }
  }

  // ---- Live location lookup (open-meteo geocoding) with a short debounce.
  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Component.onCompleted: {
    root.tick()
    root.recomputeCurve()
    root.loadCaches()
    locationFile.reload()
    Qt.callLater(root.applyLocation)
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
            height: Math.max(lunarBlock.implicitHeight, headRight.implicitHeight)

            Row {
              id: lunarBlock
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Canvas {
                id: moonCanvas
                width: Style.space(76)
                height: width
                onPaint: root.paintMoon(getContext("2d"))
                Component.onCompleted: requestPaint()
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  text: root.moonPhase
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.6
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: Style.space(300)
                  text: root.moonSubline
                  color: Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }
            }

            Column {
              id: headRight
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: root.stateText
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
                font.bold: true
              }
            }
          }

          // ---- Location: the current place, or the live search box that replaces
          //      it. The hero's big next-event time is gone — the pill, wave,
          //      gauge and COMING UP list carry that now.
          Item {
            id: locationRoot
            width: parent.width
            height: root.editingLocation ? locationEditor.implicitHeight : locationBar.implicitHeight

            Row {
              id: locationBar
              visible: !root.editingLocation
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Column {
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: root.displayLocationName === ""
                    ? "SEARCH FOR A LOCATION"
                    : root.displayLocationName.toUpperCase()
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  font.letterSpacing: 0.8
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.displayLocationName === ""
                    ? "Tap to find a coastal place for its tide times"
                    : "TAP TO CHANGE LOCATION"
                  color: Qt.darker(root.contentForeground, 1.7)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1.1
                }
              }
            }

            Column {
              id: locationEditor
              visible: root.editingLocation
              anchors.left: parent.left
              anchors.leftMargin: root.contentInset
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              TextField {
                id: locationField
                width: parent.width
                placeholderText: "Search for a location…"
                foreground: root.contentForeground
                accent: Color.accent
                font.family: root.contentFontFamily

                onTextChanged: if (root.editingLocation) geocodeDebounce.restart()

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelEditingLocation(); event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    if (root.suggestionIndex > 0) root.suggestionIndex--
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitLocation(); event.accepted = true
                  }
                }
              }

              Column {
                width: parent.width
                spacing: 0
                visible: root.locationSuggestions.length > 0

                Repeater {
                  model: root.locationSuggestions

                  Rectangle {
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: suggestionRow.implicitHeight + Style.space(10)
                    radius: Style.cornerRadius
                    color: index === root.suggestionIndex
                      ? Style.hoverFillFor(root.contentForeground, Color.accent)
                      : "transparent"

                    Row {
                      id: suggestionRow
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(8)

                      Text {
                        textFormat: Text.PlainText
                        text: modelData.name
                        color: index === root.suggestionIndex
                          ? Style.hoverStateColor(root.contentForeground, Color.accent)
                          : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        textFormat: Text.PlainText
                        visible: text !== ""
                        text: modelData.description
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: root.suggestionIndex = index
                      onClicked: root.pickSuggestion(modelData)
                    }
                  }
                }
              }

              Text {
                visible: locationField.text.trim().length >= 2 && root.locationSuggestions.length === 0
                text: "No coastal matches — try another place."
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }
            }

            MouseArea {
              anchors.fill: parent
              visible: !root.editingLocation
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.startEditingLocation()
            }
          }

          // ---- Shown briefly when a picked place has no tide data.
          Text {
            visible: root.hasLocation && !root.dataLoaded && root.dataFailed
            width: parent.width - root.contentInset * 2
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No tide data for this location — try a nearby coastline."
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Tide phase: a rolling wave chart with a clear NOW marker,
          //      plus a water gauge showing where now sits on the tide.
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.hasLocation

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
              readonly property real padT: Style.spaceReal(22)
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
                  out.push({ x: tx, label: Model.formatTime(ms + o * 3600 * 1000), now: o === 0 })
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

              // ---- grid: three faint horizontal level lines (no labels —
              //      the LOW/HIGH captions below carry the meter values).
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

              // ---- high/low event markers: compact ▲/▼ badges sitting on the
              //      curve. Exact times live on the bottom axis and in the
              //      LOW/HIGH captions, so nothing floats into the NOW zone
              //      or overlaps the time ticks.
              Repeater {
                model: wave.marks
                delegate: Item {
                  required property var modelData
                  Rectangle {
                    x: parent.modelData.x - Style.spaceReal(7.5)
                    y: parent.modelData.y - Style.spaceReal(7.5)
                    width: Style.spaceReal(15)
                    height: Style.spaceReal(15)
                    radius: width / 2
                    color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.92)
                    border.width: 1
                    border.color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.4)
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: parent.modelData.high ? "▲" : "▼"
                    color: parent.modelData.high ? wave.lineColor : Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.7)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.spaceReal(9)
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

              // ---- NOW chip: label anchored to the dot, clamped inside the
              //      plot so it never overlaps the edge labels or the event
              //      marker labels.
              Item {
                x: Math.min(
                  Math.max(wave.xNow + Style.spaceReal(10), wave.x0 + Style.spaceReal(2)),
                  wave.x1 - nowChip.implicitWidth - Style.spaceReal(2))
                y: Math.min(
                  Math.max(wave.yNow - nowChip.implicitHeight / 2, wave.yTop + Style.spaceReal(2)),
                  wave.yBase - nowChip.implicitHeight - Style.spaceReal(2))
                visible: !isNaN(wave.yNow)

                Rectangle {
                  id: nowChip
                  width: nowChipLabel.implicitWidth + Style.spaceReal(12)
                  height: nowChipLabel.implicitHeight + Style.spaceReal(5)
                  radius: Style.spaceReal(3)
                  color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.92)
                  border.width: 1
                  border.color: Qt.rgba(wave.lineColor.r, wave.lineColor.g, wave.lineColor.b, 0.4)

                  Text {
                    id: nowChipLabel
                    anchors.centerIn: parent
                    text: "NOW"
                    color: wave.lineColor
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.spaceReal(10)
                    font.bold: true
                  }
                }
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

          // ---- Bottom row: upcoming events (left) and the sunrise/sunset
          //      arc (right), both aligned to the same content insets.
          Item {
            width: parent.width
            height: Math.max(comingUpCol.implicitHeight, sunCol.implicitHeight)
            visible: root.hasLocation

            // ---- Upcoming events.
            Column {
              id: comingUpCol
              x: root.contentInset
              anchors.top: parent.top
              width: Style.space(180)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
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
                  width: comingUpCol.width
                  height: Style.space(24)

                  readonly property bool firstRow: index === 0
                  readonly property color rowForeground: firstRow ? root.contentForeground : Qt.darker(root.contentForeground, 1.35)
                  readonly property color rowAccent: firstRow ? Color.accent : Qt.darker(Color.accent, 1.15)

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(100)
                    text: Model.formatDayTime(modelData.ms)
                    color: parent.rowForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: parent.firstRow
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(102)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(16)
                    text: Model.arrow(modelData)
                    color: parent.rowAccent
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(124)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(52)
                    text: Model.heightText(modelData.level)
                    color: parent.rowForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }

            // ---- Sun: sunrise/sunset arc filling the lower-right corner,
            //      drawn in the same style as the tide wave.
            Column {
              id: sunCol
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.rightMargin: root.contentInset
              width: parent.width - root.contentInset * 2 - comingUpCol.width - Style.space(24)
              spacing: Style.space(8)

              // ---- Daylight header, matching the other section headers.
              Text {
                textFormat: Text.PlainText
                text: "DAYLIGHT"
                color: Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
                font.bold: true
              }

              // ---- Sun arc chart.
              Item {
                id: sunChart
                width: parent.width
                height: Style.space(110)
                visible: root.sunTimes !== null

                readonly property real x0: Style.spaceReal(2)
                readonly property real x1: sunChart.width - Style.spaceReal(2)
                readonly property real yTop: Style.spaceReal(14)
                readonly property real yBase: sunChart.height - Style.spaceReal(24)
                readonly property color lineColor: Color.accent

                readonly property real dayStart: (function() {
                  var r = root.sunTimes
                  if (!r) return 0
                  var d = new Date(r.rise)
                  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
                })()

                readonly property real dayEnd: (function() {
                  var r = root.sunTimes
                  if (!r) return 0
                  return sunChart.dayStart + 24 * 3600 * 1000
                })()

                function xx(t) {
                  return sunChart.x0 + (t - sunChart.dayStart) / (sunChart.dayEnd - sunChart.dayStart) * (sunChart.x1 - sunChart.x0)
                }

                function yOf(lv) {
                  return sunChart.yBase - lv * (sunChart.yBase - sunChart.yTop)
                }

                // 0 before rise and after set; a sine half-wave in between.
                function elevationAt(t) {
                  var r = root.sunTimes
                  if (!r) return 0
                  if (t < r.rise || t > r.set) return 0
                  var p = (t - r.rise) / (r.set - r.rise)
                  return Math.sin(Math.PI * Math.max(0, Math.min(1, p)))
                }

                readonly property var arc: (function() {
                  var r = root.sunTimes
                  var pts = []
                  for (var t = sunChart.dayStart; t <= sunChart.dayEnd; t += 30 * 60 * 1000)
                    pts.push(Qt.point(sunChart.xx(t), sunChart.yOf(sunChart.elevationAt(t))))
                  return pts
                })()

                readonly property var arcArea: (function() {
                  var r = root.sunTimes
                  var pts = sunChart.arc.slice(0)
                  pts.push(Qt.point(sunChart.x1, sunChart.yBase))
                  pts.push(Qt.point(sunChart.x0, sunChart.yBase))
                  return pts
                })()

                readonly property real xNow: (function() {
                  var r = root.sunTimes
                  if (!r) return sunChart.x0
                  var t = Math.max(sunChart.dayStart, Math.min(root.nowMs, sunChart.dayEnd))
                  return sunChart.xx(t)
                })()

                readonly property real yNow: (function() {
                  var r = root.sunTimes
                  if (!r) return sunChart.yBase
                  return sunChart.yOf(sunChart.elevationAt(root.nowMs))
                })()

                readonly property real xRise: (function() {
                  var r = root.sunTimes
                  return r ? sunChart.xx(r.rise) : sunChart.x0
                })()

                readonly property real xSet: (function() {
                  var r = root.sunTimes
                  return r ? sunChart.xx(r.set) : sunChart.x1
                })()

                // ---- night shading on either side of the daylight arc.
                Rectangle {
                  x: sunChart.x0
                  y: sunChart.yTop
                  width: Math.max(0, sunChart.xRise - sunChart.x0)
                  height: sunChart.yBase - sunChart.yTop
                  color: Qt.rgba(0, 0, 0, 0.05)
                }

                Rectangle {
                  x: sunChart.xSet
                  y: sunChart.yTop
                  width: Math.max(0, sunChart.x1 - sunChart.xSet)
                  height: sunChart.yBase - sunChart.yTop
                  color: Qt.rgba(0, 0, 0, 0.05)
                }

                Shape {
                  anchors.fill: parent
                  antialiasing: true

                  ShapePath {
                    strokeColor: "transparent"
                    fillGradient: LinearGradient {
                      x1: 0
                      y1: sunChart.yTop
                      x2: 0
                      y2: sunChart.yBase
                      GradientStop {
                        position: 0
                        color: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.03)
                      }
                      GradientStop {
                        position: 0.55
                        color: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.14)
                      }
                      GradientStop {
                        position: 1
                        color: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.30)
                      }
                    }
                    PathPolyline { path: sunChart.arcArea }
                  }

                  ShapePath {
                    strokeColor: sunChart.lineColor
                    strokeWidth: 1.9
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathPolyline { path: sunChart.arc }
                  }

                  ShapePath {
                    strokeColor: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.18)
                    strokeWidth: 1
                    startX: sunChart.x0
                    startY: sunChart.yBase
                    PathLine { x: sunChart.x1; y: sunChart.yBase }
                  }
                }

                // ---- sunrise / sunset boundary hairlines. The times are
                //      read straight off the chart, tagged at the top of
                //      each line like axis values. Dashed to tell them apart
                //      from the solid NOW hairline.
                Shape {
                  anchors.fill: parent
                  antialiasing: true
                  ShapePath {
                    strokeColor: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.55)
                    strokeWidth: 1
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [3, 3]
                    startX: sunChart.xRise
                    startY: sunChart.yTop
                    PathLine { x: sunChart.xRise; y: sunChart.yBase }
                  }
                }

                Shape {
                  anchors.fill: parent
                  antialiasing: true
                  ShapePath {
                    strokeColor: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.55)
                    strokeWidth: 1
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [3, 3]
                    startX: sunChart.xSet
                    startY: sunChart.yTop
                    PathLine { x: sunChart.xSet; y: sunChart.yBase }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  x: Math.max(sunChart.x0, Math.min(sunChart.xRise - implicitWidth / 2, sunChart.x1 - implicitWidth))
                  y: sunChart.yTop
                  text: root.sunTimes ? Model.formatTime(root.sunTimes.rise) : ""
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.spaceReal(10)
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  x: Math.max(sunChart.x0, Math.min(sunChart.xSet - implicitWidth / 2, sunChart.x1 - implicitWidth))
                  y: sunChart.yTop
                  text: root.sunTimes ? Model.formatTime(root.sunTimes.set) : ""
                  color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.spaceReal(10)
                  font.bold: true
                }

                // ---- NOW marker.
                Rectangle {
                  x: sunChart.xNow - width / 2
                  y: sunChart.yTop
                  width: 1
                  height: sunChart.yBase - sunChart.yTop
                  color: Qt.rgba(sunChart.lineColor.r, sunChart.lineColor.g, sunChart.lineColor.b, 0.28)
                }

                Rectangle {
                  x: sunChart.xNow - Style.spaceReal(4.4)
                  y: sunChart.yNow - Style.spaceReal(4.4)
                  width: Style.spaceReal(8.8)
                  height: Style.spaceReal(8.8)
                  radius: width / 2
                  color: sunChart.lineColor
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
                text: root.displayLocationName === ""
                  ? "TIDE DATA"
                  : root.displayLocationName.toUpperCase()
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