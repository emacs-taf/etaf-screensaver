;;; etaf-screensaver-app.el --- Buffer, commands and lifecycle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer owns the buffer, the keymap, the presentation mode
;; and the mount lifecycle.  Opening mounts a fresh session; closing unmounts
;; its Runtime and kills its buffer, so no timer survives.  Every command
;; resolves the buffer-local session, and the public controls drive the same
;; functions the keys do.
;;
;; Presentation saves the window configuration, hides the chrome and cycles
;; scenes; the first key afterwards restores the configuration and closes the
;; presentation buffer.  `etaf-screensaver-idle-mode' presents after the
;; configured idle delay, but only when no minibuffer is active.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-screensaver-theme)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-engine)
(require 'etaf-screensaver-dsl)
(require 'etaf-screensaver-layers)
(require 'etaf-screensaver-banner)
(require 'etaf-screensaver-loader)
(require 'etaf-screensaver-scene-donut)
(require 'etaf-screensaver-views)

(defcustom etaf-screensaver-buffer-name "*ETAF Screensaver*"
  "Default buffer name of a mounted screensaver."
  :type 'string
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-default-scene 'donut
  "Scene opened when no other one is requested."
  :type 'symbol
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-cycle-seconds 30
  "Seconds a scene stays before presentation switches to the next one."
  :type 'number
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-idle-delay 300
  "Seconds of idle time before `etaf-screensaver-idle-mode' presents."
  :type 'number
  :group 'etaf-screensaver)

(defvar etaf-screensaver--idle-timer nil
  "Timer of `etaf-screensaver-idle-mode', when enabled.")

(defvar etaf-screensaver--presenting nil
  "Non-nil while a presentation is mounted.")

(defvar-local etaf-screensaver--session nil
  "Screensaver session owned by the current buffer.")

(defvar-local etaf-screensaver--command-maps nil
  "Buffer-local session keymap entry for `emulation-mode-map-alists'.")

(defvar-local etaf-screensaver--present-maps nil
  "Buffer-local presentation keymap entry for `emulation-mode-map-alists'.")

(defvar-local etaf-screensaver--present-config nil
  "Window configuration saved by the current presentation.")

(defun etaf-screensaver--scene-options ()
  "Return the registered scenes as completion options."
  (mapcar (lambda (id)
            (cons (etaf-screensaver--scene-title (etaf-screensaver--scene id)) id))
          (etaf-screensaver-scenes)))

(defun etaf-screensaver--prompt-scene ()
  "Prompt for a registered scene and return its identifier."
  (cdr (assoc (completing-read "场景：" (etaf-screensaver--scene-options) nil t)
              (etaf-screensaver--scene-options))))

(defun etaf-screensaver--buffer-session (&optional buffer-name)
  "Return the mounted session in BUFFER-NAME or signal a user error."
  (let* ((name (or buffer-name etaf-screensaver-buffer-name))
         (buffer (get-buffer name))
         (session (and buffer (buffer-live-p buffer)
                       (buffer-local-value 'etaf-screensaver--session buffer))))
    (or session (user-error "没有已挂载的屏保：%s" name))))

(defun etaf-screensaver--default-dims ()
  "Return the initial (COLUMNS . ROWS) for a newly opened workspace."
  (if (window-live-p (selected-window))
      (cons (max 8 (window-body-width))
            (max 4 (- (window-body-height) 2)))
    (cons 80 22)))

;;; Commands owned by the mounted workspace.

(etaf-define-component etaf-screensaver--root (&key session)
  "Mount SESSION with its keymap and disposal hook, then draw the shell."
  :setup (etaf-screensaver--install session)
  :view (etaf-screensaver-shell :session session))

(defun etaf-screensaver--toggle-command ()
  "Toggle the current session between running and paused."
  (interactive)
  (let* ((session (etaf-screensaver--buffer-session))
         (status (etaf-screensaver--session-status session)))
    (if (eq status 'running)
        (etaf-screensaver--session-pause session)
      (etaf-screensaver--session-resume session))))

(defun etaf-screensaver--step-command ()
  "Pause the current session and advance exactly one frame."
  (interactive)
  (etaf-screensaver--session-step (etaf-screensaver--buffer-session)))

(defun etaf-screensaver--reset-command ()
  "Recreate the current scene at the same seed."
  (interactive)
  (etaf-screensaver--session-reset (etaf-screensaver--buffer-session)))

(defun etaf-screensaver--reseed-command ()
  "Give the current session a fresh random seed."
  (interactive)
  (etaf-screensaver--session-set-seed (etaf-screensaver--buffer-session)
                                      (random 1000000)))

(defun etaf-screensaver--select-relative (session delta)
  "Select the scene DELTA positions from SESSION's current one, wrapping."
  (let* ((ids (etaf-screensaver-scenes))
         (current (etaf-screensaver--scene-id
                   (etaf-screensaver--session-scene session)))
         (index (or (cl-position current ids) 0)))
    (etaf-screensaver--session-select-scene
     session (nth (% (+ index delta) (length ids)) ids))))

(defun etaf-screensaver--next-command ()
  "Switch to the next registered scene."
  (interactive)
  (etaf-screensaver--select-relative (etaf-screensaver--buffer-session) 1))

(defun etaf-screensaver--previous-command ()
  "Switch to the previous registered scene."
  (interactive)
  (etaf-screensaver--select-relative (etaf-screensaver--buffer-session) -1))

(defun etaf-screensaver--faster-command ()
  "Raise the current session's frame rate."
  (interactive)
  (let ((session (etaf-screensaver--buffer-session)))
    (etaf-screensaver--session-set-frame-rate
     session (min 60 (round (* 1.5 (etaf-screensaver--session-frame-rate session)))))))

(defun etaf-screensaver--slower-command ()
  "Lower the current session's frame rate."
  (interactive)
  (let ((session (etaf-screensaver--buffer-session)))
    (etaf-screensaver--session-set-frame-rate
     session (max 1 (round (/ (etaf-screensaver--session-frame-rate session) 1.5))))))

(defun etaf-screensaver--params-command ()
  "Toggle the current session's parameter panel."
  (interactive)
  (let* ((session (etaf-screensaver--buffer-session))
         (ref (etaf-screensaver--session-params-open session)))
    (setf (etaf-value ref) (not (etaf-value ref)))
    (etaf-screensaver--session-fit session)
    (etaf-screensaver--session-publish session)))

(defun etaf-screensaver--cinema-command ()
  "Toggle the current session's chrome-free cinema mode."
  (interactive)
  (let* ((session (etaf-screensaver--buffer-session))
         (ref (etaf-screensaver--session-cinema session)))
    (setf (etaf-value ref) (not (etaf-value ref)))
    (etaf-screensaver--session-fit session)
    (etaf-screensaver--session-publish session)))

(defun etaf-screensaver--close-command ()
  "Close the current buffer's screensaver."
  (interactive)
  (etaf-screensaver-close))

(defun etaf-screensaver--reload-command ()
  "Reload the scene spec files and refresh the current scene."
  (interactive)
  (etaf-screensaver-reload-scenes))

;;; Mount lifecycle.

(defun etaf-screensaver--install (session)
  "Attach SESSION to its Runtime, keymap and disposal hook."
  (let ((runtime (etaf-current-runtime)))
    (etaf-screensaver--session-attach session runtime)
    (with-current-buffer (etaf-runtime-buffer runtime)
      (setq-local etaf-screensaver--session session)
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "SPC") #'etaf-screensaver--toggle-command)
        (define-key map (kbd "n") #'etaf-screensaver--step-command)
        (define-key map (kbd "r") #'etaf-screensaver--reset-command)
        (define-key map (kbd "R") #'etaf-screensaver--reseed-command)
        (define-key map (kbd "s") #'etaf-screensaver--next-command)
        (define-key map (kbd "S") #'etaf-screensaver--previous-command)
        (define-key map (kbd "+") #'etaf-screensaver--faster-command)
        (define-key map (kbd "-") #'etaf-screensaver--slower-command)
        (define-key map (kbd "TAB") #'etaf-screensaver--params-command)
        (define-key map (kbd "c") #'etaf-screensaver--cinema-command)
        (define-key map (kbd "l") #'etaf-screensaver--reload-command)
        (define-key map (kbd "q") #'etaf-screensaver--close-command)
        (setq-local etaf-screensaver--command-maps
                    (list (cons 'etaf-screensaver--session map)))
        (setq-local emulation-mode-map-alists
                    (cons 'etaf-screensaver--command-maps
                          (remq 'etaf-screensaver--command-maps
                                emulation-mode-map-alists)))))
    (etaf-on-unmounted (lambda () (etaf-screensaver--dispose session)))
    (etaf-screensaver--session-resume session)))

(defun etaf-screensaver--dispose (session)
  "Release SESSION without touching another mounted workspace."
  (etaf-screensaver--session-dispose session)
  (let ((buffer (etaf-screensaver--session-buffer session)))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (eq etaf-screensaver--session session)
          (setq etaf-screensaver--session nil)
          (setq-local emulation-mode-map-alists
                      (remq 'etaf-screensaver--command-maps
                            emulation-mode-map-alists)))))))

;;; Public opening, closing and control.

;;;###autoload
(defun etaf-screensaver-open (&optional scene buffer-name)
  "Mount the screensaver workspace in BUFFER-NAME, selecting SCENE.

SCENE is a registered identifier, its symbol name or its displayed title;
without one `etaf-screensaver-default-scene' is opened.  An existing runtime
in that buffer is replaced.  Return the buffer."
  (interactive (list (when current-prefix-arg (etaf-screensaver--prompt-scene)) nil))
  (let* ((id (or (etaf-screensaver--resolve-scene scene)
                 etaf-screensaver-default-scene))
         (buffer (get-buffer-create (or buffer-name etaf-screensaver-buffer-name))))
    (etaf-screensaver--scene id)
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (with-current-buffer buffer (etaf-unmount runtime)))
    (with-current-buffer buffer
      (let* ((dims (etaf-screensaver--default-dims))
             (session (etaf-screensaver--session-create
                       id :columns (car dims) :rows (cdr dims) :buffer buffer)))
        (setq-local etaf-screensaver--session session)
        (etaf-mount buffer (etaf-view (etaf-screensaver--root :session session)))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-screensaver-close (&optional buffer-name)
  "Unmount the screensaver workspace in BUFFER-NAME and kill its buffer.
Return nil so the command leaves no buffer behind."
  (interactive)
  (let ((buffer (get-buffer (or buffer-name etaf-screensaver-buffer-name))))
    (when buffer
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (with-current-buffer buffer (etaf-unmount runtime)))
      (when (buffer-live-p buffer) (kill-buffer buffer))))
  nil)

;;;###autoload
(defun etaf-screensaver-present (&optional scene)
  "Present SCENE as a full-window screensaver.

The current window configuration is saved, the chrome and mode line are
hidden and the scene cycle is enabled.  The first key afterwards restores the
configuration and closes the presentation buffer; a nil SCENE uses
`etaf-screensaver-default-scene'."
  (interactive (list (when current-prefix-arg (etaf-screensaver--prompt-scene))))
  (let* ((config (current-window-configuration))
         (buffer (etaf-screensaver-open scene))
         (session (buffer-local-value 'etaf-screensaver--session buffer)))
    (with-current-buffer buffer
      (setq-local etaf-screensaver--present-config config
                  etaf-screensaver--presenting t
                  cursor-type nil
                  mode-line-format nil)
      (let ((wake (make-sparse-keymap)))
        (define-key wake [t] #'etaf-screensaver--wake-command)
        (setq-local etaf-screensaver--present-maps
                    (list (cons 'etaf-screensaver--presenting wake)))
        (setq-local emulation-mode-map-alists
                    (cons 'etaf-screensaver--present-maps
                          (remq 'etaf-screensaver--present-maps
                                emulation-mode-map-alists))))
      (setf (etaf-value (etaf-screensaver--session-cinema session)) t
            (etaf-screensaver--session-cycle-p session) t
            (etaf-screensaver--session-cycle-seconds session)
            etaf-screensaver-cycle-seconds
            (etaf-screensaver--session-on-cycle session)
            (lambda (current) (etaf-screensaver--select-relative current 1)))
      (etaf-screensaver--session-fit session)
      (etaf-screensaver--session-publish session))
    (pop-to-buffer buffer)
    (delete-other-windows)
    buffer))

(defun etaf-screensaver--wake-command ()
  "Leave presentation, restore the window configuration and close its buffer."
  (interactive)
  (let ((buffer (current-buffer))
        (config etaf-screensaver--present-config))
    (setq etaf-screensaver--presenting nil)
    (when (window-configuration-p config)
      (set-window-configuration config))
    (when (buffer-live-p buffer)
      (etaf-screensaver-close (buffer-name buffer)))))

;;;###autoload
(define-minor-mode etaf-screensaver-idle-mode
  "Present a screensaver after `etaf-screensaver-idle-delay' seconds idle."
  :global t
  :group 'etaf-screensaver
  (if etaf-screensaver-idle-mode
      (setq etaf-screensaver--idle-timer
            (run-with-idle-timer etaf-screensaver-idle-delay t
                                 #'etaf-screensaver--idle-fire))
    (when (timerp etaf-screensaver--idle-timer)
      (cancel-timer etaf-screensaver--idle-timer))
    (setq etaf-screensaver--idle-timer nil)))

(defun etaf-screensaver--idle-fire ()
  "Present the screensaver when the idle delay expires."
  (unless (or etaf-screensaver--presenting (active-minibuffer-window))
    (etaf-screensaver-present)))

;;; Public controls.

(defun etaf-screensaver-pause (&optional buffer-name)
  "Pause the screensaver mounted in BUFFER-NAME."
  (interactive)
  (etaf-screensaver--session-pause (etaf-screensaver--buffer-session buffer-name)))

(defun etaf-screensaver-resume (&optional buffer-name)
  "Resume the screensaver mounted in BUFFER-NAME."
  (interactive)
  (etaf-screensaver--session-resume (etaf-screensaver--buffer-session buffer-name)))

(defun etaf-screensaver-step (&optional buffer-name)
  "Pause the screensaver in BUFFER-NAME and advance exactly one frame."
  (interactive)
  (etaf-screensaver--session-step (etaf-screensaver--buffer-session buffer-name)))

(defun etaf-screensaver-reset (&optional buffer-name)
  "Recreate the screensaver scene in BUFFER-NAME at the same seed."
  (interactive)
  (etaf-screensaver--session-reset (etaf-screensaver--buffer-session buffer-name)))

(defun etaf-screensaver-select-scene (scene &optional buffer-name)
  "Switch the screensaver in BUFFER-NAME to SCENE.
SCENE is an identifier, its symbol name or its displayed title."
  (interactive (list (etaf-screensaver--prompt-scene) nil))
  (etaf-screensaver--session-select-scene
   (etaf-screensaver--buffer-session buffer-name) scene))

(defun etaf-screensaver-reload-scenes ()
  "Reload the scene spec files and refresh a mounted scene in place.
Reloading re-reads `etaf-screensaver-scene-directories', so an edited or
newly dropped .esc file appears immediately; when the mounted scene still
exists its spec is rebuilt without switching away.  Return how many files
loaded."
  (interactive)
  (let ((count (etaf-screensaver-load-scenes))
        (buffer (get-buffer etaf-screensaver-buffer-name)))
    (when (and buffer (buffer-live-p buffer))
      (let ((session (buffer-local-value 'etaf-screensaver--session buffer)))
        (when session
          (let ((id (etaf-screensaver--scene-id
                     (etaf-screensaver--session-scene session))))
            (when (memq id (etaf-screensaver-scenes))
              (etaf-screensaver--session-select-scene session id t))))))
    count))

(defun etaf-screensaver-set-param (key value &optional buffer-name)
  "Set scene parameter KEY to VALUE in BUFFER-NAME and repaint its frame."
  (interactive (list (intern (read-string "参数：")) (read-string "值：") nil))
  (etaf-screensaver--session-set-param
   (etaf-screensaver--buffer-session buffer-name) key value))

(defun etaf-screensaver-set-frame-rate (frame-rate &optional buffer-name)
  "Set the screensaver in BUFFER-NAME to FRAME-RATE frames per second."
  (interactive "n每秒帧数：")
  (etaf-screensaver--session-set-frame-rate
   (etaf-screensaver--buffer-session buffer-name) frame-rate))

(defun etaf-screensaver-set-seed (seed &optional buffer-name)
  "Set the screensaver in BUFFER-NAME to SEED and reset its scene."
  (interactive "n随机种子：")
  (etaf-screensaver--session-set-seed
   (etaf-screensaver--buffer-session buffer-name) seed))

(defun etaf-screensaver-status (&optional buffer-name)
  "Return the screensaver in BUFFER-NAME as a status plist.
The plist holds :scene, :title, :status, :frame-rate, :seed, :ticks,
:elapsed, :columns, :rows and :notice."
  (etaf-screensaver--session-status-plist
   (etaf-screensaver--buffer-session buffer-name)))

;; Bundled scene specs load with the package.  A byte-compilation pass does
;; not read them, and `etaf-screensaver-reload-scenes' re-reads the
;; configured directories at any time.
(unless (bound-and-true-p byte-compile-current-file)
  (etaf-screensaver-load-scenes))

(provide 'etaf-screensaver-app)
;;; etaf-screensaver-app.el ends here
