;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver.el --- Idle generative screensavers for Emacs

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1"))
;; Keywords: multimedia, convenience
;; URL: https://github.com/emacs-taf/etaf-screensaver

;;; Commentary:
;; A screensaver, not an editor: only animation is visible.  Keyboard input,
;; mouse movement, a click or wheel input dismisses it and restores the prior
;; window configuration.  Settings belong in Emacs Lisp or Customize.
;;
;; Example:
;;   (require 'etaf-screensaver)
;;   (setq etaf-screensaver-idle-delay 300
;;         etaf-screensaver-program
;;         '(:order shuffle :scenes (matrix snow donut plasma)))
;;   (etaf-screensaver-mode 1)
;;
;; Automatic mode owns one idle watcher and a rearming hook.  A presentation
;; owns one animation timer, a transient input map and an ephemeral buffer;
;; stopping releases all of these.  No child process is started.  This is not
;; a security lock.  Callbacks supplied by scene authors must be pure: they
;; may not create processes/timers or alter editor state.  A registered reel
;; reads its recording once when its scene starts; no other scene callback
;; performs I/O.
;;
;; Only the following declarations are public.  Unlisted symbols are private.
;; See docs/manual.md for playback composition, configuration and scene specs.
;;
;; Function: etaf-screensaver-mode (&optional arg)
;;;###autoload (autoload 'etaf-screensaver-mode "etaf-screensaver" nil t)
;; Toggle automatic presentation after the configured idle interval.
;; Positive ARG enables, nonpositive ARG disables.  Disabling also dismisses
;; an active presentation.  Repeated enabling replaces, not stacks, watchers.
;; The automatic path avoids minibuffer input and unfocused/hidden frames.
;;
;; Function: etaf-screensaver-start (&optional program)
;;;###autoload (autoload 'etaf-screensaver-start "etaf-screensaver" nil t)
;; Present PROGRAM, defaulting to etaf-screensaver-program, in the selected
;; frame and return its buffer.  Starting while active returns the existing
;; buffer.  Invalid configuration leaves the original windows unchanged;
;; errors during takeover restore them before signaling.  Input is consumed
;; rather than replayed into the restored buffer.
;;
;; Function: etaf-screensaver-stop ()
;;;###autoload (autoload 'etaf-screensaver-stop "etaf-screensaver" nil t)
;; Dismiss the presentation and return nil.  Safe to call repeatedly.
;; Restore windows and mouse tracking; release the Runtime, buffer, animation
;; timer and wake hooks/map.  Automatic mode, if enabled, waits a fresh idle
;; interval.  Disabling the mode releases that watcher too.
;;
;; Function: etaf-screensaver-status ()
;;;###autoload (autoload 'etaf-screensaver-status "etaf-screensaver" nil nil)
;; Return :active and :automatic, plus the active scene's :scene, :buffer name,
;; zero-based :index, :seed, :ticks, :elapsed, :columns, :rows, :frame-rate,
;; copied :params alist and :up-next scene identifiers for this round.
;; Useful for configuration inspection and lifecycle integration.
;;
;; Function: etaf-screensaver-scenes ()
;;;###autoload (autoload 'etaf-screensaver-scenes "etaf-screensaver" nil nil)
;; Return registered scene identifiers in registration order.
;;
;; Function: etaf-screensaver-scene-info (scene)
;;;###autoload (autoload 'etaf-screensaver-scene-info "etaf-screensaver" nil nil)
;; Return SCENE's :id, :title, :summary, :tags, :frame-rate and :params.
;; SCENE accepts an identifier, its string name or displayed title.  Callback
;; implementations stay private.  Unknown scenes signal etaf-screensaver-error.
;;
;; Macro: etaf-screensaver-define-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-scene "etaf-screensaver" nil nil)
;; Register a pure callback scene under ID; replace an existing registration
;; in place.  PROPERTIES supplies :create, :step, :render, optional :resize,
;; :title, :summary, :tags, :frame-rate, :background and :params descriptors.
;; CREATE returns state, STEP mutates it, RENDER returns row strings or a
;; newline-separated string, and RESIZE returns resized state.  Each receives
;; a context with dimensions, seed, tick, elapsed time, dt and parameter/random
;; accessors; see the macro docstring and manual.  Pointer input always wakes,
;; never enters a scene.  Registrations affect subsequent starts.
;;
;; Function: etaf-screensaver-register-scene (spec)
;;;###autoload (autoload 'etaf-screensaver-register-scene "etaf-screensaver" nil nil)
;; Register inert SPEC data, optionally wrapped as (etaf-scene ...).
;; The plist holds :id, metadata, :params and a nonempty :layers stack.
;; Built-in kinds are life, rain, sand, particles, field, text and banner.
;; Expressions use a whitelist, never eval.  Invalid specs signal
;; etaf-screensaver-error.  An existing identifier is replaced in place.
;;
;; Function: etaf-screensaver-load-scenes (&optional directories)
;;;###autoload (autoload 'etaf-screensaver-load-scenes "etaf-screensaver" nil t)
;; Load .esc scene files and .esr reel files from DIRECTORIES, defaulting to
;; scene-directories, and return the number loaded.  Later directories
;; override earlier ids.  Bad files report a message and are skipped; other
;; files still load.  Load/reload outside presentation; changes are used by
;; subsequent starts.
;;
;; Function: etaf-screensaver-define-reel-provider (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-reel-provider "etaf-screensaver" nil nil)
;; Register the recorded-animation provider ID with PROPERTIES.
;; PROPERTIES is a plist with :title and :license display strings,
;; :extensions file name suffixes for batch import, :match (lambda (file))
;; recognizing the format and :read (lambda (file)) returning the recording
;; as :width, :height, :frame-rate, :frames and optional :durations
;; (seconds per frame), :ansi (frame text carries SGR runs) and :source.
;; Re-registering an ID replaces it in place.  The built-in `tte' provider
;; reads Terminal Text Effects recordings without running the tool.
;;
;; Function: etaf-screensaver-register-reel (spec)
;;;###autoload (autoload 'etaf-screensaver-register-reel "etaf-screensaver" nil nil)
;; Register the recorded animation described by SPEC as a scene.
;; SPEC is a plist, optionally wrapped as (etaf-reel ...), with :id,
;; :provider and :recording plus optional :title, :summary, :tags, :width,
;; :height, :frame-rate, :frame-count, :source, :license and :background.
;; A relative :recording resolves against the reel file's directory.  The
;; scene reads the recording when it is created, so an unused reel holds only
;; metadata; playback follows the recording's own per-frame timing and
;; centers its fixed canvas, cropping when the window is smaller.  Invalid
;; specs signal etaf-screensaver-error.  Registering the same :id replaces
;; the previous scene in place.
;;
;; Function: etaf-screensaver-import-recording (file &optional destination)
;;;###autoload (autoload 'etaf-screensaver-import-recording "etaf-screensaver" nil t)
;; Import one recording FILE as a reel and return its report plist.
;; DESTINATION defaults to the user scene directory.  The native recording is
;; copied next to a new .esr reel spec that names its provider, dimensions,
;; frame count and license; it is validated first and never transcoded.
;; The report holds :file, :status `imported', :provider, :title, :output,
;; :recording, :width, :height, :frame-rate, :frame-count, :colors,
;; :attributes, :license and :source.  A file no provider recognizes or a
;; recording that fails validation signals etaf-screensaver-error and writes
;; nothing.
;;
;; Function: etaf-screensaver-import-directory (directory &optional destination)
;;;###autoload (autoload 'etaf-screensaver-import-directory "etaf-screensaver" nil t)
;; Import every recording DIRECTORY holds and return a report plist.
;; Candidate files use the extensions registered by reel providers.  An
;; unrecognized file is skipped; a recognized file that fails validation is
;; reported as failed.  Reels are written to DESTINATION (default: the user
;; scene directory), and the report holds :directory, :destination and the
;; :imported, :skipped and :failed lists so callers can audit compatibility,
;; dimensions, color use and license before playing anything.  Register the
;; new reels with etaf-screensaver-load-scenes afterwards.
;;
;; Variable: etaf-screensaver-idle-delay
;; Positive idle seconds before automatic presentation, default 300.
;; Re-enable the mode after changing it to re-arm immediately.
;;
;; Variable: etaf-screensaver-program
;; Repeating program: a scene symbol, a scene item plist, or a nested group.
;; An item has :scene and optional :duration, :frame-rate and :params alist.
;; A group has :order sequential/shuffle/random, :scenes children and optional
;; :count selections (default child count).  Shuffle draws without replacement
;; within each bag; random allows repeats.  Groups nest to select sequences.
;;
;; Variable: etaf-screensaver-scene-duration
;; Default positive seconds per scene, default 30.  Items override this.
;;
;; Variable: etaf-screensaver-scene-options
;; Per-scene defaults, e.g. ((matrix :params ((speed . 5)) :duration 20)).
;; Program item values override these; parameter alists merge by key.
;;
;; Variable: etaf-screensaver-max-frame-rate
;; Positive frame-rate cap up to 120, default 30.  Scene/item rates are capped.
;;
;; Variable: etaf-screensaver-seed
;; Integer for reproducible scene and program choices, or nil for fresh starts.
;;
;; Variable: etaf-screensaver-background
;; Default canvas color, overridden by a scene's own background.
;;
;; Variable: etaf-screensaver-scene-directories
;; Ordered scene directories.  Defaults to bundled scenes and the user's
;; etaf-screensaver/scenes directory.  Load files before starting playback.
;;
;; Error: etaf-screensaver-error
;; Invalid scene or playback configuration.  A start validates before takeover;
;; a runtime failure tears down the presentation and reports the error, disabling
;; automatic mode to avoid an idle error loop.

;;; Code:
(add-to-list 'load-path
             (expand-file-name "lisp"
                               (file-name-directory (or load-file-name buffer-file-name))))
(require 'etaf-screensaver-app)

(provide 'etaf-screensaver)
;;; etaf-screensaver.el ends here
