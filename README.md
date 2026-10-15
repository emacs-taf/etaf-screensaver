# etaf-screensaver

Generative screensavers for Emacs, built on [ETAF](https://github.com/emacs-taf/etaf).
After an idle interval, animation fills the current frame's editing area.
A key, mouse movement, click or wheel input dismisses it and restores the
previous windows. There are no controls, parameter panels or status bars.
Configuration belongs in Emacs Lisp or `M-x customize-group RET etaf-screensaver`.

This is a visual screensaver, **not a security lock**. It creates no child
processes. Dismissal releases its animation timer, transient input map and
buffer; automatic mode retains only its idle watcher and rearming hook.
Disabling the mode releases those too.

## Requirements and setup

Emacs 29.1 or later and the `etaf`, `ebox` and `ecss` provider roots on
`load-path`. Providers may be beside this repository or two levels up in the
`emacs-taf/etaf-apps` workspace layout. Add this repository root as well:

```elisp
(require 'etaf-screensaver)
(setq etaf-screensaver-idle-delay 300
      etaf-screensaver-program
      '(:order shuffle :scenes (matrix snow donut plasma)))
(etaf-screensaver-mode 1)
```

- `M-x etaf-screensaver-start`: start now, using the same configured program.
- `M-x etaf-screensaver-mode`: enable or disable automatic idle presentation.
- `M-x etaf-screensaver-stop`: explicit, idempotent dismissal.

The first wake event is consumed, not replayed into your document. Clicks wake
on button release so the rest of the click cannot activate restored controls.
Automatic activation avoids an active minibuffer and unfocused or hidden frames.
The animation adapts to the available character grid; tiny windows clip artwork
instead of shrinking its characters. No additional Emacs frame is created.

## Presentation

Keep the same works and choose how they appear:

```elisp
(setq etaf-screensaver-program '(:pack ink)
      etaf-screensaver-presentation 'card)
```

`full` fills the canvas, `card` frames a work on a mat, `band` adds a cinema
strip and clock, and `mosaic` plays up to four independent works concurrently.
Nil uses each pack's suggested presentation. Item/group overrides allow a
mixed program. A 64×24 drawable character grid is the recommended minimum;
narrow walls stack their tiles and smaller windows deliberately clip content.

## Playback configuration

A program is a scene, a configured scene item, or a group of programs.
Groups support `sequential`, `shuffle` (each child once per bag) and `random`
(with replacement). The program repeats until input wakes the editor.

```elisp
;; Randomly order two groups; preserve the order inside the first group.
(setq etaf-screensaver-program
      '(:order shuffle
        :scenes ((:order sequential :scenes (matrix starfield))
                 (:order random :count 3 :scenes (snow plasma donut)))))

;; Scene-specific defaults; a program item can override them.
(setq etaf-screensaver-scene-options
      '((matrix :duration 20 :params ((speed . 5)))
        (donut :duration 40 :params ((speed . 4) (detail . fine)))))
```

The default program rotates four bundled style packs — neon (mesh, beams and
code flow), space (black holes, lightning, fireworks), ink (dark text on a
cream page) and ember (warm particles and falling sand). Every selected pack's
works are included. Recordings use their natural duration; a mosaic page holds
until its longest work ends, looping shorter works. Dismissal remembers the
current work/page, not an exact frame within it.
See the [manual](docs/manual.md) for program composition, style packs,
durations, frame-rate caps, repeatable seeds, custom scene files,
recorded-animation import and callback authoring. Recordings can be text
(Terminal Text Effects) or baked images (MilkDrop via butterchurn, shader or
sketch previews); the manual explains how to bake and trim a bundle without
putting it in version control.
The [entry Commentary](etaf-screensaver.el) is the supported API inventory.

## Development

```sh
make check          # structure, compilation, public acceptance and API bindings
make gui SERVER=... # maintained scenario in an owned graphical Emacs server
```

The GUI scenario covers scene rendering, all four presentations across wide,
ordinary, narrow and short windows, text/image composition, cross-style rounds
and native command-loop wake routing. Actual automatic activation and physical mouse input require a focused
idle/input pass; background screenshots do not certify that interaction.

From the enclosing workspace, measure autonomous frame cadence with:

```sh
python3 scripts/performance.py run --mode batch \
  --scenario-file etaf-apps/etaf-screensaver/benchmarks/performance-scenarios.el \
  --load-path etaf-apps/etaf-screensaver --scenario 'etaf-screensaver.frame.*'
```

A sample includes waiting for the next frame, computation and publication.
It is not the retired manual-step workload. See [architecture](docs/architecture.md)
for ownership and cleanup invariants.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
