# Omarchy Tide

A Whitley Bay tide bar widget for [Omarchy](https://omarchy.org/).

Adds a tide pill to the bar showing the next high/low (▲/▼) with a tide-curve popup: a rolling 6 h back / 18 h ahead wave, a LOW→HIGH water gauge, and the upcoming events. Data comes from the Open Waters tide API (api.openwaters.io), resolving to the North Shields reference station, and is cached locally so the panel works offline.

## Install

Requires an Omarchy system (Hyprland + the Omarchy shell).

```sh
omarchy plugin add https://github.com/Gnosis80s/OmarchyTide.git --enable
```

The command clones the repo, validates it against the Omarchy plugin schema, installs it to `~/.config/omarchy/plugins/whitleybay.tide/`, and places it in the center of the bar. The bar hot-reloads; no shell restart is needed.

Not on the bar after all? Enable it manually:

```sh
omarchy plugin enable whitleybay.tide --section center
```

## Usage

- **Left click** on the pill: open/close the tide panel.
- **Middle click**: refresh the tide data.

## Notes

- Coordinates and the gauge label are hardcoded to **Whitley Bay** (55.0456, -1.4443 / North Shields) — this widget will not show another location's tides.
- Requires `curl`, `bash`, and GNU `date` (all standard on Arch), plus network access to `api.openwaters.io` at least once for fresh data.
- Data is cached to `~/.local/state/omarchy/settings/whitleybay-tide-*.json` for offline use.
- The bar pill and panel accent colors follow your active Omarchy theme.

## Layout

```
whitleybay.tide/
├── manifest.json     # Plugin manifest (id, entry point, bar-widget metadata)
├── BarWidget.qml     # Bar pill: mini water gauge + next event time
├── Panel.qml         # Popup: tide wave chart, gauge, upcoming events
└── Model.js          # Tide API parsing + interpolation helpers
```