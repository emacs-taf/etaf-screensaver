;;; etaf-screensaver.el --- Generative art scenes as an Emacs screensaver -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0") (ebox "3.0.0"))
;; Keywords: games, multimedia, convenience
;; URL: https://github.com/emacs-taf/etaf-screensaver

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-screensaver) after adding this
;; repository root and the ETAF, ETAF UI, Ebox and ECSS roots to `load-path'.
;;
;; A scene is a small generative program registered under an identifier.  The
;; mainstream way to add one is data: `etaf-screensaver-define-scene' describes
;; pure Lisp callbacks, `etaf-screensaver-register-scene' interprets an inert
;; spec, and `etaf-screensaver-load-scenes' reads one `(etaf-scene ...)' form
;; per *.esc file from `etaf-screensaver-scene-directories'.  A spec stacks
;; generic layers (life, rain, sand, particles, field, text) and drives them
;; with a small pure expression language, so a new screensaver is a data file
;; and never a new Lisp file; a scene that outgrows the DSL still has the
;; callbacks.  The workspace renders the canvas through ETAF's retained Host
;; boundary, so a running scene publishes frames without re-rendering the
;; application; an open parameter panel edits the scene through the catalog's
;; Slider, Segmented and Switch Components.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  This Commentary is the authoritative export
;; list; implementations and precise docstrings remain beside their
;; definitions.
;;
;; Function: etaf-screensaver-open (&optional scene buffer-name)
;;;###autoload (autoload 'etaf-screensaver-open "etaf-screensaver" nil t)
;; Mount the workspace in BUFFER-NAME, selecting SCENE, and return the buffer.
;;
;; SCENE is a registered identifier, its symbol name or its displayed title;
;; without one `etaf-screensaver-default-scene' is opened.  BUFFER-NAME
;; defaults to `etaf-screensaver-buffer-name'.  An existing Runtime in that
;; buffer is replaced.
;;
;; Function: etaf-screensaver-close (&optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-close "etaf-screensaver" nil t)
;; Unmount the workspace in BUFFER-NAME and kill its buffer.
;;
;; Function: etaf-screensaver-present (&optional scene)
;;;###autoload (autoload 'etaf-screensaver-present "etaf-screensaver" nil t)
;; Present SCENE as a full-window screensaver and return its buffer.
;;
;; The current window configuration is saved, the chrome and mode line are
;; hidden and the scene cycle is enabled, so scenes switch every
;; `etaf-screensaver-cycle-seconds'.  The first key afterwards restores the
;; configuration and closes the presentation buffer.
;;
;; Function: etaf-screensaver-scenes ()
;;;###autoload (autoload 'etaf-screensaver-scenes "etaf-screensaver" nil t)
;; Return the registered scene identifiers in display order.
;;
;; Function: etaf-screensaver-scene-info (scene)
;;;###autoload (autoload 'etaf-screensaver-scene-info "etaf-screensaver" nil nil)
;; Return SCENE's public description as a plist.
;;
;; SCENE is an identifier, its symbol name or its displayed title.  The plist
;; holds :id, :title, :summary, :tags, :frame-rate and :params; the scene's
;; callbacks stay internal.
;;
;; Macro: etaf-screensaver-define-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-scene "etaf-screensaver" nil nil)
;; Register a code scene under ID from PROPERTIES and return it.
;;
;; PROPERTIES is a plist with :title, :summary, :tags, :frame-rate,
;; :background, :params, :create, :step, :render and the optional :resize and
;; :pointer.  Registering the same ID again replaces the previous description
;; in place.  See the macro's docstring for the callback contracts and the
;; context plist passed to every callback.  Most scenes should use
;; `etaf-screensaver-register-scene' or a spec file instead; this macro is
;; the escape hatch for scenes the DSL cannot express.
;;
;; Function: etaf-screensaver-register-scene (spec)
;;;###autoload (autoload 'etaf-screensaver-register-scene "etaf-screensaver" nil nil)
;; Register the scene described by the inert SPEC plist and return it.
;;
;; SPEC holds :id, :title, :summary, :tags, :frame-rate, :background, :params
;; and :layers.  Each layer names a registered kind -- life, rain, sand,
;; particles, field or text -- and its properties may be literals, parameter
;; symbols or expressions in the pure spec language (numbers, strings, `if',
;; `and', `or', `not' and the arithmetic and trigonometric functions;
;; variables are the scene parameters, the layer's fields and w, h, cx, cy,
;; t, dt, tick and i).  Registering the same :id again replaces the previous
;; scene in place.
;;
;; Function: etaf-screensaver-load-scenes (&optional directories)
;;;###autoload (autoload 'etaf-screensaver-load-scenes "etaf-screensaver" nil t)
;; Load every scene spec file in DIRECTORIES and return how many loaded.
;;
;; DIRECTORIES defaults to `etaf-screensaver-scene-directories'.  Every
;; *.esc file holds one `(etaf-scene ...)' form; later directories replace a
;; scene whose :id matches, so a user directory overrides a bundled scene.
;; A file that fails to read or validate reports and is skipped.
;;
;; Function: etaf-screensaver-reload-scenes ()
;;;###autoload (autoload 'etaf-screensaver-reload-scenes "etaf-screensaver" nil t)
;; Reload the scene spec files and refresh a mounted scene in place.
;;
;; An edited or newly dropped .esc file appears immediately; when the mounted
;; scene still exists its spec is rebuilt without switching away.  Return how
;; many files loaded.
;;
;; Function: etaf-screensaver-pause (&optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-pause "etaf-screensaver" nil t)
;; Pause the workspace in BUFFER-NAME and stop its frame timer.
;;
;; Function: etaf-screensaver-resume (&optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-resume "etaf-screensaver" nil t)
;; Resume the workspace in BUFFER-NAME and re-arm its frame timer.
;;
;; Function: etaf-screensaver-step (&optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-step "etaf-screensaver" nil t)
;; Pause the workspace in BUFFER-NAME and advance exactly one frame.
;;
;; Function: etaf-screensaver-reset (&optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-reset "etaf-screensaver" nil t)
;; Recreate the scene in BUFFER-NAME at the same seed.
;;
;; Function: etaf-screensaver-select-scene (scene &optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-select-scene "etaf-screensaver" nil t)
;; Switch the workspace in BUFFER-NAME to SCENE.
;;
;; Function: etaf-screensaver-set-param (key value &optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-set-param "etaf-screensaver" nil t)
;; Set the scene parameter KEY to VALUE in BUFFER-NAME and repaint its frame.
;;
;; Function: etaf-screensaver-set-frame-rate (frame-rate &optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-set-frame-rate "etaf-screensaver" nil t)
;; Set the workspace in BUFFER-NAME to FRAME-RATE frames per second.
;;
;; Function: etaf-screensaver-set-seed (seed &optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-set-seed "etaf-screensaver" nil t)
;; Set the workspace in BUFFER-NAME to SEED and recreate its scene.
;;
;; Function: etaf-screensaver-status (&optional buffer-name)
;;;###autoload (autoload 'etaf-screensaver-status "etaf-screensaver" nil nil)
;; Return the workspace in BUFFER-NAME as a status plist.
;;
;; The plist holds :scene, :title, :status, :frame-rate, :seed, :ticks,
;; :elapsed, :columns, :rows and :notice.
;;
;; Function: etaf-screensaver-idle-mode (&optional arg)
;;;###autoload (autoload 'etaf-screensaver-idle-mode "etaf-screensaver" nil t)
;; Toggle presenting a screensaver after `etaf-screensaver-idle-delay' idle.
;;
;; Error: etaf-screensaver-error
;; Signaled for invalid scene specs, registrations and control calls.
;;
;; Variable: etaf-screensaver-buffer-name
;; Buffer name used when a caller does not name one.
;;
;; Variable: etaf-screensaver-default-scene
;; Scene identifier opened when a caller does not name one.
;;
;; Variable: etaf-screensaver-cycle-seconds
;; Seconds a scene stays before presentation switches to the next one.
;;
;; Variable: etaf-screensaver-idle-delay
;; Seconds of idle time before `etaf-screensaver-idle-mode' presents.
;;
;; Variable: etaf-screensaver-scene-directories
;; Directories scanned for scene spec files, in order.
;;
;; Every *.esc file holds one `(etaf-scene ...)' form; a later directory
;; replaces a scene whose :id already exists, so the user directory overrides
;; a bundled scene of the same id.

;;; Code:

;; Consumers that only add this repository root to `load-path' reach the
;; submodules through this entry, so the `lisp/' directory is added here
;; instead of asking every caller for it.
(add-to-list 'load-path
             (expand-file-name "lisp"
                               (file-name-directory (or load-file-name
                                                        buffer-file-name))))

(require 'etaf-screensaver-app)

(provide 'etaf-screensaver)
;;; etaf-screensaver.el ends here
