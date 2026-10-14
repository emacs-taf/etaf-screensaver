# etaf-screensaver

Generative screensavers for Emacs, built on [ETAF](https://github.com/emacs-taf/etaf).
A screensaver is a **scene spec**: a small data file that stacks generic layers
(automata, materials, particles, fields, text, terminal effects) and drives them
with a pure expression language. Add a scene by dropping a `.esc` file into a
directory; no Lisp is required. Faster, richer scenes can still register code
callbacks through the public macro.

## Requirements

- Emacs 29.1 or later.
- The framework checkouts `etaf`, `etaf-ui`, `ebox` and `ecss` on `load-path`
  (beside this repository, or two levels up in the workspace layout).

## Install and run

Add this repository root and the four provider roots to `load-path`, then:

```elisp
(require 'etaf-screensaver)
M-x etaf-screensaver-open          ; interactive workspace
M-x etaf-screensaver-present       ; full-window screensaver, any key wakes
```

`M-x etaf-screensaver-idle-mode` presents a screensaver after
`etaf-screensaver-idle-delay` seconds of idle time.

## Keys

| Key | Action |
| --- | --- |
| `SPC` | play or pause |
| `n` | pause and advance exactly one frame |
| `s` / `S` | next or previous scene |
| `+` / `-` | raise or lower the frame rate |
| `TAB` | open or close the parameter panel |
| `r` | reset the scene at the same seed |
| `R` | reset with a fresh random seed |
| `c` | toggle cinema mode (canvas only) |
| `l` | reload the scene spec files |
| `?` | key help |
| `q` | close |

The parameter panel edits the current scene through the catalog's Slider,
Segmented and Switch components; `etaf-screensaver-set-param` changes the same
parameters from Lisp. Present mode hides the chrome, cycles scenes every
`etaf-screensaver-cycle-seconds` and returns the previous window configuration
when any key is pressed.

## Bundled scenes

| Scene | What it shows |
| --- | --- |
| `banner` | an ASCII banner revealed by random terminal effects, looping |
| `donut` | the classic rotating torus with a z-buffer and a luminance ramp |
| `falling-sand` | sand, water and walls with mouse painting and passive sand rain |
| `life` | Conway's Game of Life with an automatic reseed |
| `matrix` | digital rain with per-column glyphs and a green face |
| `plasma` | four sine waves quantized into a palette, merged into color runs |
| `quotes` | a centered block of text scrolling upwards |
| `snow` | drifting flakes that sway and wrap around the canvas |
| `starfield` | stars flying past with depth-based brightness |

## Adding a screensaver

Write one scene spec file, for example `~/.emacs.d/etaf-screensaver/scenes/rainbow.esc`:

```elisp
(etaf-scene
 :id rainbow
 :title "彩虹"
 :summary "彩色正弦带"
 :frame-rate 12
 :params ((:key speed :label "速度" :type number :min 1 :max 8 :step 1 :default 3))
 :layers ((:kind field
           :value (sin (+ (* 0.2 x) (* speed t)))
           :range (-1 1)
           :ramp " .:-=+*#%@"
           :palette ("#101A3A" "#1B3A6E" "#2E9E9B" "#B3E3A0" "#F2F7C8"))))
```

Then load it with `M-x etaf-screensaver-reload-scenes` (or `l` in the workspace);
the scene joins the switcher, the cycle and the parameter panel immediately.
`etaf-screensaver-scene-directories` lists the scanned directories; a user
scene replaces a bundled scene with the same `:id`.

The full spec reference -- every layer and property, the expression language
and the callback escape hatch -- is in [docs/manual.md](docs/manual.md).

## Development

```sh
make check     # repository structure, compilation, acceptance, public API
make test      # acceptance only
make compile   # byte-compilation with warnings as errors
make clean
```

Frame-publication workloads are registered in `benchmarks/performance-scenarios.el`.
From the enclosing `emacs-taf` workspace, run:

```sh
python3 scripts/performance.py run --mode batch \
  --scenario-file etaf-apps/etaf-screensaver/benchmarks/performance-scenarios.el \
  --load-path etaf-apps/etaf-screensaver --scenario 'etaf-screensaver.frame.*'
```

These workloads step seeded, paused scenes; they measure computation and
publication rather than timer cadence. See the workspace performance manual
for baseline comparison and GUI measurement.

The GUI workflow (`make gui`) runs the maintained scenario in a graphical
Emacs server and leaves screenshots in a fresh evidence directory. On Windows,
set `PYTHONUTF8=1` if you invoke the Python policy tools directly; the
Makefile and hooks already pass `-X utf8` / `PYTHONUTF8=1`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
