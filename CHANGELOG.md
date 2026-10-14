# Changelog

## Unreleased

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
