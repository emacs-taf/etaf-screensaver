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

The engine owns a page's composed frame and the independent scene states,
random streams and content rectangles within it. The playlist expands finite
selections first, then groups consecutive mosaic works into pages of at most
four without crossing pack boundaries. Partial pages do not fabricate works.
The presentation layout is the single source of content rectangles for both
callback sizing and composition; a wall is not a sliced single-scene frame.
Only the parent owns a mounted Runtime. Color-only changes are meaningful:
publication compares text properties as well as characters. Full-canvas works
inherit the Host background directly. Framed works use a read-only mat, border
and caption template, rebuilt only for a new page, viewport or clock minute;
its rows are split into static fragments and work-row slots. Each animation
row concatenates these once, without recropping an already placed neighbor's
text or image runs. Exact-width rows can be reused, but adding page-specific
faces first copies the source so a recording's
cached strings do not acquire another presentation's colors.

Each scene renders its own frame text.
Canvas cells are character vectors, so writes do not depend on UTF-8 byte
width. Composition preserves wide-character continuation cells and merges
adjacent colors. The expression interpreter evaluates only its whitelist;
common unary/binary arithmetic does not allocate an argument list per
expression. A dense field builds closures over that same whitelist and reuses
exact subexpression values along invariant spatial/time axes. Its caches and
coordinate bindings belong to the field and are recreated on resize. Changing
globals refresh per render; random calls are never cached, and conditional
branches remain lazy. Scene data is never evaluated as Lisp, and the environment
cannot escape through the expression whitelist. The engine
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
layer scales each frame to fit the canvas, centers it on whole character rows and crops it per row with a `display`
slice, the same retained Host boundary ETAF video uses. A display run reserves
its full cell footprint, with a fractional-width spacer for pixel rounding;
neighboring tile borders therefore stay aligned without stretching the image. The engine flushes the previous frame from Emacs's image cache
after the next one is committed and flushes remaining images on teardown.
Thus long playback retains only the currently displayed page's decoded frames.
Baking is a development step (`scripts/bake-canvas-frames.mjs`): it renders
a browser canvas offline and writes still frames. Renderer adapters use
upstream Butterchurn and Vanta, a virtual clock and a seeded RNG; external
URL canvases instead use real time. The baker owns one CDP tab and a staging
directory, bounds requests and output, validates canvas dimensions/MIME and
commits by rename. Loop crossfades happen there, not on the Emacs input path.
`scripts/bake-gallery.mjs` applies the data recipe, delegates each work to the
baker and generates public `.esr` specs and independent pack configuration.
The image provider rejects paths leaving the bundle and bounds manifest,
canvas, frame count and encoded size before import. It is not a decoder
sandbox. The application never runs a browser, shader or external decoder at
playback.

### Offline baking protocol (version 1)

The CLI uses a local Chrome CDP HTTP endpoint: `PUT /json/new?about:blank`
allocates its one owned target; the returned WebSocket carries numbered
`Runtime.enable`, `Page.enable`, `Emulation.setDeviceMetricsOverride`,
`Page.navigate` and `Runtime.evaluate` requests. Replies resolve by id;
protocol errors, exception events, console errors, socket loss and deadlines
fail the operation. Cleanup uses `/json/close/<owned-id>` and never closes
another target. The bounded fixture peer in `tests/tools` speaks these same
HTTP/WebSocket envelopes, including failure paths, without a browser or
network service. Actual upstream renderers require a separate real bake.

A renderer adapter exposes names, start and per-frame advance inside the
owned page. Capture validates its canvas and MIME; advance/capture share one
browser task so WebGL cannot clear the drawing buffer between them. The
output contract is a version-1 frame manifest plus basename-only stills.
Upstream attribution is metadata, never executable scene configuration.
A collection recipe contains defaults, works and pack data; its runner only
composes the baker and public reel/pack formats. It cannot change the playback
program, start Emacs, or run a renderer during presentation.

## Presentation lifecycle

Start validates and prepares the initial scene before replacing windows.
Only one presentation may own the editor at a time; a repeated start returns
its existing buffer without replacing the saved window configuration.
The presentation saves the frame's window configuration, caller buffer,
mouse tracking and any toolbar/tab-bar setting it changes. It mounts a
canvas-only view in an ephemeral buffer, with no mode line, header, cursor or
interactive scene controls. It does not create or activate a frame.

One single-shot animation timer advances every work's elapsed time, selects
the next page when its duration expires and publishes the composed frame.
Scheduling subtracts time already spent rendering from the next frame interval;
missed deadlines skip waiting rather than replaying a burst of old ticks.
A mosaic page lasts for its longest work; recorded children follow their own
timing and loop independently. It schedules a successor only
if it still owns the active presentation. Scene boundaries and resize update
reactive view inputs; ordinary animation publishes just retained canvas text.
If the window disappears, the buffer dies, the frame is deleted or focus is
lost, the presentation is released rather than running invisibly. Focus loss
means an observed true-to-false transition on the owning frame, not a global
notification while a manual background preview is already unfocused.

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

Configured playback retains its current page, remaining queue, scene seed and
program random state across dismissal, restarting that page from its beginning
on wake. It compares a newly compiled effective program and configured seed to
the saved snapshot before reuse. Changed packs/options/registrations invalidate
it. Explicit previews do not consume or overwrite that configured position.

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
