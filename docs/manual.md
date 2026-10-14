# etaf-screensaver manual

This manual documents the scene interface: the spec format, the expression
language, every built-in layer and the two extension points. The public API
list lives in `etaf-screensaver.el`; this document explains how to use it.

## Concepts

A **scene** is a pure generative program registered under an identifier. It
builds a state, advances it by one frame and projects it into canvas rows. The
workspace owns one session per buffer: the clock, the seed, the parameter refs
and the frame publication.

A **spec** is inert data describing a scene: a title, parameters and a stack of
**layers**. Each layer names a registered **kind** and its properties. The DSL
interprets the spec into ordinary scene callbacks, so adding a screensaver
means adding a data file.

A **frame** is a list of row strings, each exactly as wide as the canvas (or a
single newline-separated string). Rows may carry `face` properties for color;
adjacent cells with the same color become one text-property run, so quantized
color is cheap and per-cell rainbow noise is not.

## Scene spec

A spec is a plist; a `.esc` file wraps it in `(etaf-scene ...)`. Keys:

| Key | Required | Meaning |
| --- | --- | --- |
| `:id` | yes | symbol registered as the scene identifier |
| `:title` | no | display name (defaults to the identifier's name) |
| `:summary` | no | one-line description |
| `:tags` | no | list of symbols for grouping |
| `:frame-rate` | no | preferred frames per second (default 15) |
| `:background` | no | canvas color; defaults to the workspace canvas token |
| `:params` | no | parameter descriptors (see below) |
| `:layers` | yes | nonempty list of layers, drawn back to front |

Registering the same `:id` again replaces the previous scene in place, which
is what makes reloading a file update the mounted scene.

### Parameters

Each descriptor is a plist:

| Key | Applies to | Meaning |
| --- | --- | --- |
| `:key` | all | symbol used in expressions and `etaf-screensaver-set-param` |
| `:label` | all | nonempty display label |
| `:type` | all | `number`, `choice` or `toggle` |
| `:default` | all | initial value, valid for the type |
| `:min`, `:max` | number | inclusive integer bounds |
| `:step` | number | positive integer alignment (default 1) |
| `:options` | choice | alist of unique keys to nonempty labels |

Parameters appear in the workspace's panel as a Slider, Segmented selector or
Switch. A parameter is addressed by its key symbol in expressions, and Lisp
callers may also use the equivalent keyword (`:speed` or `speed`).

### Context

Every callback receives a plist:

| Key | Value |
| --- | --- |
| `:columns`, `:rows` | canvas size in cells |
| `:seed` | the session's seed |
| `:tick` | completed steps before this one |
| `:elapsed` | seconds before this step |
| `:dt` | seconds since the previous step (0 for a single step) |
| `:params` | list of parameter keys |
| `:param` | key to value function |
| `:random` | no argument returns a float in [0,1); a positive limit returns an integer below it |

## Expression language

Layer properties may be literals, parameter symbols, or expressions. An
expression is a number, a string, `t`, `nil`, a variable or a list whose head
is one of the forms below. The evaluator never calls `eval`; unknown
variables, functions and forms signal `etaf-screensaver-error`.

### Variables

- the scene parameters (`speed`, `density`, ...);
- a particle's or field cell's own fields (`x`, `y`, `vx`, ...);
- the globals `w`, `h` (canvas size), `cx`, `cy` (center), `t` (seconds),
  `dt` (step seconds), `tick` (steps), `i` (particle index), `pi` and `e`.

A field binding shadows a parameter of the same name, and a parameter shadows
a global.

### Forms

`(if TEST THEN [ELSE])`, `(and ...)`, `(or ...)`, `(not X)`.

### Functions

| Group | Functions |
| --- | --- |
| arithmetic | `+`, `-`, `*`, `/`, `mod`/`%` |
| comparison | `<`, `<=`, `>`, `>=`, `=`, `/=` |
| rounding | `floor`, `ceiling`, `round`, `abs`, `sign`, `float` |
| selection | `min`, `max`, `clamp` |
| power and roots | `pow`, `sqrt` |
| trigonometry | `sin`, `cos`, `tan` |
| random | `(rnd)` in [0,1), `(rnd LIMIT)` in [0,LIMIT), `(rndi LIMIT)` integer |

Comparisons are variadic: `(< a b c)` is true when the sequence increases.

## Layers

### `life`

A Conway-style neighborhood automaton.

| Property | Meaning |
| --- | --- |
| `:rule` | plist `(:birth (3) :survive (2 3))`; defaults to Conway's rule |
| `:density` | initial population, 0 to 1 (default 0.25) |
| `:wrap` | whether opposite edges are neighbors (default true) |
| `:char` | live cell character (default `█`) |
| `:color` | live cell color |

A field with no live cells is reseeded automatically, so the screensaver never
freezes on an empty board.

### `rain`

One driven drop per column with a visible tail.

| Property | Meaning |
| --- | --- |
| `:glyphs` | string of characters a drop may show (default `01`) |
| `:head` | the leading character (default `▓`) |
| `:tail` | rows a tail spans (default 8) |
| `:speed` | fall speed (default 8) |
| `:direction` | `down` (default) or `up` |
| `:color` | whole-layer color |

### `sand`

Falling materials with declarative movement, plus optional rain and mouse
painting. The layer is interactive: dragging on the canvas stamps the brush.

| Property | Meaning |
| --- | --- |
| `:materials` | nonempty list of material plists (see below) |
| `:rain` | grains emitted at the top per step (default 0) |
| `:rain-material` | material key the rain uses (default the first one) |
| `:brush` | current material key; any other value erases |
| `:brush-size` | odd cell count of the square brush (default 1) |

A material plist holds `:key`, `:char`, optional `:color`, `:moves` (an
ordered list of `down`, `down-left`, `down-right`, `left`, `right`, `up`,
`up-left`, `up-right`) and optional `:flows-through`, a list of material keys
that may enter this material. Opposite moves are tried in random order, so a
pile spreads naturally. An empty `:moves` list makes a material static (a
wall).

### `particles`

Numeric particles driven by expressions.

| Property | Meaning |
| --- | --- |
| `:count` | particle count (default 50) |
| `:init` | alist of field to expression, evaluated at creation |
| `:update` | alist of field to expression, applied every step |
| `:wrap` | list of `(:field LOW HIGH)`: values under LOW jump to HIGH and over HIGH jump to LOW |
| `:recycle` | `(:when EXPR :fields ALIST)`: when EXPR is true, reinitialize the listed fields |
| `:draw` | plist with `:x`, `:y`, `:char` and `:color` expressions |
| `:color` | fallback color for a particle without a `:color` expression |

Fields default to `x`, `y`, and particles are drawn at rounded coordinates.
Out-of-canvas draws are clipped by the canvas, so effects may start off screen.

### `field`

One expression per cell: a stateless color or character field.

| Property | Meaning |
| --- | --- |
| `:value` | expression evaluated with `x` and `y` in cell coordinates |
| `:range` | `(LOW HIGH)` value range used for normalization (default 0 to 1) |
| `:ramp` | character ramp, indexed by the normalized value |
| `:palette` | optional list of colors, indexed by the normalized value |
| `:block` | `(WIDTH HEIGHT)` cells per evaluation (default 1 by 1) |

The palette is quantized: adjacent cells that land on the same entry merge
into one run, which keeps a smooth field cheap to publish.

### `text`

| Property | Meaning |
| --- | --- |
| `:lines` | a string or a list of strings |
| `:speed` | lines per second when scrolling (default 1) |
| `:scroll` | whether the block scrolls upwards (default true) |
| `:align` | `left`, `center` (default) or `right` |
| `:color` | text color |

Empty strings keep paragraph gaps. Wide characters are placed with their own
display width, so CJK text stays aligned.

### `banner`

An ASCII banner revealed by a terminal text effect; the effect holds, then the
next one takes over, looping forever. This is the Omarchy-style screensaver
(their `ttfx` loop) expressed as data.

| Property | Meaning |
| --- | --- |
| `:art` | the banner as a string with newlines or a list of lines |
| `:effects` | effect list; defaults to the full rotation |
| `:effect-time` | seconds one effect takes to settle (default 3) |
| `:hold` | seconds the settled banner stays (default 0.8) |
| `:colors` | palette; each effect run picks one color |

Effects: `print`, `wipe`, `dissolve`, `decrypt`, `rain`, `beams`,
`middleout`, `spray`. Unsettled cells may show transient glyphs (decrypt
scrambles in place, rain shimmers ahead of the falling head, spray flies in
from a random direction).

## Scene files

`etaf-screensaver-scene-directories` lists the scanned directories in order.
Each `*.esc` file holds exactly one `(etaf-scene ...)` form. Bundled scenes
live in `lisp/scenes`; the default user directory is
`~/.emacs.d/etaf-screensaver/scenes`. A later directory replaces a scene whose
`:id` matches, so a user file overrides a bundled scene.

- `etaf-screensaver-load-scenes` loads every configured directory and returns
  how many files loaded; a file that fails to read or validate reports and is
  skipped while the rest still load.
- `etaf-screensaver-reload-scenes` reloads the files and rebuilds the mounted
  scene in place, so an edited spec appears without switching away.
- `etaf-screensaver-register-scene` registers a spec programmatically.

## Code scenes

A scene that outgrows the DSL registers ordinary callbacks with
`etaf-screensaver-define-scene`:

```elisp
(etaf-screensaver-define-scene my-scene
  :title "Custom"
  :summary "Shows a counter"
  :params '((:key step :label "Step" :type number :min 1 :max 5 :step 1 :default 1))
  :create (lambda (context) (list :count 0))
  :step (lambda (state context)
          (setf (plist-get state :count)
                (+ (plist-get state :count)
                   (funcall (plist-get context :param) :step))))
  :render (lambda (state context)
            (list (format "count=%d" (plist-get state :count)))))
```

The callbacks are `:create`, `:step`, `:render` and the optional `:resize`
(return a state that fits a resized canvas) and `:pointer` (receives
`(:phase start|move|end :row ROW :column COLUMN :event EVENT)`; return non-nil
to repaint immediately).

## Adding a layer kind

Layer kinds are registered in the DSL:

```elisp
(etaf-screensaver--define-layer-kind 'my-kind
  :validate (lambda (layer) ...)
  :create (lambda (layer context) ...)
  :step (lambda (layer state context) ...)
  :draw (lambda (layer state context canvas) ...)
  :resize (lambda (layer state context) ...) ; optional
  :pointer (lambda (layer state context event) ...)) ; optional
```

`draw` writes cells through `etaf-screensaver--canvas-draw`; the canvas merges
colors and handles wide characters. Build with `make check` as usual.

## Performance notes

- A monochrome full-canvas frame publishes in a few milliseconds; per-cell
  colors cost roughly proportionally to the number of color runs. Quantize
  palettes and merge runs.
- High-frequency scenes should cap themselves: `:frame-rate` is the scene's
  own budget. The workspace pauses stepping while its buffer is not visible.
- Keep particle counts and field resolutions modest; `:block` in a field or a
  coarse ramp is the cheap way to trade detail for speed.
- The canvas and HUD hosts are updated through ETAF's retained boundary, so a
  frame never re-renders the application; structural changes (cinema mode, the
  parameter panel, scene switching, a resize) re-render once.
