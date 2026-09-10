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

// ---- Lunar geometry (low-precision Meeus; plenty for a widget moon).

function _rad(d) { return d * Math.PI / 180 }
function _deg(r) { return r * 180 / Math.PI }
function _wrap360(d) { return ((d % 360) + 360) % 360 }

function _vec3(ra, dec) {
  return [Math.cos(dec) * Math.cos(ra), Math.cos(dec) * Math.sin(ra), Math.sin(dec)]
}

function _dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

function _eclToEqu(lamDeg, betDeg, epsDeg) {
  var l = _rad(lamDeg), b = _rad(betDeg), e = _rad(epsDeg)
  var cosb = Math.cos(b)
  var x = Math.cos(l) * cosb
  var y = Math.sin(l) * cosb
  var z = Math.sin(b)
  var ye = y * Math.cos(e) - z * Math.sin(e)
  var ze = y * Math.sin(e) + z * Math.cos(e)
  return { ra: Math.atan2(ye, x), dec: Math.asin(ze) }
}

// Geocentric apparent Sun. Returns RA/Dec in radians.
function _sunEquatorial(T) {
  var L = _wrap360(280.46646 + 36000.76983 * T + 0.0003032 * T * T)
  var M = _wrap360(357.52911 + 35999.05029 * T - 0.0001537 * T * T)
  var C = (1.914602 - 0.004817 * T - 0.000014 * T * T) * Math.sin(_rad(M))
    + (0.019993 - 0.000101 * T) * Math.sin(_rad(2 * M)) + 0.000289 * Math.sin(_rad(3 * M))
  var omega = _wrap360(125.04 - 1934.136 * T)
  var lam = _wrap360(L + C - 0.00569 - 0.00478 * Math.sin(_rad(omega)))
  var eps = _obliq(T)
  return _eclToEqu(lam, 0, eps)
}

function _obliq(T) {
  return 23.4392911 - 0.0130042 * T
}

// Geocentric apparent Moon via the low-precision lunar theory. Returns
// RA/Dec in radians.
function _moonEquatorial(T) {
  var Lp = _wrap360(218.3164477 + 481267.88123421 * T - 0.0015786 * T * T + T * T * T / 538841)
  var D = _wrap360(297.8501921 + 445267.1114034 * T - 0.0018819 * T * T)
  var M = _wrap360(357.5291092 + 35999.0502909 * T - 0.0001536 * T * T)
  var Mp = _wrap360(134.9633964 + 477198.8675055 * T + 0.0087414 * T * T)
  var F = _wrap360(93.2720950 + 483202.0175233 * T - 0.0036539 * T * T)
  var E = 1 - 0.002516 * T - 0.0000074 * T * T

  // [dD, dM, dMp, dF, arcsec-e6-of-degree amplitude] — principal longitude terms.
  var lterms = [
    [0, 0, 1, 0, 6288774], [2, 0, -1, 0, 1274027], [2, 0, 0, 0, 658314],
    [0, 0, 2, 0, 213618], [0, 1, 0, 0, -185116], [0, 0, 0, 2, -114332],
    [2, 0, -2, 0, 58793], [2, -1, -1, 0, 57066], [2, 0, 1, 0, 53322],
    [2, -1, 0, 0, 45758], [0, 1, -1, 0, -40923], [1, 0, 0, 0, -34720],
    [0, 1, 1, 0, -30383], [2, 0, -2, 2, 15327], [0, 0, 2, 2, -12528],
    [0, 0, -2, 2, 10980], [4, 0, -1, 0, 10675], [0, 0, 3, 0, 10034],
    [4, 0, -2, 0, 8548], [2, 1, -1, 0, -7888], [2, 1, 0, 0, -6766],
    [1, 0, -1, 0, -5163], [1, 0, 1, 0, 4987], [2, -1, 1, 0, 4036],
    [2, 0, 2, 0, 3994], [4, 0, 0, 0, 3861], [2, 0, -3, 0, 3665],
    [0, 1, -2, 0, -2689], [2, 0, -1, 2, -2602], [2, 0, -1, -2, 2390]
  ]
  var dLambda = 0
  for (var li = 0; li < lterms.length; li++) {
    var lt = lterms[li], m2 = Math.abs(lt[1])
    var f = 1
    if (m2 === 1) f = E
    else if (m2 >= 2) f = E * E
    dLambda += f * lt[4] * Math.sin(_rad(lt[0] * D + lt[1] * M + lt[2] * Mp + lt[3] * F))
  }

  // Principal latitude terms.
  var bterms = [
    [0, 0, 0, 1, 5128122], [0, 0, 1, 1, 280602], [0, 0, 1, -1, 277693],
    [2, 0, 0, -1, 173237], [2, 0, -1, 1, 55413], [2, 0, -1, -1, 46271],
    [2, 0, 0, 1, 32573], [0, 0, 2, 1, 17198], [2, 0, 1, -1, 9266],
    [0, 0, 2, -1, 8822], [2, -1, 0, -1, 8216], [2, 0, -2, -1, 4324],
    [2, 0, 1, 1, 4200], [2, 1, 0, -1, -3359], [2, -1, -1, 1, 2463],
    [2, -1, 0, 1, 2211], [2, -1, -1, -1, 2065], [0, 1, -1, -1, -1870]
  ]
  var dBeta = 0
  for (var bi = 0; bi < bterms.length; bi++) {
    var bt = bterms[bi], em = Math.abs(bt[1])
    var ef = 1
    if (em === 1) ef = E
    else if (em >= 2) ef = E * E
    dBeta += ef * bt[4] * Math.sin(_rad(bt[0] * D + bt[1] * M + bt[2] * Mp + bt[3] * F))
  }

  var lam = _wrap360(Lp + dLambda / 1000000)
  var bet = dBeta / 1000000
  return _eclToEqu(lam, bet, _obliq(T))
}

// Lunar phase. The phase itself is global, so no observer coordinates are
// needed. Returns the synodic-month age in days, the illuminated fraction,
// the eight-bin phase name, and which side of the disc is lit (waxing leans
// right, waning left — the classic flat phase graphic).
function moonInfo(ms) {
  var i = typeof ms === "number" ? ms : (new Date()).getTime()

  var synodic = 29.530588853 * 24 * 3600 * 1000
  var newMoonEpoch = Date.UTC(2000, 0, 6, 18, 14, 0)
  var age = ((i - newMoonEpoch) % synodic + synodic) % synodic / synodic

  var phase = "New moon"
  if (age < 0.03 || age >= 0.97) phase = "New moon"
  else if (age < 0.22) phase = "Waxing crescent"
  else if (age < 0.28) phase = "First quarter"
  else if (age < 0.47) phase = "Waxing gibbous"
  else if (age < 0.53) phase = "Full moon"
  else if (age < 0.72) phase = "Waning gibbous"
  else if (age < 0.78) phase = "Last quarter"
  else phase = "Waning crescent"

  var jd = i / 86400000 + 2440587.5
  var T = (jd - 2451545.0) / 36525.0
  var sun = _sunEquatorial(T)
  var moon = _moonEquatorial(T)
  var S = _vec3(sun.ra, sun.dec)
  var M = _vec3(moon.ra, moon.dec)
  var cosE = _dot(S, M)

  // waxing when the moon sits east of the sun on the sky.
  var waxing = _wrap360(_deg(moon.ra) - _deg(sun.ra)) < 180
  var illumination = Math.max(0, Math.min(1, (1 - cosE) / 2))

  return {
    ageDays: age * 29.530588853,
    illumination: illumination,
    phase: phase,
    waxing: waxing
  }
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

// ---- Sunrise / sunset (Open-Meteo daily API).

function parseSunTimes(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    var daily = data && data.daily
    if (!daily || !daily.sunrise || !daily.sunset) return null
    var rise = toMs(daily.sunrise[0])
    var set = toMs(daily.sunset[0])
    if (isNaN(rise) || isNaN(set)) return null
    return { rise: rise, set: set }
  } catch (e) {
    return null
  }
}

// Normalised sun position: 0.0 at sunrise, 1.0 at sunset, <0 before rise,
// >1 after set.  Drives the mini sun arc in the panel footer.
function sunPosition(sunTimes, ms) {
  if (!sunTimes) return null
  var span = sunTimes.set - sunTimes.rise
  if (span <= 0) return null
  return (ms - sunTimes.rise) / span
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
    moonInfo: moonInfo,
    arrow: arrow,
    tideState: tideState,
    barLabel: barLabel,
    parseLocationFile: parseLocationFile,
    locationSlug: locationSlug,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    parseSunTimes: parseSunTimes,
    sunPosition: sunPosition
  }
}