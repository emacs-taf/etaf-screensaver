# etaf-screensaver manual

This manual explains idle presentation, Lisp playback configuration and scene
authoring. The supported API inventory lives in `etaf-screensaver.el`.

## Automatic presentation and waking

```elisp
(require 'etaf-screensaver)
(setq etaf-screensaver-idle-delay 300)
(etaf-screensaver-mode 1)
```

After the idle interval, the selected Emacs frame shows only animation.
Automatic activation waits while the minibuffer is active or the frame is
hidden or unfocused. It never raises a frame or starts a child process.
`etaf-screensaver-start` starts the same presentation manually; an optional
program argument overrides configuration for that presentation only.

A key, mouse movement, completed click or wheel event restores the saved
windows and buffer positions. The wake event is consumed, not replayed into
an editor or another application's controls. A click dismisses on release;
its button-down event is consumed first. Stopping removes the animation timer,
transient input map, wake hooks, mouse-tracking change, Runtime and ephemeral
buffer. Repeated start does not overwrite the original window snapshot, and
repeated stop is harmless. Killing the presentation buffer also cleans up.
This is not a security lock and does not protect unattended sensitive data.

Automatic mode retains one idle watcher and a post-command rearming hook.
After dismissal it waits a fresh interval, including a mouse-only wake that
did not reset Emacs's native idle clock. `(etaf-screensaver-mode -1)` dismisses
any active presentation and releases the watcher and hook too. Re-enabling
replaces the watcher rather than accumulating timers; do this after changing
`etaf-screensaver-idle-delay` if the new delay should take effect immediately.

## Composing playback

A program is a scene symbol, a configured scene item, or a group containing
more programs. The root repeats after each finite round.

```elisp
;; One animation, recreated after its duration.
(setq etaf-screensaver-program 'donut)

;; One ordered sequence.
(setq etaf-screensaver-program
      '(:order sequential :scenes (matrix starfield snow)))

;; Every scene once, in a newly shuffled order each round.
(setq etaf-screensaver-program
      '(:order shuffle :scenes (matrix starfield snow donut plasma)))

;; Choose groups randomly, but play the first group's sequence in order.
(setq etaf-screensaver-program
      '(:order random :count 2
        :scenes ((:order sequential :scenes (matrix starfield))
                 (:order shuffle :scenes (snow plasma donut)))))
```

Groups take `:order`, a nonempty `:scenes` list and an optional positive
`:count` (default: child count). Sequential order wraps through children;
shuffle draws without replacement within each bag and creates another bag
if count exceeds child count; random samples with replacement. Thus random
can repeat a scene or group, whereas shuffle covers every child in a bag.
Nested groups remain contiguous; the parent chooses a whole child program,
not individual scenes flattened out of it.

Scene items specify `:scene`, optional positive `:duration` seconds,
`:frame-rate` and a `:params` alist. Defaults can be shared per scene:

```elisp
(setq etaf-screensaver-scene-duration 30
      etaf-screensaver-max-frame-rate 30
      etaf-screensaver-scene-options
      '((matrix :duration 20 :params ((speed . 4)))
        (donut :params ((speed . 6) (detail . normal))))
(setq etaf-screensaver-program
      '(:order sequential
        :scenes ((:scene matrix :duration 10 :params ((speed . 7)))
                 donut)))
```

Item values override per-scene defaults, which override the scene's parameters
and frame rate or the global default duration. Parameter alists merge by key;
symbol and keyword forms address the same parameter. The global frame-rate cap
always applies. It is a ceiling, not a promise of physical refresh frequency.
A duration must be at most one day, frame rates at most 120, group child/count
values at most 1000, nesting at most 16 and an expanded round at most 10000
nodes. These bounds keep erroneous configurations from blocking the editor.

`etaf-screensaver-seed` is nil by default, giving each presentation a new seed.
An integer reproduces the program choices and initial scene states. Later
frames depend on elapsed time and viewport dimensions as well. Configuration
is validated and snapshotted at start; edit it outside the screen, then stop
and start to apply it. `etaf-screensaver-status` reports the active item,
effective parameters and remaining scenes without showing an on-screen HUD.

Invalid configuration fails before window takeover. A callback or rendering
failure tears down the presentation, reports its cause and disables automatic
mode to prevent repeated idle errors. Correct the configuration or scene,
then enable the mode again.

## Concepts

A **scene** is a pure generative program registered under an identifier. It
builds a state, advances it by one frame and projects it into canvas rows. The
presentation owns one session: the clock, seed, parameter values and frame
publication. It creates no extra frame and changes no user buffer contents.

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
| `:background` | no | canvas color; defaults to `etaf-screensaver-background` |
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

Parameters are configured through `etaf-screensaver-scene-options` or program
items, never through an in-screen control. A parameter is addressed by its key
symbol in expressions; Lisp configuration may use the equivalent keyword
(`:speed` or `speed`).

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
Random expressions use the session's seeded generator during creation, steps,
rendering and resize. Starting with the same seed replays the same sequence
when the viewport, parameters and elapsed-time steps are unchanged.

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

Falling materials with declarative movement and optional continuous emission.
Mouse input dismisses the screensaver; there is no painting mode.

| Property | Meaning |
| --- | --- |
| `:materials` | nonempty list of material plists (see below) |
| `:rain` | grains emitted at the top per step (default 0) |
| `:rain-material` | material key the rain uses (default the first one) |

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
Each `*.esc` file holds exactly one `(etaf-scene ...)` form and each `*.esr`
file one `(etaf-reel ...)` form. Bundled scenes live in `lisp/scenes` and
bundled reels in `lisp/reels`; the default user directory is
`~/.emacs.d/etaf-screensaver/scenes`. A later directory replaces a scene whose
`:id` matches, so a user file overrides a bundled scene.

- `etaf-screensaver-load-scenes` loads every configured directory and returns
  how many files loaded; a file that fails to read or validate reports and is
  skipped while the rest still load.
- Call the loader outside presentation after editing files, then start a new
  presentation to use the updated registrations.
- `etaf-screensaver-register-scene` registers a spec programmatically, and
  `etaf-screensaver-register-reel` registers a recorded animation directly.

## Recorded animations

A *reel* plays a recording that an external animation tool produced, without
running that tool or transcribing its algorithms. The native recording stays
in its own format; a small `.esr` spec names the provider, dimensions, frame
count and license. Playback follows the recording's own per-frame timing and
centers its fixed canvas, cropping both edges in a smaller window. A scene
duration longer than the recording loops it.

Many recorded effects are entrance animations: the text resolves and the
frames then hold. Choose a recording that keeps changing — the bundled
`tte-beams`, `tte-synthgrid` and `tte-thunderstorm` all do — or shorten its
item duration so the still hold does not dominate. Importing validates format
and safety; it does not judge whether the animation stays in motion.

Terminal Text Effects (TTE) recordings (`*.tterec`) are supported out of the
box. Record one with the tool, then import it:

```sh
echo "Hello" | tte --record animation.tterec --seed 7 --canvas-width 80 \
  --canvas-height 24 --anchor-text c --anchor-canvas c matrix
```

```elisp
(etaf-screensaver-import-recording "/path/animation.tterec")
(etaf-screensaver-load-scenes)
(etaf-screensaver-start 'tte-animation)
```

`etaf-screensaver-import-recording` validates the recording, copies it beside
a new `.esr` spec in the user scene directory and returns a report plist. It
signals `etaf-screensaver-error` for an unrecognized format or an invalid
recording and writes nothing. Importing never transcodes frames: replacing
the recording file re-reads it at the next start.

For several files:

```elisp
(etaf-screensaver-import-directory "~/recordings")
```

The batch report holds `:imported`, `:skipped` and `:failed` lists. Every
imported entry names the provider, output spec, canvas, frame rate, frame
count, color depths and license, so incompatible files are visible before
playback instead of silently accepted. Only extensions registered by a
provider are scanned; a recognized file whose content fails validation is
reported as failed. Files other providers own are ignored, not claimed.

An `.esr` file is ordinary Lisp data and may be written by hand:

```elisp
(etaf-reel :id tte-matrix :provider tte :recording "matrix.tterec"
           :title "Terminal Text Effects: matrix"
           :width 80 :height 24 :frame-rate 20 :frame-count 306
           :source "matrix" :license "MIT")
```

A relative `:recording` resolves against the directory of the `.esr` file.
`lisp/reels` ships three recordings produced with Terminal Text Effects 0.15.0
(commit 6dbc34a0, MIT) from the text `ETAF`: the beams, synthgrid and
thunderstorm effects, which is why the default program includes `tte-beams`,
`tte-synthgrid` and `tte-thunderstorm`. The MIT license covers the TTE tool
and these bundled recordings' generation; verify the rights of your own input
text before publishing a recording.

A provider for another tool registers a reader:

```elisp
(etaf-screensaver-define-reel-provider 'my-tool
  :title "My Animation Tool"
  :license "MIT"
  :extensions '("myanim")
  :match (lambda (file) (string-suffix-p ".myanim" file))
  :read (lambda (file)
          (list :width 80 :height 24 :frame-rate 30
                :ansi t                 ; frame text may carry SGR runs
                :frames (my-tool-read-frames file))))
```

`:read` must return `:width` and `:height` in cells, `:frame-rate` and a
nonempty `:frames` vector of frame strings whose rows have exactly that
width; optional `:durations` gives seconds per frame, `:ansi` marks SGR runs
and `:source` names the work. Providers are trusted code and run in the
presentation's thread. Recordings are read once when their scene starts and
recent unchanged reads are cached, so a registered but unused reel holds only
metadata, and an invalid recording reports at import or at first playback.

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

The callbacks are `:create`, `:step`, `:render` and optional `:resize`, which
returns state fitting a resized canvas. They must be pure apart from their
own scene state: no I/O, processes, timers, buffers or editor changes. All
input belongs to the screensaver lifecycle and dismisses it. Use data specs
for ordinary scenes; callbacks are the escape hatch for algorithms the spec
language cannot express.

## Performance notes

- Quantize palettes and merge adjacent color runs; arbitrary per-cell colors
  cost more to publish than coherent runs.
- Recorded reels convert SGR runs once per frame and slice cached cells on
  resize, and recent unchanged recordings are decompressed once per session.
- Use `:frame-rate` and the global cap to bound refresh work. Playback stops
  and cleans up if its buffer/window disappears; no hidden animation probe
  remains running.
- Keep particle counts and field resolutions modest; `:block` in a field or a
  coarse ramp trades detail for computation time.
- Frame content uses ETAF's retained Host boundary. Scene switches and resize
  change the view; ordinary frames update only the canvas content.
- The maintained performance scenarios time the next autonomous frame, including
  its timer wait and publication. Background measurements do not certify
  physical input latency or foreground automatic activation.
