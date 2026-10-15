# Screensaver architecture

## Ownership and dependency direction

The application depends on ETAF's public Runtime and retained Host APIs.
ETAF owns rendering and its own mount resources; the application owns idle
policy, input dismissal and playback. No catalog UI is needed. Scene authors
supply data specs or pure callbacks, not editor buffers, processes or timers.

The scene registry validates descriptions. The playlist compiler validates
all branches before takeover and snapshots effective scene descriptions,
parameters, durations, backgrounds and frame-rate caps. Finite groups choose
children in order, from shuffled bags or with replacement; nesting composes
whole sequences. Bounds on depth, group size and round expansion prevent an
accidental unbounded program from occupying the input thread.

The engine owns one scene's state, random stream, viewport and frame text.
Canvas cells are character vectors, so writes do not depend on UTF-8 byte
width. Composition preserves wide-character continuation cells and merges
adjacent colors. The expression interpreter evaluates only its whitelist;
argument traversal does not allocate a closure per expression. The engine
owns no timer or input handler.

## Recorded animations

Reels adapt external animation recordings without reimplementing their
algorithms. A provider turns one native format into frame strings and
metadata; it is registered by id with match and read functions, extension
hints and a license. The built-in `tte` provider validates Terminal Text
Effects recordings, a zlib stream of tagged records, and converts SGR runs
into the same face properties the canvas uses. No provider runs a process:
playback reads bytes and leaves the recording in its native format.

The reel layer owns provider-independent behavior: per-frame timing from the
recording, looping, lazy per-frame SGR conversion, wide-character aware
center fitting and a small cache of recent unchanged reads. Registration
validates metadata and the referenced file but not frames, so an unused reel
costs only its spec; the first playback verifies frame shape. Importing
copies a recording beside a `.esr` spec and reports compatibility,
dimensions, color depths and license per file instead of claiming universal
support. The loader scans `.esr` specs beside `.esc` scenes and skips a
broken spec without disturbing the others.

Text recordings render as canvas rows; image recordings take a second path.
The `frames` provider returns image file names and a pixel size; the reel
layer scales each frame to fit the canvas, centers it and crops it per
character row with a `display` slice, the same retained Host boundary ETAF
video uses. The engine flushes the previous frame from Emacs's image cache
after the next one is committed, so long playback keeps one decoded frame.
Baking is a development step (`scripts/bake-canvas-frames.mjs`): it renders
a browser canvas offline and writes still frames. The application never runs
a browser, shader or decoder at playback.

## Presentation lifecycle

Start validates and prepares the initial scene before replacing windows.
Only one presentation may own the editor at a time; a repeated start returns
its existing buffer without replacing the saved window configuration.
The presentation saves the frame's window configuration, caller buffer,
mouse tracking and any toolbar/tab-bar setting it changes. It mounts a
canvas-only view in an ephemeral buffer, with no mode line, header, cursor or
interactive scene controls. It does not create or activate a frame.

One single-shot animation timer advances time, selects the next item when its
duration expires and publishes the next frame. It schedules a successor only
if it still owns the active presentation. Scene boundaries and resize update
reactive view inputs; ordinary animation publishes just retained canvas text.
If the window disappears, the buffer dies, the frame is deleted or focus is
lost, the presentation is released rather than running invisibly.

A transient map plus a pre-command hook consumes wake input. Mouse tracking
is enabled only while presenting. Button-down is consumed before dismissal
on release, avoiding a trailing click on the restored application. Other
keys, mouse movement and wheel input dismiss immediately. No wake input is
requeued into the editor.

Stop clears active ownership first, making callbacks from unmount, keymap
release and buffer death safe to reenter. It cancels the animation timer,
removes wake hooks and focus observation, restores mouse tracking and the
frame/window snapshot, unmounts the Runtime and kills the temporary buffer.
Cleanup runs on failed startup and rendering failure too; an animation failure
also disables automatic mode and reports its cause instead of retrying in an
idle error loop.

## Automatic idle mode

Automatic mode separately owns one single-shot idle timer and a post-command
rearming hook. Presentation suspends that watcher. On wake, a fresh interval
is armed; if mouse-only input did not reset Emacs's native idle clock, the
threshold includes its current idle duration. Subsequent ordinary commands
rearm relative to their fresh idle period. Hidden/unfocused frames and active
minibuffers defer activation. Disabling the mode removes both watcher and
rearming hook and dismisses any presentation.

There are no external processes, recurring hidden-frame probes or permanent
mouse-tracking changes. The idle watcher is intentional only while the user
has enabled automatic mode.

## Verification boundaries

Public acceptance drives real timers, the presentation API and native command
loop events. It checks seeded programs, Unicode output, configuration errors,
window restoration and Emacs timer/process inventories. The graphical scenario
checks every bundled scene, several window shapes and input dismissal, with
separate screenshot review. Real automatic activation and OS mouse delivery
require a focused idle/input pass; background evidence cannot establish them.
Performance scenarios measure autonomous frame cadence including timer wait,
not a private engine step or the removed workspace controls.
