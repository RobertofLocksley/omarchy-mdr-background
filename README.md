# Macrodata Refinement background

A Quickshell background plugin for [Omarchy](https://omarchy.org/) 4 that
replaces the desktop wallpaper with a live Macrodata Refinement field, as seen
on the Lumon terminals in *Severance*.

Digits fill the screen. Some of them are *scary* — they swell and twitch. Lasso
a cluster with the mouse and, if most of what you caught was scary, it flies
into one of the five bins along the bottom.

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-mdr-background
```

The plugin replaces Omarchy's built-in `omarchy.background`, so it takes over
wallpaper rendering entirely — including transitions and theme switching, which
are preserved as-is.

## Activation

The field only draws under a theme that opts in. By default that is the theme
slug `lumon-macrodata`, read from `~/.local/state/omarchy/current/theme.name`.
Under any other theme you get the ordinary wallpaper, unchanged.

To bind it to a different theme, edit `mdrThemeName` in `Background.qml`.

## Behaviour worth knowing

**It suspends when covered.** A background-layer surface is invisible the
moment a window sits over it, so animating underneath one is wasted work. The
frame driver stops, driven off the Hyprland workspace's window count, and
resumes when the workspace empties. CPU/GPU cost goes to effectively zero;
memory stays allocated, since the grid objects are kept so resuming is instant.

This deliberately does *not* use `updatesEnabled`. Omarchy's stock background
plugin documents that parking the layer that way can lose its committed buffer
and leave a black desktop until the shell restarts.

**Double-click still works.** Omarchy's double-click-to-change-background and
right-double-click-to-change-theme gestures are forwarded through. A press that
travels less than 10px is treated as a click rather than a lasso, so the two do
not fight.

## Tuning

Properties on `MdrField`, all settable from `Background.qml`:

| Property | Default | Effect |
|---|---|---|
| `scaryThreshold` | `0.66` | Higher means sparser clusters |
| `noiseStep` | `0.2` | Noise distance between cells; lower means larger clusters |
| `driftSpeed` | `0.004` | How fast clusters migrate |
| `tickMs` | `33` | Frame interval; 33 is ~30fps |
| `scanlines` | `true` | CRT scanline overlay |

## Credits

Derived from Omarchy's `omarchy.background` plugin (MIT, Basecamp).

The refinement mechanic is reimplemented from scratch — noise-thresholded
clusters, the majority-scary selection rule, and the bin model are all informed
by [Lumon-Industries/Macrodata-Refinement](https://github.com/Lumon-Industries/Macrodata-Refinement),
but no code is copied from it: that project declares no license.

*Severance* is Apple TV+. Not affiliated with or endorsed by Apple or the
show's producers.
