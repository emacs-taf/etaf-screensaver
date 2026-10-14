;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-app.el --- Idle presentation and input-owned teardown

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One presentation owns one animation timer, one transient input map and one
;; window configuration.  Stop is idempotent and clears ownership before any
;; callback can reenter it.  Automatic mode separately owns one idle watcher;
;; it never starts a process and suspends its watcher during presentation.

;;; Code:
(require 'cl-lib)
(require 'face-remap)
(require 'etaf)
(require 'etaf-screensaver-playlist)
(require 'etaf-screensaver-engine)
(require 'etaf-screensaver-dsl)
(require 'etaf-screensaver-layers)
(require 'etaf-screensaver-banner)
(require 'etaf-screensaver-loader)
(require 'etaf-screensaver-import)
(require 'etaf-screensaver-tte)
(require 'etaf-screensaver-scene-donut)
(require 'etaf-screensaver-views)

(defcustom etaf-screensaver-idle-delay 300
  "Seconds without Emacs input before automatic presentation.
Set this before enabling `etaf-screensaver-mode'.  Enabling the mode again
re-arms its single watcher with the current value.  Mouse movement during a
presentation also starts a fresh idle interval when it dismisses the scene."
  :type 'number :group 'etaf-screensaver)

(cl-defstruct (etaf-screensaver--presentation (:constructor etaf-screensaver--presentation-new))
  session frame window configuration origin-buffer timer exit-map track-mouse frame-parameters face-cookie
  program queue random-state seed index deadline last-time)

(defvar etaf-screensaver--active nil)
(defvar etaf-screensaver--idle-timer nil)
(defvar etaf-screensaver-mode nil)

(defun etaf-screensaver--cancel-idle ()
  "Release the automatic mode's pending watcher."
  (when (timerp etaf-screensaver--idle-timer)
    (cancel-timer etaf-screensaver--idle-timer))
  (setq etaf-screensaver--idle-timer nil))

(defun etaf-screensaver--arm-idle ()
  "Arm one idle interval after this input or mouse-only wake."
  (etaf-screensaver--cancel-idle)
  (when (and etaf-screensaver-mode (not etaf-screensaver--active))
    (let ((idle (current-idle-time)))
      ;; Mouse motion need not reset Emacs's own idle clock.  Offset the
      ;; deadline in that case; the next ordinary command resets it normally.
      (setq etaf-screensaver--idle-timer
            (run-with-idle-timer
             (+ etaf-screensaver-idle-delay (if idle (float-time idle) 0)) nil
             #'etaf-screensaver--idle-fire)))))

(defun etaf-screensaver--idle-fire ()
  "Present only in an available, focused Emacs frame."
  (setq etaf-screensaver--idle-timer nil)
  (when (and etaf-screensaver-mode (not etaf-screensaver--active))
    (if (or (active-minibuffer-window) executing-kbd-macro (input-pending-p)
            (not (eq (frame-visible-p (selected-frame)) t))
            (and (display-graphic-p) (not (eq (frame-focus-state) t))))
        (etaf-screensaver--arm-idle)
      (condition-case problem
          (etaf-screensaver-start)
        (error
         (etaf-screensaver-mode -1)
         (display-warning 'etaf-screensaver (error-message-string problem) :warning))))))

(defun etaf-screensaver--wake-before-command ()
  "Consume input while presenting, then restore the previous interface."
  (when etaf-screensaver--active
    ;; A click comprises down and up.  Consume the down event and dismiss on
    ;; up, so a trailing click cannot activate a restored application's UI.
    (unless (memq 'down (event-modifiers last-command-event))
      (etaf-screensaver-stop))
    (setq this-command #'ignore)))

(defun etaf-screensaver--wake ()
  "Dismiss the presentation without replaying the wake event."
  (interactive)
  (etaf-screensaver-stop))

(defun etaf-screensaver--window-changed ()
  "Release a presentation whose owning window or frame disappeared."
  (when-let* ((owner etaf-screensaver--active))
    (let ((window (etaf-screensaver--presentation-window owner))
          (buffer (etaf-screensaver--session-buffer
                   (etaf-screensaver--presentation-session owner))))
      (unless (and (window-live-p window) (eq (window-buffer window) buffer)
                   (eq (frame-visible-p (etaf-screensaver--presentation-frame owner)) t))
        (etaf-screensaver-stop)))))

(defun etaf-screensaver--focus-changed ()
  "Release the presentation when its frame loses keyboard focus."
  (when (and etaf-screensaver--active
             (eq (frame-focus-state
                  (etaf-screensaver--presentation-frame etaf-screensaver--active)) nil))
    (etaf-screensaver-stop)))

(defun etaf-screensaver--frame-deleted (frame)
  "Release the presentation if its FRAME is being deleted."
  (when (and etaf-screensaver--active
             (eq frame (etaf-screensaver--presentation-frame etaf-screensaver--active)))
    (etaf-screensaver-stop)))

(defun etaf-screensaver--buffer-killed ()
  "Release the presentation when its buffer is killed externally."
  (when (and etaf-screensaver--active
             (eq (current-buffer)
                 (etaf-screensaver--session-buffer
                  (etaf-screensaver--presentation-session etaf-screensaver--active))))
    (etaf-screensaver-stop)))

(defun etaf-screensaver--columns (window)
  "Return drawable columns in WINDOW, reserving Emacs's end-of-line cell."
  (max 1 (1- (window-body-width window))))

(defun etaf-screensaver--canvas-face (owner)
  "Paint OWNER's unused edge cell with its scene background."
  (with-current-buffer (etaf-screensaver--session-buffer
                        (etaf-screensaver--presentation-session owner))
    (when (etaf-screensaver--presentation-face-cookie owner)
      (face-remap-remove-relative (etaf-screensaver--presentation-face-cookie owner)))
    (setf (etaf-screensaver--presentation-face-cookie owner)
          (face-remap-add-relative
           'default :background
           (plist-get (etaf-screensaver--session-item
                       (etaf-screensaver--presentation-session owner)) :background)))))

(defun etaf-screensaver--next (owner now)
  "Select OWNER's next item at wall time NOW."
  (unless (etaf-screensaver--presentation-queue owner)
    (setf (etaf-screensaver--presentation-queue owner)
          (etaf-screensaver--program-round (etaf-screensaver--presentation-program owner)
                                           (etaf-screensaver--presentation-random-state owner))))
  (let ((item (pop (etaf-screensaver--presentation-queue owner))))
    (cl-incf (etaf-screensaver--presentation-index owner))
    (etaf-screensaver--session-select
     (etaf-screensaver--presentation-session owner) item
     (+ (etaf-screensaver--presentation-seed owner) (etaf-screensaver--presentation-index owner)))
    (etaf-screensaver--canvas-face owner)
    (setf (etaf-screensaver--presentation-deadline owner) (+ now (plist-get item :duration)))))

(defun etaf-screensaver--arm-frame (owner)
  "Schedule OWNER's next frame only while it still owns the presentation."
  (when (eq owner etaf-screensaver--active)
    (let* ((session (etaf-screensaver--presentation-session owner))
           (rate (plist-get (etaf-screensaver--session-item session) :frame-rate)))
      (setf (etaf-screensaver--presentation-timer owner)
            (run-at-time (/ 1.0 rate) nil #'etaf-screensaver--tick owner)))))

(defun etaf-screensaver--tick (owner)
  "Render one live frame for OWNER; failures unwind the whole presentation."
  (setf (etaf-screensaver--presentation-timer owner) nil)
  (when (eq owner etaf-screensaver--active)
    (condition-case problem
        (progn
          (etaf-screensaver--window-changed)
          (when (eq owner etaf-screensaver--active)
            (let* ((session (etaf-screensaver--presentation-session owner))
                   (window (etaf-screensaver--presentation-window owner))
                   (now (float-time))
                   (dt (max 0 (- now (etaf-screensaver--presentation-last-time owner)))))
              (etaf-screensaver--session-resize
               session (etaf-screensaver--columns window) (max 1 (window-body-height window)))
              (if (>= now (etaf-screensaver--presentation-deadline owner))
                  (progn (etaf-screensaver--next owner now)
                         (etaf-screensaver--session-publish session))
                (etaf-screensaver--session-advance session dt))
              (setf (etaf-screensaver--presentation-last-time owner) now))
            (etaf-screensaver--arm-frame owner)))
      (quit (etaf-screensaver-stop))
      (error
       (etaf-screensaver-stop)
       ;; Do not repeatedly enter a broken scene while the user is idle.
       (when etaf-screensaver-mode (etaf-screensaver-mode -1))
       (display-warning 'etaf-screensaver (error-message-string problem) :warning)))))

(defun etaf-screensaver-start (&optional program)
  "Present PROGRAM, or `etaf-screensaver-program', and return its buffer.
Starting an already active presentation returns its buffer without replacing
its window snapshot.  Validate configuration before takeover.  Any failure
restores the interface and signals the original error.  Input is consumed;
keyboard input, mouse movement, a click or wheel input dismisses the scene.
This is a visual screensaver, not an operating-system security lock."
  (interactive)
  (if etaf-screensaver--active
      (etaf-screensaver--session-buffer
       (etaf-screensaver--presentation-session etaf-screensaver--active))
    (when (active-minibuffer-window)
      (user-error "Cannot start a screensaver while the minibuffer is active"))
    (etaf-screensaver--validate-options)
    (let* ((tree (etaf-screensaver--compile-program (or program etaf-screensaver-program)))
           (seed (or etaf-screensaver-seed (random most-positive-fixnum)))
           (rng (cl-make-random-state seed))
           (queue (etaf-screensaver--program-round tree rng))
           (item (pop queue))
           (frame (selected-frame))
           (configuration (current-window-configuration frame))
           (origin-buffer (current-buffer))
           (buffer (generate-new-buffer " *ETAF Screensaver*"))
           session owner)
      (condition-case problem
          (progn
            (setq session (etaf-screensaver--session-create
                           item seed (etaf-screensaver--columns (selected-window))
                           (max 1 (window-body-height)) buffer)
                  owner (etaf-screensaver--presentation-new
                         :session session :frame frame :configuration configuration
                         :origin-buffer origin-buffer
                         :program tree :queue queue :random-state rng :seed seed :index 0
                         :track-mouse track-mouse
                         :frame-parameters
                         (cl-loop for key in '(tab-bar-lines tool-bar-lines)
                                  for value = (frame-parameter frame key)
                                  when (and (numberp value) (> value 0))
                                  collect (cons key value))))
            (setq etaf-screensaver--active owner)
            (etaf-screensaver--cancel-idle)
            (switch-to-buffer buffer)
            (delete-other-windows)
            (setf (etaf-screensaver--presentation-window owner) (selected-window))
            (dolist (parameter (etaf-screensaver--presentation-frame-parameters owner))
              (set-frame-parameter frame (car parameter) 0))
            (set-window-margins nil 0 0)
            (set-window-fringes nil 0 0)
            (with-current-buffer buffer
              (setq-local mode-line-format nil header-line-format nil tab-line-format nil
                          cursor-type nil display-line-numbers nil
                          truncate-lines t show-trailing-whitespace nil
                          indicate-empty-lines nil)
              (add-hook 'kill-buffer-hook #'etaf-screensaver--buffer-killed nil t))
            (etaf-screensaver--session-resize session (etaf-screensaver--columns (selected-window))
                                             (max 1 (window-body-height)))
            (etaf-mount
             buffer (etaf-view
                     (etaf-screensaver-view
                      :session session
                      :on-close (lambda ()
                                  (when (eq owner etaf-screensaver--active)
                                    (etaf-screensaver-stop))))))
            (setf (etaf-screensaver--session-runtime session) (etaf-runtime-for-buffer buffer))
            (etaf-screensaver--canvas-face owner)
            (message nil)
            (let ((map (make-sparse-keymap)))
              (define-key map [t] #'etaf-screensaver--wake)
              (define-key map [mouse-movement] #'etaf-screensaver--wake)
              (setf (etaf-screensaver--presentation-exit-map owner)
                    (set-transient-map map (lambda () (eq owner etaf-screensaver--active)))))
            (setq track-mouse t)
            (add-hook 'pre-command-hook #'etaf-screensaver--wake-before-command)
            (add-hook 'window-configuration-change-hook #'etaf-screensaver--window-changed)
            (add-hook 'delete-frame-functions #'etaf-screensaver--frame-deleted)
            (add-function :after after-focus-change-function #'etaf-screensaver--focus-changed)
            (let ((now (float-time)))
              (setf (etaf-screensaver--presentation-last-time owner) now
                    (etaf-screensaver--presentation-deadline owner) (+ now (plist-get item :duration))))
            (etaf-screensaver--arm-frame owner)
            buffer)
        ((error quit)
         (if (and owner (eq owner etaf-screensaver--active))
             (etaf-screensaver-stop)
           (when (buffer-live-p buffer) (kill-buffer buffer)))
         (signal (car problem) (cdr problem)))))))

(defun etaf-screensaver-stop ()
  "Dismiss the screensaver, restore its windows and release its resources.
Idempotent.  No animation timer, transient keymap, mouse tracking change or
presentation buffer survives.  When automatic mode is enabled, only its
idle watcher and rearming hook remain, waiting a fresh idle interval."
  (interactive)
  (when-let* ((owner etaf-screensaver--active))
    ;; Clear ownership first: unmount, buffer death and map teardown can reenter.
    (setq etaf-screensaver--active nil)
    (when (timerp (etaf-screensaver--presentation-timer owner))
      (cancel-timer (etaf-screensaver--presentation-timer owner)))
    (setf (etaf-screensaver--presentation-timer owner) nil)
    (remove-hook 'pre-command-hook #'etaf-screensaver--wake-before-command)
    (remove-hook 'window-configuration-change-hook #'etaf-screensaver--window-changed)
    (remove-hook 'delete-frame-functions #'etaf-screensaver--frame-deleted)
    (remove-function after-focus-change-function #'etaf-screensaver--focus-changed)
    (setq track-mouse (etaf-screensaver--presentation-track-mouse owner))
    (when-let* ((exit (etaf-screensaver--presentation-exit-map owner)))
      (funcall exit))
    (let* ((session (etaf-screensaver--presentation-session owner))
           (buffer (etaf-screensaver--session-buffer session))
           (runtime (etaf-screensaver--session-runtime session))
           (frame (etaf-screensaver--presentation-frame owner))
           (restore-current (eq (current-buffer) buffer)))
      (unwind-protect
          (when (and runtime (etaf-runtime-mounted-p runtime)) (etaf-unmount runtime))
        (setf (etaf-screensaver--session-runtime session) nil)
        (when (frame-live-p frame)
          (with-selected-frame frame
            (when (etaf-screensaver--presentation-frame-parameters owner)
              (modify-frame-parameters frame (etaf-screensaver--presentation-frame-parameters owner)))
            (set-window-configuration (etaf-screensaver--presentation-configuration owner))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (remove-hook 'kill-buffer-hook #'etaf-screensaver--buffer-killed t))
          (kill-buffer buffer))
        (when restore-current
          (set-buffer (if (buffer-live-p (etaf-screensaver--presentation-origin-buffer owner))
                          (etaf-screensaver--presentation-origin-buffer owner)
                        (window-buffer (selected-window)))))
        (etaf-screensaver--arm-idle))))
  nil)

(defun etaf-screensaver-status ()
  "Return a bounded snapshot of automatic mode and the active presentation.
The plist contains :active, :automatic and, while active, :scene, :buffer,
:index (zero-based playlist position), :seed, :ticks, :elapsed, :columns,
:rows, :frame-rate, :params and :up-next (the remainder of this round).
The returned parameter alist is a copy; changing it does not configure playback."
  (let ((owner etaf-screensaver--active))
    (append (list :active (and owner t) :automatic (and etaf-screensaver-mode t))
            (when owner
              (let ((session (etaf-screensaver--presentation-session owner)))
                (list :scene (etaf-screensaver--scene-id (etaf-screensaver--session-scene session))
                      :buffer (buffer-name (etaf-screensaver--session-buffer session))
                      :index (etaf-screensaver--presentation-index owner)
                      :seed (etaf-screensaver--session-seed session)
                      :ticks (etaf-screensaver--session-ticks session)
                      :elapsed (etaf-screensaver--session-elapsed session)
                      :columns (etaf-screensaver--session-columns session)
                      :rows (etaf-screensaver--session-rows session)
                      :frame-rate (plist-get (etaf-screensaver--session-item session) :frame-rate)
                      :params (copy-tree (etaf-screensaver--session-params session))
                      :up-next (mapcar (lambda (item) (plist-get item :scene))
                                       (etaf-screensaver--presentation-queue owner))))))))

(define-minor-mode etaf-screensaver-mode
  "Toggle automatic, input-dismissed screensavers after Emacs is idle.
Disabling also dismisses an active presentation and releases the idle watcher.
Calling this repeatedly does not stack timers or hooks.  No external process
is started.  Configure the delay and playback program in Emacs Lisp."
  :global t :group 'etaf-screensaver
  (etaf-screensaver--cancel-idle)
  (remove-hook 'post-command-hook #'etaf-screensaver--arm-idle)
  (if (not etaf-screensaver-mode)
      (etaf-screensaver-stop)
    (unless (and (numberp etaf-screensaver-idle-delay) (> etaf-screensaver-idle-delay 0))
      (setq etaf-screensaver-mode nil)
      (etaf-screensaver--fail "Idle delay must be a positive number"))
    (add-hook 'post-command-hook #'etaf-screensaver--arm-idle)
    (etaf-screensaver--arm-idle)))

(etaf-screensaver-load-scenes)

(provide 'etaf-screensaver-app)
;;; etaf-screensaver-app.el ends here
