# Macrodata Refinement background

A Quickshell background plugin for [Omarchy](https://omarchy.org/) 4 that
replaces the desktop wallpaper with a live Macrodata Refinement field, as seen
on the Lumon terminals in *Severance*.

Digits fill the screen. Some are *scary* — they swell and twitch, in clusters
that drift across the field. Lasso a cluster with the mouse and, if most of what
you caught was scary, it flies into one of the five bins along the bottom.

## Install

```bash
omarchy plugin add https://github.com/RobertofLocksley/omarchy-mdr-background
```

This replaces Omarchy's built-in `omarchy.background`, taking over wallpaper
rendering including transitions and theme switching.

## Activation

The field only draws under a theme that opts in — by default the theme slug
`lumon-macrodata`, which pairs with
[omarchy-lumon-macrodata](https://github.com/RobertofLocksley/omarchy-lumon-macrodata).
Under any other theme you get the ordinary wallpaper.

To bind it to a different theme, change `mdrThemeName` in `Background.qml`.

## Behaviour

**It pauses when covered.** The field animates only while the desktop is
actually visible; open a window over it and the animation stops until the
workspace is clear again. Idle cost is effectively zero.

**Double-click gestures still work.** Omarchy's double-click to change
background, and right-double-click to change theme, both pass through. A press
that travels less than 10px counts as a click rather than a lasso.

## Tuning

Properties on `MdrField`, settable from `Background.qml`:

| Property | Default | Effect |
|---|---|---|
| `scaryThreshold` | `0.66` | Higher means sparser clusters |
| `noiseStep` | `0.2` | Noise distance between cells; lower means larger clusters |
| `driftSpeed` | `0.004` | How fast clusters migrate |
| `tickMs` | `33` | Frame interval; 33 is ~30fps |
| `scanlines` | `true` | CRT scanline overlay |

## License

MIT. Derived from Omarchy's `omarchy.background` plugin, also MIT —
[basecamp/omarchy](https://github.com/basecamp/omarchy).

*Severance* is Apple TV+. Not affiliated with or endorsed by Apple or the show's
producers.
