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
