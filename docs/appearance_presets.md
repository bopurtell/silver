# Themes and appearance

## Live color schemes

Open the palette (**Space c c**), type `theme`, and choose **Choose theme…**.
Type to filter; **↑/↓** or **Tab/Shift-Tab** previews the highlighted theme on
your workspace. **Enter** saves it, and **Esc** restores the previous theme.

Try **Silver Dark**, **Silver Light**, **Silver Blue**, **Silver Dusk**,
**Silver Patina**, or **Silver Pearl**. Search `cobalt` or `btop` for palettes
adapted from those applications; they ship with Silver and need no separate
installation.

## Presets and independent controls

Search `appearance` in the palette. `[active]` marks the current setting.

| Preset | Presentation |
| --- | --- |
| A — Instrument | Rounded frames and lowercase border titles |
| B — Structured | Rectangular frames and clear focus |
| C — Minimal | Quiet, borderless chrome |
| D — Studio | Filled cards and tile-title badges |
| E — Structured studio | Structured frames with Studio-style headers |

You can choose color (**Vivid**, **Selective**, or **Restrained**), icons
(**Unicode**, **ASCII**, or **Off**), and density (**Compact** or
**Comfortable**) independently. Unicode uses standard box drawing, not Nerd
Font. Status animation indicates a pending request or active producer, not a
passing result. Changing appearance does not alter provider output, start
work, or change run selections, pins, or layouts.

Appearance choices persist per project and environment; they don't change
another running client. See [presentation preferences](existing_project_setup.md#persistent-presentation-preferences)
and [workspace layout](workspace_configuration.md) for related settings.

## Capture frames locally

From the Silver checkout, build the normal terminal binary and run:

```sh
_build/default/terminal/main.exe --capture-appearance /path/to/new-capture-directory
```

This writes deterministic synthetic scenarios as plain-text and ANSI frames.
It does not start a daemon, open real evidence, or invoke EDA tools.
