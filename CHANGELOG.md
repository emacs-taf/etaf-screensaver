# Changelog

## Unreleased

### Added

- Eased page reveals preserve outgoing colors while the next work moves,
  without per-frame image encoding. Configure the duration independently in
  Lisp or Customize; wake input remains available throughout.

- A rebuildable 24-work moving gallery, with six light compositions and three
  dark packs. Offline baking reuses Vanta and MilkDrop renderers, retains their
  attribution and licenses, and can crossfade each reel's loop seam.
- Bounded, atomic canvas baking with deterministic preset/effect seeds,
  frame-by-frame warmup, additional preset packs and offline CLI tests.

- Independent presentation selection: full canvas, gallery card, cinema band
  with clock, and a mosaic of up to four independently animated works. Choose
  globally or per program group/item; narrow walls stack their works.

- Recorded-animation reels adapt external tools without transcribing their
  algorithms. The built-in `tte` provider reads Terminal Text Effects
  recordings, and `etaf-screensaver-import-recording` and
  `etaf-screensaver-import-directory` validate, copy and report compatible
  files with dimensions, color depths and license. Fourteen recorded reels ship
  in `lisp/reels` and join the default program. Other tools can register a
  reader through `etaf-screensaver-define-reel-provider`.
- Image-frame reels: the built-in `frames` provider reads a JSON manifest
  plus baked stills; the canvas scales and slices them per character row,
  centers them and recycles decoded frames. `scripts/bake-canvas-frames.mjs`
  bakes Butterchurn/MilkDrop presets or any page canvas into a bundle.
  Baked bundles stay out of version control.
- Style packs and strategies: `etaf-screensaver-packs` groups scenes into a
  shared visual language (neon, space, ink, ember) and programs accept
  `(:pack NAME)` items, so a round can hold one pack, rotate whole packs,
  loop a single work or mix packs deliberately.  Recorded works register
  their recorded length as the scene duration and no longer get cut
  mid-loop.  Fourteen Terminal Text Effects recordings ship in `lisp/reels`,
  including a light-paper `ink` pack; `scripts/trim-recording.py` drops the
  still tail of a recording before import.

### Changed

- Gallery cards fill the editing area with a thin frame and ordinary lower-left
  title/description. Images retain their native size when they fit and only
  scale down proportionally, avoiding blurred enlargement. Generated gallery
  scenes retain their own background in both standalone and pack playback.

- The application is now a canvas-only screensaver. Configure it in Lisp or
  Customize; any key, mouse movement, completed click or wheel input wakes it.
  Dismissal restores the editor and releases all presentation resources.
- Playback programs compose sequential, shuffled and random groups, including
  nested animation sequences, selection counts and per-scene settings.
- **Breaking:** replace `etaf-screensaver-open`/`present` with
  `etaf-screensaver-start`, `close` with `etaf-screensaver-stop`, and
  `etaf-screensaver-idle-mode` with `etaf-screensaver-mode`. Workspace controls
  (pause, resume, step, reset, select-scene, set-param, set-frame-rate and
  set-seed) are removed; use the program and scene-options configuration.
  Replace default-scene/cycle-seconds with program/scene-duration. Status no
  longer takes a buffer name. Use `etaf-screensaver-load-scenes` before a new
  start instead of live reload. Scene pointer callbacks and sand painting
  are removed because pointer input always wakes the editor.
- ETAF UI is no longer a runtime dependency.

### Fixed

- Sequential ANSI color and attribute changes no longer alter preceding runs
  in recorded frames; foreground/background and attribute resets stay local.

- Frame cadence stays aligned to each page's clock instead of accumulating
  timer delay; late frames skip expired slots and natural page deadlines stay
  independent of the outgoing frame's timing.

- Gallery playback reuses fitted image rows and avoids repeated image-width
  measurement and per-cell rendering allocations for empty margins while preserving frame size,
  letterboxing, clipping, styled blank widths and aligned mosaic borders.

- Image-bundle imports recognize file headers even in a headless Emacs build.
  Image composition remains testable without decoding pixels; graphical
  playback still checks decoder support. Validated formats are reused during
  playback instead of reopening each still to redetect its type.

- Repeating gallery rounds reuse validated recording metadata within a shared
  payload budget. Padding shorter rows preserves their image runs without
  unnecessary cropping or reconstruction.

- Image-bundle validation reuses a header buffer and canonical bundle root
  instead of repeating editor-buffer hooks and path traversal for every still.
  Common image signatures use a short initial read, with a bounded fallback
  for longer headers. Import revalidates current assets even when its manifest
  is unchanged; suffixes never replace content checks.

- Image bundle imports reject escaping frame paths and oversized manifests,
  declared canvases, frame lists and encoded image payloads before copying.
- Color-only animation frames now repaint instead of freezing after the first
  tick. Image rows reserve their complete footprint and align to whole rows.
- Default pack playback includes its trailing works instead of repeatedly
  selecting only an initial subset.
- Resuming honors changed effective settings and preserves scene seeds and the
  program's random state. Explicit previews no longer replace that position.
- Frame scheduling no longer adds render time to every nominal frame interval.
- Gallery and mosaic playback reuse their static borders and captions rather
  than rebuilding them on every animation tick. Dense fields reuse invariant
  calculations and reduce per-cell temporary allocations without reducing
  sampling density or changing randomness. Generative scenes reuse their
  current-size scratch canvas without retaining old glyphs or colors. Life
  counts neighbors from live cells and reuses its generation buffers.
- A manually started background preview survives global focus rechecks; it
  still dismisses when its own frame actually loses focus or receives input.
- Scenes can draw Unicode symbols and mixed-width text on Emacs 31, including
  Matrix, Life and Chinese quotes, without failing to write a canvas cell.
- Random expressions use the session seed throughout the scene lifecycle,
  allowing Snow and Starfield to initialize and reset reproducibly.

## 0.1.0

Initial release.

- A scene registry with two public paths: inert scene specs interpreted by the
  generic DSL, and `etaf-screensaver-define-scene` for code scenes.
- Generic layer kinds: `life`, `rain`, `sand`, `particles`, `field`, `text`
  and `banner` (ASCII banner with random terminal effects).
- A pure expression language for layer properties with parameters, globals
  (`w`, `h`, `cx`, `cy`, `t`, `dt`, `tick`, `i`) and arithmetic,
  trigonometric and comparison functions.
- Scene spec files (`.esc`) loaded from `etaf-screensaver-scene-directories`
  with in-place override, tolerant error reporting and live reload.
- A workspace with play, pause, single step, reset, seed, frame rate, scene
  switching, a parameter panel built from ETAF UI components, cinema mode and
  an optional idle presentation mode.
- A retained canvas and HUD line, so a running scene publishes frames without
  re-rendering the application.
- Nine bundled scenes and acceptance tests for the catalog, controls, the DSL,
  the loader and the mount lifecycle.
