# Changelog

## Unreleased

### Added

- Recorded-animation reels adapt external tools without transcribing their
  algorithms. The built-in `tte` provider reads Terminal Text Effects
  recordings, and `etaf-screensaver-import-recording` and
  `etaf-screensaver-import-directory` validate, copy and report compatible
  files with dimensions, color depths and license. Three recorded reels ship
  in `lisp/reels` and join the default program. Other tools can register a
  reader through `etaf-screensaver-define-reel-provider`.
- Image-frame reels: the built-in `frames` provider reads a JSON manifest
  plus baked stills; the canvas scales and slices them per character row,
  centers them and recycles decoded frames. `scripts/bake-canvas-frames.mjs`
  bakes Butterchurn/MilkDrop presets or any page canvas into a bundle.
  Baked bundles stay out of version control.

### Changed

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
