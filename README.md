# Omarchy Tide

A searchable tide bar widget for [Omarchy](https://omarchy.org/).

Adds a tide pill to the bar with a mini water gauge (current level between LOW
and HIGH) beside the next high/low time (▲/▼). Hovering the pill shows the
current state at a glance — location, rising/falling, and the present level.
Opening the pill rows out a panel with:

- **Tide phase** — a rolling 6 h back / 18 h ahead wave of the water level
  with a NOW marker, clean ▲/▼ event badges on the curve, and a LOW→HIGH
  water gauge for the current half-cycle.
- **Upcoming events** — the next four high/low tides with time, level, and
  how far the tide will still move (range %).
- **Daylight** — the day's sun arc with dashed sunrise/sunset hairlines (times
  read straight off the chart) and a dot marking the sun's position right now.
  Also shown: night shading outside the daylight window.
- **Moon phase** — a drawn lunar disc (lit side facing the sun, waxing right,
  waning left) with phase, % lit, and age alongside.

A live location search picks any coastal place. The pick resolves to the
nearest published tide reference station via the Open Waters tide API
(api.openwaters.io); sunrise and sunset come from Open-Meteo
(api.open-meteo.com). Everything is cached per location so the panel works
offline.

## Preview

The expanded panel on the bar (Whitley Bay, UK):

![Omarchy Tide expanded panel](tide-panel.png)

## Install

Requires an Omarchy system (Hyprland + the Omarchy shell).

```sh
omarchy plugin add https://github.com/Gnosis80s/OmarchyTide.git --enable
```

The command clones the repo, validates it against the Omarchy plugin schema,
installs it to `~/.config/omarchy/plugins/gnosis.tide/`, and places it in
the center of the bar. The bar hot-reloads; no shell restart is needed.

Not on the bar after all? Enable it manually:

```sh
omarchy plugin enable gnosis.tide --section center
```

## Usage

- **Left click** on the pill: open/close the tide panel.
- **Middle click**: refresh the tide data.
- **Hover** the pill: peek at the current state (location · phase · level).
- In the panel, tap the location to search; pick a suggestion to load that
  place. The chosen location persists across restarts.

## Notes

- The first time you open the panel you'll be asked to pick a location —
  search for your nearest coastal town.
- Coordinates and station are resolved per location; an inland pick resolves
  to the closest tide station, so results describe the nearest coast.
- Requires `curl`, `bash`, and GNU `date` (all standard on Arch), plus network
  access to `api.openwaters.io` (tides) and `api.open-meteo.com` (geocoding and
  sunrise/sunset) at least once for fresh data.
- Data is cached to `~/.local/state/omarchy/settings/gnosis-tide-<location>-*.json`
  and the location to `gnosis-tide-location.json` for offline use.
- The bar pill and panel accent colors follow your active Omarchy theme.

## Layout

```
gnosis.tide/
├── manifest.json     # Plugin manifest (id, entry point, bar-widget metadata)
├── BarWidget.qml     # Bar pill: mini gauge + next event time + hover tooltip
├── Panel.qml         # Popup: location search, tide wave, gauge, daylight arc, coming up, moon
└── Model.js          # Tide API parsing, geocoding, interpolation, sun times
```
