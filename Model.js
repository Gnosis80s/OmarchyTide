// Tide data helpers for the Omarchy tide plugin.
//
// Data comes from the Open Waters tide API (openwaters.io/tides), keyed by the
// latitude/longitude of the location the user picked in the search box. The
// API resolves to the nearest reference station with published harmonic
// constituents, so predictions hold for the chosen place. Extremes give timed
// high/low events; the timeline gives a 10-minute level series used for the
// tide curve. When the timeline is unavailable the curve is approximated by
// sine interpolation between neighbouring extremes.

function now() {
  return new Date()
}

function toMs(value) {
  if (typeof value === "number") return value
  var t = new Date(value)
  return isNaN(t.getTime()) ? NaN : t.getTime()
}

function parseExtremes(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var list = data && data.extremes
    if (!Array.isArray(list)) return []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var ms = toMs(list[i].time)
      if (isNaN(ms)) continue
      out.push({ ms: ms, level: Number(list[i].level), high: !!list[i].high, low: !!list[i].low })
    }
    out.sort(function(a, b) { return a.ms - b.ms })
    return out
  } catch (e) {
    return []
  }
}

function parseTimeline(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var list = data && data.timeline
    if (!Array.isArray(list)) return []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var ms = toMs(list[i].time)
      if (isNaN(ms)) continue
      out.push({ ms: ms, level: Number(list[i].level) })
    }
    out.sort(function(a, b) { return a.ms - b.ms })
    return out
  } catch (e) {
    return []
  }
}

function firstAfter(list, ms) {
  if (!list) return null
  for (var i = 0; i < list.length; i++) {
    if (list[i].ms > ms) return list[i]
  }
  return null
}

function firstBeforeOrAt(list, ms) {
  var last = null
  if (!list) return last
  for (var i = 0; i < list.length; i++) {
    if (list[i].ms <= ms) last = list[i]
    else break
  }
  return last
}

function firstHighAfter(list, ms) {
  if (!list) return null
  for (var i = 0; i < list.length; i++) {
    if (list[i].ms > ms && list[i].high) return list[i]
  }
  return null
}

function firstLowAfter(list, ms) {
  if (!list) return null
  for (var i = 0; i < list.length; i++) {
    if (list[i].ms > ms && list[i].low) return list[i]
  }
  return null
}

function nextWindow(list, ms, count) {
  var out = []
  if (!list) return out
  for (var i = 0; i < list.length && out.length < count; i++) {
    if (list[i].ms > ms) out.push(list[i])
  }
  return out
}

// Approximate height at any instant by easing sinusoidally between the two
// surrounding extremes. Only used when the live timeline is unavailable.
function levelAtSynth(list, ms) {
  if (!list || list.length === 0) return NaN
  var prev = firstBeforeOrAt(list, ms)
  var next = firstAfter(list, ms)
  if (!prev && !next) return NaN
  if (!prev) return next.level
  if (!next) return prev.level
  var span = next.ms - prev.ms
  if (span <= 0) return next.level
  var f = (ms - prev.ms) / span
  if (f < 0) f = 0
  if (f > 1) f = 1
  var d = next.level - prev.level
  return prev.level + d * (1 - Math.cos(Math.PI * f)) / 2
}

function levelAtTimeline(timeline, ms) {
  var prev = null
  for (var i = 0; i < timeline.length; i++) {
    if (timeline[i].ms <= ms) prev = timeline[i]
    else {
      var next = timeline[i]
      var span = next.ms - prev.ms
      if (span <= 0) return prev.level
      var f = (ms - prev.ms) / span
      return prev.level + (next.level - prev.level) * f
    }
  }
  return prev ? prev.level : NaN
}

// Current sea level: interpolated exactly at `ms` from the two surrounding
// timeline samples (live and smooth), else the sinusoidal estimate from
// extremes, else null.
function currentLevel(timeline, extremes, ms) {
  if (timeline && timeline.length > 1 && ms >= timeline[0].ms && ms <= timeline[timeline.length - 1].ms) {
    var prev = firstBeforeOrAt(timeline, ms)
    var next = firstAfter(timeline, ms)
    if (prev && next && next.ms > prev.ms) {
      var span = next.ms - prev.ms
      var f = Math.max(0, Math.min(1, (ms - prev.ms) / span))
      return { level: prev.level + (next.level - prev.level) * f, synced: true }
    }
    if (prev) return { level: prev.level, synced: true }
  }
  var v = levelAtSynth(extremes, ms)
  if (!isNaN(v)) return { level: v, synced: false }
  return null
}

// Samples for the tide curve. Prefers the live timeline when it spans the
// window; otherwise synthesises from extremes. Steps every 15 minutes.
function windowSamples(timeline, extremes, ms, hoursAhead) {
  var step = 15 * 60 * 1000
  var end = ms + hoursAhead * 3600 * 1000
  var out = []
  var useTimeline = timeline && timeline.length > 1
    && timeline[0].ms <= ms
    && timeline[timeline.length - 1].ms > end
  for (var t = ms; t <= end; t += step) {
    var level = useTimeline ? levelAtTimeline(timeline, t) : levelAtSynth(extremes, t)
    if (!isNaN(level)) out.push({ ms: t, level: level, live: useTimeline })
  }
  return out
}

// Rolling window for the phase chart: past and future, so the shape of the
// tide wave and where now sits on it are easy to read.
function phaseSamples(timeline, extremes, ms, hoursBack, hoursAhead) {
  var step = 15 * 60 * 1000
  var start = ms - hoursBack * 3600 * 1000
  var end = ms + hoursAhead * 3600 * 1000
  var out = []
  var useTimeline = timeline && timeline.length > 1
    && timeline[0].ms <= start
    && timeline[timeline.length - 1].ms >= end
  for (var t = start; t <= end; t += step) {
    var level = useTimeline ? levelAtTimeline(timeline, t) : levelAtSynth(extremes, t)
    if (!isNaN(level)) out.push({ ms: t, level: level, live: useTimeline })
  }
  return out
}

// Extremes that fall inside a window, for markers on the phase chart.
function extremesBetween(list, fromMs, toMs) {
  var out = []
  if (!list) return out
  for (var i = 0; i < list.length; i++) {
    if (list[i].ms >= fromMs && list[i].ms <= toMs) out.push(list[i])
  }
  return out
}

// Current level interpolated from the sample series at an exact instant.
function levelAtSamples(samples, ms) {
  if (!samples || samples.length === 0) return NaN
  if (ms <= samples[0].ms) return samples[0].level
  for (var i = 0; i < samples.length; i++) {
    if (samples[i].ms >= ms) {
      var prev = samples[i - 1] || samples[i]
      var span = samples[i].ms - prev.ms
      if (span <= 0) return samples[i].level
      var f = (ms - prev.ms) / span
      return prev.level + (samples[i].level - prev.level) * f
    }
  }
  return samples[samples.length - 1].level
}

// Position of the current level between the flanking extremes of the present
// half-cycle — the values that drive the water gauge. fraction is 0.0 at low
// water and 1.0 at high water, whether the tide is rising or falling.
function flanking(extremes, ms, level) {
  if (!extremes || extremes.length < 2 || isNaN(level)) return null
  var prev = firstBeforeOrAt(extremes, ms)
  var next = firstAfter(extremes, ms)
  if (!prev || !next) return null
  var lowLv = Math.min(prev.level, next.level)
  var highLv = Math.max(prev.level, next.level)
  var span = highLv - lowLv
  if (span <= 0) return null
  return {
    rising: next.level > prev.level,
    fraction: Math.max(0, Math.min(1, (level - lowLv) / span)),
    low: prev.level < next.level ? prev : next,
    high: prev.level < next.level ? next : prev,
    fromMs: prev.ms,
    toMs: next.ms,
    level: level
  }
}

function two(n) {
  return (n < 10 ? "0" : "") + n
}

function formatTime(ms) {
  var d = new Date(ms)
  return two(d.getHours()) + ":" + two(d.getMinutes())
}

function dayShort(ms) {
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][new Date(ms).getDay()]
}

function formatDayTime(ms) {
  return dayShort(ms) + " " + formatTime(ms)
}

function heightText(level) {
  if (level === undefined || level === null || isNaN(level)) return "—"
  return Number(level).toFixed(1) + " m"
}

function arrow(event) {
  return event && event.high ? "▲" : "▼"
}

function tideState(event) {
  return event ? (event.high ? "RISING" : "FALLING") : ""
}

function barLabel(extremes, ms, loaded) {
  var next = firstAfter(extremes, ms)
  if (next) return arrow(next) + " " + formatTime(next.ms)
  return loaded ? "" : "…"
}

// Location state file: JSON { name, latitude, longitude }; tolerant of an
// absent or corrupt file.
function parseLocationFile(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var name = String(data.name || "").trim()
    var lat = Number(data.latitude)
    var lon = Number(data.longitude)
    return {
      name: name,
      latitude: isNaN(lat) ? null : lat,
      longitude: isNaN(lon) ? null : lon
    }
  } catch (e) {
    return { name: "", latitude: null, longitude: null }
  }
}

// Filesystem-safe slug for the per-location cache filenames.
function locationSlug(name) {
  var s = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  return s === "" ? "nolocation" : s
}

// Open-Meteo geocoding response → pickable rows for the search box.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var results = data.results
    if (!results || !results.length) return []
    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Commit from the search box: only a real geocoded pick is valid, since a
// location without coordinates cannot be resolved to tides.
function locationCommit(text, suggestions, selectedIndex) {
  var choices = suggestions || []
  if (!choices.length) return { name: "", latitude: null, longitude: null }
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  return choices[index]
}

if (typeof module !== "undefined") {
  module.exports = {
    now: now,
    toMs: toMs,
    parseExtremes: parseExtremes,
    parseTimeline: parseTimeline,
    firstAfter: firstAfter,
    firstBeforeOrAt: firstBeforeOrAt,
    firstHighAfter: firstHighAfter,
    firstLowAfter: firstLowAfter,
    nextWindow: nextWindow,
    currentLevel: currentLevel,
    windowSamples: windowSamples,
    phaseSamples: phaseSamples,
    extremesBetween: extremesBetween,
    levelAtSamples: levelAtSamples,
    flanking: flanking,
    formatTime: formatTime,
    dayShort: dayShort,
    formatDayTime: formatDayTime,
    heightText: heightText,
    arrow: arrow,
    tideState: tideState,
    barLabel: barLabel,
    parseLocationFile: parseLocationFile,
    locationSlug: locationSlug,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit
  }
}