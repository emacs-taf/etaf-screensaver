;;; etaf-screensaver-engine.el --- Session clock and frame publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One session drives one scene inside one mounted Runtime.  The session owns
;; the single frame timer, the random state, the parameter refs, the current
;; frame and its publication: a frame is written through
;; `etaf-runtime-update-host-contents' into two fixed Hosts (the canvas and
;; the HUD line), so a running scene never re-renders the application.
;;
;; Scene callbacks stay pure: the engine builds the context, calls STEP and
;; RENDER, pads or truncates every row to the canvas width and publishes only
;; frames that changed.  A hidden buffer stops advancing but keeps the timer
;; awake with a cheap visibility probe, so showing the buffer again resumes
;; without a key press; disposal cancels the timer.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-screensaver-model)

(cl-defstruct (etaf-screensaver--session (:constructor etaf-screensaver--session-make))
  "Live state of one mounted scene.
The scene owns its own STATE; FRAME holds the rendered canvas text and
PUBLISHED-FRAME the last one written into the Runtime.  PARAMS is an alist of
parameter keys to refs.  SIZE is a (COLUMNS . ROWS) ref the view follows,
REVISION a ref bumped when the scene or its parameters change shape, and
CINEMA and PARAMS-OPEN refs the view reads for its chrome."
  scene state status frame-rate columns rows size seed params frame
  published-frame published-hud
  canvas-ref canvas-id hud-ref hud-id
  runtime buffer timer ticks elapsed dt random-state
  disposed notice revision cinema params-open pointer
  cycle-p cycle-seconds scene-elapsed on-cycle hidden)

(defvar etaf-screensaver--canvas-counter 0
  "Number of allocated canvas Host ids, used to make each one unique.")

(defvar etaf-screensaver--hud-counter 0
  "Number of allocated HUD Host ids, used to make each one unique.")

(defun etaf-screensaver--next-canvas-id ()
  "Return a canvas Host id that is unique within this Emacs session."
  (format "etaf-screensaver-canvas-%d" (cl-incf etaf-screensaver--canvas-counter)))

(defun etaf-screensaver--next-hud-id ()
  "Return a HUD Host id that is unique within this Emacs session."
  (format "etaf-screensaver-hud-%d" (cl-incf etaf-screensaver--hud-counter)))

(defun etaf-screensaver--blank-frame (columns rows)
  "Return a blank canvas frame of COLUMNS by ROWS."
  (mapconcat #'identity
             (make-list rows (make-string columns ?\s))
             "\n"))

(defun etaf-screensaver--session-param-refs (scene)
  "Return fresh parameter refs for SCENE as (KEY . REF) pairs."
  (mapcar (lambda (param)
            (cons (plist-get param :key)
                  (etaf-ref (plist-get param :default)
                            :name (intern (format "etaf-screensaver-param-%s"
                                                  (plist-get param :key))))))
          (etaf-screensaver--scene-params scene)))

(cl-defun etaf-screensaver--session-create (scene &key columns rows seed buffer)
  "Create a paused session for SCENE sized to COLUMNS by ROWS.
SEED fixes the scene's random state; a nil SEED draws one now.  BUFFER is the
mount target the session later attaches to; without one the session is
headless and can still be stepped.  Return the session."
  (let* ((scene (etaf-screensaver--scene (etaf-screensaver--resolve-scene scene)))
         (columns (or columns 80))
         (rows (or rows 22))
         (seed (or seed (random 1000000))))
    (let ((session (etaf-screensaver--session-make
                    :scene scene
                    :status 'paused
                    :frame-rate (etaf-screensaver--scene-frame-rate scene)
                    :columns columns :rows rows
                    :size (etaf-ref (cons columns rows) :name 'etaf-screensaver-size)
                    :seed seed
                    :params (etaf-screensaver--session-param-refs scene)
                    :frame (etaf-screensaver--blank-frame columns rows)
                    :canvas-ref (make-symbol "etaf-screensaver-canvas")
                    :canvas-id (etaf-screensaver--next-canvas-id)
                    :hud-ref (make-symbol "etaf-screensaver-hud")
                    :hud-id (etaf-screensaver--next-hud-id)
                    :random-state (cl-make-random-state seed)
                    :revision (etaf-ref 0 :name 'etaf-screensaver-revision)
                    :cinema (etaf-ref nil :name 'etaf-screensaver-cinema)
                    :params-open (etaf-ref nil :name 'etaf-screensaver-params-open)
                    :pointer (etaf-ref (etaf-screensaver--scene-pointer scene)
                                       :name 'etaf-screensaver-pointer)
                    :buffer buffer
                    :ticks 0 :elapsed 0.0 :dt 0.0)))
      (etaf-screensaver--session-recreate session)
      session)))

(defun etaf-screensaver--session-context (session)
  "Return the callback context plist of SESSION."
  (let ((random-state (etaf-screensaver--session-random-state session)))
    (list :columns (etaf-screensaver--session-columns session)
          :rows (etaf-screensaver--session-rows session)
          :seed (etaf-screensaver--session-seed session)
          :tick (etaf-screensaver--session-ticks session)
          :elapsed (etaf-screensaver--session-elapsed session)
          :dt (etaf-screensaver--session-dt session)
          :params (mapcar #'car (etaf-screensaver--session-params session))
          :param (lambda (key) (etaf-screensaver--session-param session key))
          ;; RANDOM mirrors the spec language's `rnd': no argument returns a
          ;; float in [0, 1), a positive LIMIT an integer below it.
          :random (lambda (&optional limit)
                    (if limit
                        (cl-random limit random-state)
                      (/ (float (cl-random 1000000 random-state)) 1000000.0))))))

(defun etaf-screensaver--param-key (key)
  "Return KEY as the plain symbol a parameter descriptor uses.
Callers may address a parameter by its symbol or by the keyword with the
same name, so `:speed' and `speed' reach the same ref."
  (if (keywordp key)
      (intern (substring (symbol-name key) 1))
    key))

(defun etaf-screensaver--session-param-ref (session key)
  "Return SESSION's ref holding parameter KEY's value."
  (let ((key (etaf-screensaver--param-key key)))
    (or (cdr (assq key (etaf-screensaver--session-params session)))
        (etaf-screensaver--fail "Scene %s has no parameter %s"
                                (etaf-screensaver--scene-id
                                 (etaf-screensaver--session-scene session))
                                key))))

(defun etaf-screensaver--session-param (session key)
  "Return SESSION's current value for scene parameter KEY."
  (etaf-value (etaf-screensaver--session-param-ref session key)))

(defun etaf-screensaver--session-set-param (session key value)
  "Set SESSION's parameter KEY to VALUE and repaint the current frame."
  (let ((ref (etaf-screensaver--session-param-ref session key)))
    (setf (etaf-value ref) value)
    (etaf-screensaver--session-render session)
    (etaf-screensaver--session-publish session)))

(defun etaf-screensaver--session-normalize-row (row columns)
  "Return ROW as a string of exactly COLUMNS display columns.
A short row is padded with spaces, a long row is truncated, and characters
that cannot live in a canvas row are dropped."
  (let* ((line (cond ((stringp row) row)
                     ((null row) "")
                     (t (format "%s" row))))
         (line (if (string-match-p "[\r\t]" line)
                   (string-replace "\r" "" (string-replace "\t" " " line))
                 line))
         (fitted (truncate-string-to-width line columns nil ?\s)))
    (if (stringp fitted) fitted (make-string columns ?\s))))

(defun etaf-screensaver--session-normalize-frame (session frame)
  "Return FRAME as SESSION's canvas text of ROWS lines by COLUMNS columns.
FRAME is a string of newline-separated rows or a list of row strings; missing
rows and short rows are padded and extra rows are dropped."
  (let* ((columns (etaf-screensaver--session-columns session))
         (rows (etaf-screensaver--session-rows session))
         (lines (cond ((stringp frame) (split-string frame "\n"))
                      ((proper-list-p frame) frame)
                      (t (etaf-screensaver--fail
                          "Scene %s :render must return a string or a list of rows"
                          (etaf-screensaver--scene-id
                           (etaf-screensaver--session-scene session)))))))
    (mapconcat (lambda (index)
                 (etaf-screensaver--session-normalize-row (nth index lines) columns))
               (number-sequence 0 (1- rows)) "\n")))

(defun etaf-screensaver--session-render (session)
  "Render SESSION's current scene state and store the canvas frame."
  (let* ((scene (etaf-screensaver--session-scene session))
         (frame (funcall (etaf-screensaver--scene-render scene)
                         (etaf-screensaver--session-state session)
                         (etaf-screensaver--session-context session))))
    (setf (etaf-screensaver--session-frame session)
          (etaf-screensaver--session-normalize-frame session frame))))

(defun etaf-screensaver--session-hud-text (session)
  "Return SESSION's one-line HUD text."
  (let* ((scene (etaf-screensaver--session-scene session))
         (elapsed (max 0 (floor (etaf-screensaver--session-elapsed session))))
         (status (pcase (etaf-screensaver--session-status session)
                   ('running "运行中") ('paused "已暂停") (_ "准备就绪")))
         (notice (etaf-screensaver--session-notice session)))
    (format "%s · %s · %s fps · seed %d · %d:%02d%s"
            (etaf-screensaver--scene-title scene)
            status
            (etaf-screensaver--session-frame-rate session)
            (etaf-screensaver--session-seed session)
            (/ elapsed 60) (% elapsed 60)
            (if notice (format " · %s" notice) ""))))

(defun etaf-screensaver--session-publish (session)
  "Publish SESSION's changed canvas and HUD content to its Runtime.
A host that is not committed yet (the first publication can land during the
mount transaction) is skipped without marking its content published, so the
next frame retries it."
  (let ((runtime (etaf-screensaver--session-runtime session)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (let ((updates nil)
            (hud (etaf-screensaver--session-hud-text session))
            (canvas-ref (etaf-screensaver--session-canvas-ref session))
            (hud-ref (etaf-screensaver--session-hud-ref session)))
        (when (and (etaf-host-ref-bounds runtime canvas-ref)
                   (not (equal (etaf-screensaver--session-frame session)
                               (etaf-screensaver--session-published-frame session))))
          (push (cons canvas-ref (etaf-screensaver--session-frame session)) updates))
        (when (and (etaf-host-ref-bounds runtime hud-ref)
                   (not (equal hud (etaf-screensaver--session-published-hud session))))
          (push (cons hud-ref hud) updates))
        (when updates
          (condition-case problem
              (progn
                (etaf-runtime-update-host-contents runtime (nreverse updates))
                (setf (etaf-screensaver--session-published-frame session)
                      (etaf-screensaver--session-frame session)
                      (etaf-screensaver--session-published-hud session) hud))
            (etaf-runtime-error
             (setf (etaf-screensaver--session-notice session)
                   (format "画面发布失败：%s" (error-message-string problem)))
             (etaf-screensaver--session-pause session))))))))

(defun etaf-screensaver--session-recreate (session)
  "Recreate SESSION's scene state and render the first frame."
  (setf (etaf-screensaver--session-state session)
        (funcall (etaf-screensaver--scene-create (etaf-screensaver--session-scene session))
                 (etaf-screensaver--session-context session))
        (etaf-screensaver--session-ticks session) 0
        (etaf-screensaver--session-elapsed session) 0.0
        (etaf-screensaver--session-dt session) 0.0
        (etaf-screensaver--session-scene-elapsed session) 0.0
        (etaf-screensaver--session-published-frame session) nil)
  (etaf-screensaver--session-render session))

(defun etaf-screensaver--session-advance (session &optional dt)
  "Advance SESSION one scene step, render it and publish the frame.
DT is the seconds elapsed since the previous step, zero for a single step."
  (unless (etaf-screensaver--session-disposed session)
    (setf (etaf-screensaver--session-dt session) (or dt 0.0))
    (funcall (etaf-screensaver--scene-step (etaf-screensaver--session-scene session))
             (etaf-screensaver--session-state session)
             (etaf-screensaver--session-context session))
    (cl-incf (etaf-screensaver--session-ticks session))
    (cl-incf (etaf-screensaver--session-elapsed session) (or dt 0.0))
    (etaf-screensaver--session-render session)
    (etaf-screensaver--session-publish session)))

(defun etaf-screensaver--session-cancel-timer (session)
  "Cancel SESSION's pending frame timer, when any."
  (when (timerp (etaf-screensaver--session-timer session))
    (cancel-timer (etaf-screensaver--session-timer session)))
  (setf (etaf-screensaver--session-timer session) nil))

(defun etaf-screensaver--session-arm (session)
  "Schedule SESSION's next frame, replacing any pending one."
  (etaf-screensaver--session-cancel-timer session)
  (unless (or (etaf-screensaver--session-disposed session)
              (not (eq (etaf-screensaver--session-status session) 'running)))
    (setf (etaf-screensaver--session-timer session)
          (run-at-time (/ 1.0 (etaf-screensaver--session-frame-rate session))
                       nil #'etaf-screensaver--session-tick session))))

(defun etaf-screensaver--session-pause (session)
  "Pause SESSION and stop its frame timer."
  (unless (eq (etaf-screensaver--session-status session) 'paused)
    (setf (etaf-screensaver--session-status session) 'paused)
    (etaf-screensaver--session-cancel-timer session)
    (etaf-screensaver--session-publish session)))

(defun etaf-screensaver--session-resume (session)
  "Resume SESSION and arm its frame timer."
  (unless (etaf-screensaver--session-disposed session)
    (setf (etaf-screensaver--session-status session) 'running
          (etaf-screensaver--session-hidden session) nil)
    (etaf-screensaver--session-publish session)
    (etaf-screensaver--session-arm session)))

(defun etaf-screensaver--session-step (session)
  "Pause SESSION and advance exactly one frame."
  (etaf-screensaver--session-pause session)
  (etaf-screensaver--session-advance session 0.0))

(defun etaf-screensaver--session-reset (session)
  "Recreate SESSION's scene state at the same seed and repaint."
  (etaf-screensaver--session-recreate session)
  (etaf-screensaver--session-publish session))

(defun etaf-screensaver--session-set-seed (session seed)
  "Set SESSION's seed to SEED, restart its random state and reset."
  (setf (etaf-screensaver--session-seed session) seed
        (etaf-screensaver--session-random-state session) (cl-make-random-state seed))
  (etaf-screensaver--session-reset session))

(defun etaf-screensaver--session-set-frame-rate (session frame-rate)
  "Set SESSION's frames per second to FRAME-RATE and re-arm its timer."
  (setf (etaf-screensaver--session-frame-rate session) frame-rate)
  (etaf-screensaver--session-publish session)
  (etaf-screensaver--session-arm session))

(defun etaf-screensaver--session-select-scene (session scene &optional force)
  "Switch SESSION to SCENE, keeping its seed and refreshing its parameters.
FORCE re-registers a scene that is already selected, so a reloaded spec takes
effect without switching away and back."
  (let* ((scene (etaf-screensaver--scene (etaf-screensaver--resolve-scene scene)))
         (current (etaf-screensaver--session-scene session)))
    (when (or force
              (not (eq (etaf-screensaver--scene-id scene)
                       (etaf-screensaver--scene-id current))))
      (setf (etaf-screensaver--session-scene session) scene
            (etaf-screensaver--session-frame-rate session)
            (etaf-screensaver--scene-frame-rate scene)
            (etaf-screensaver--session-params session)
            (etaf-screensaver--session-param-refs scene)
            (etaf-value (etaf-screensaver--session-pointer session))
            (etaf-screensaver--scene-pointer scene))
      (etaf-screensaver--session-recreate session)
      (cl-incf (etaf-value (etaf-screensaver--session-revision session)))
      (etaf-screensaver--session-publish session)
      (etaf-screensaver--session-arm session))))

(defun etaf-screensaver--session-chrome-rows (session)
  "Return the body rows SESSION's interactive chrome needs.
Cinema mode has no chrome; otherwise the HUD and footer take two rows and an
open parameter panel takes one row per parameter."
  (if (etaf-value (etaf-screensaver--session-cinema session))
      0
    (+ 2 (if (etaf-value (etaf-screensaver--session-params-open session))
             (length (etaf-screensaver--scene-params
                      (etaf-screensaver--session-scene session)))
           0))))

(defun etaf-screensaver--session-resize (session columns rows)
  "Resize SESSION's canvas to COLUMNS by ROWS and repaint it."
  (let ((size (etaf-value (etaf-screensaver--session-size session))))
    (unless (and (= columns (car size)) (= rows (cdr size)))
      (setf (etaf-screensaver--session-columns session) columns
            (etaf-screensaver--session-rows session) rows)
      (setf (etaf-value (etaf-screensaver--session-size session)) (cons columns rows))
      (let ((resize (etaf-screensaver--scene-resize (etaf-screensaver--session-scene session))))
        (if (functionp resize)
            (let ((next (funcall resize (etaf-screensaver--session-state session)
                                 (etaf-screensaver--session-context session))))
              (when next (setf (etaf-screensaver--session-state session) next))
              (etaf-screensaver--session-render session))
          (etaf-screensaver--session-recreate session)))
      (setf (etaf-screensaver--session-published-frame session) nil)
      (etaf-screensaver--session-publish session))))

(defun etaf-screensaver--session-fit (session)
  "Resize SESSION to its buffer's visible window, when it has one."
  (when-let* ((buffer (etaf-screensaver--session-buffer session))
              (window (get-buffer-window buffer t)))
    (let ((columns (max 8 (window-body-width window)))
          (rows (max 4 (- (window-body-height window)
                          (etaf-screensaver--session-chrome-rows session)))))
      (etaf-screensaver--session-resize session columns rows))))

(defun etaf-screensaver--session-cycle (session dt)
  "Count one scene interval for SESSION and cycle when its budget is spent."
  (when (and (etaf-screensaver--session-cycle-p session)
             (functionp (etaf-screensaver--session-on-cycle session)))
    (cl-incf (etaf-screensaver--session-scene-elapsed session) dt)
    (when (>= (etaf-screensaver--session-scene-elapsed session)
              (etaf-screensaver--session-cycle-seconds session))
      (setf (etaf-screensaver--session-scene-elapsed session) 0.0)
      (funcall (etaf-screensaver--session-on-cycle session) session))))

(defun etaf-screensaver--session-set-notice (session notice)
  "Set SESSION's notice to NOTICE and publish the HUD line."
  (setf (etaf-screensaver--session-notice session) notice)
  (etaf-screensaver--session-publish session))

(defun etaf-screensaver--session-tick (session)
  "Advance a live, visible SESSION once and schedule its next frame.
A hidden buffer stops advancing but keeps a cheap visibility probe alive, so
showing it again resumes the scene without a key press."
  (setf (etaf-screensaver--session-timer session) nil)
  (let* ((runtime (etaf-screensaver--session-runtime session))
         (buffer (and runtime (etaf-runtime-buffer runtime))))
    (when (and (not (etaf-screensaver--session-disposed session))
               (buffer-live-p buffer)
               (eq runtime (etaf-runtime-for-buffer buffer))
               (eq (etaf-screensaver--session-status session) 'running))
      (cond
       ((not (get-buffer-window buffer t))
        (unless (etaf-screensaver--session-hidden session)
          (setf (etaf-screensaver--session-hidden session) t)
          (etaf-screensaver--session-set-notice session "窗口不可见，画面已暂停。"))
        (etaf-screensaver--session-arm session))
       (t
        (when (etaf-screensaver--session-hidden session)
          (setf (etaf-screensaver--session-hidden session) nil)
          (etaf-screensaver--session-set-notice session nil))
        (etaf-screensaver--session-fit session)
        (let ((dt (/ 1.0 (etaf-screensaver--session-frame-rate session))))
          (etaf-screensaver--session-advance session dt)
          (etaf-screensaver--session-cycle session dt))
        (etaf-screensaver--session-arm session))))))

(defun etaf-screensaver--session-attach (session runtime)
  "Attach SESSION to mounted RUNTIME and fit it to the visible window."
  (setf (etaf-screensaver--session-runtime session) runtime
        (etaf-screensaver--session-buffer session) (etaf-runtime-buffer runtime))
  (etaf-screensaver--session-fit session))

(defun etaf-screensaver--session-dispose (session)
  "Release SESSION: cancel its timer and drop its Runtime reference."
  (setf (etaf-screensaver--session-disposed session) t)
  (etaf-screensaver--session-cancel-timer session)
  (setf (etaf-screensaver--session-runtime session) nil))

(defun etaf-screensaver--session-pointer-event (session gesture)
  "Forward one pointer GESTURE on SESSION's canvas to its scene.
The gesture's buffer position is projected onto the canvas grid; a position
outside the canvas is ignored.  The scene's :pointer callback receives a
plist with :phase, :row, :column and :event."
  (let ((pointer (etaf-screensaver--scene-pointer
                  (etaf-screensaver--session-scene session)))
        (runtime (etaf-screensaver--session-runtime session)))
    (when (and (functionp pointer)
               runtime (etaf-runtime-mounted-p runtime))
      (when-let* ((bounds (etaf-host-ref-bounds
                           runtime (etaf-screensaver--session-canvas-ref session)))
                  (event (plist-get gesture :event))
                  (point (and (consp event) (posn-point (event-start event))))
                  (start (car bounds))
                  (columns (etaf-screensaver--session-columns session)))
        (when (and (integerp point) (>= point start))
          (let* ((delta (- point start))
                 (row (/ delta (1+ columns)))
                 (column (% delta (1+ columns))))
            (when (and (>= row 0) (< row (etaf-screensaver--session-rows session))
                       (>= column 0) (< column columns))
              ;; A non-nil result asks for an immediate repaint, so painting
              ;; while paused shows up without waiting for the next step.
              (when (funcall pointer
                             (etaf-screensaver--session-state session)
                             (etaf-screensaver--session-context session)
                             (list :phase (plist-get gesture :phase)
                                   :row row :column column
                                   :event event))
                (etaf-screensaver--session-render session)
                (etaf-screensaver--session-publish session)))))))))

(defun etaf-screensaver--session-status-plist (session)
  "Return SESSION's observable status as a plist."
  (list :scene (etaf-screensaver--scene-id (etaf-screensaver--session-scene session))
        :title (etaf-screensaver--scene-title (etaf-screensaver--session-scene session))
        :status (etaf-screensaver--session-status session)
        :frame-rate (etaf-screensaver--session-frame-rate session)
        :seed (etaf-screensaver--session-seed session)
        :ticks (etaf-screensaver--session-ticks session)
        :elapsed (etaf-screensaver--session-elapsed session)
        :columns (etaf-screensaver--session-columns session)
        :rows (etaf-screensaver--session-rows session)
        :notice (etaf-screensaver--session-notice session)))

(provide 'etaf-screensaver-engine)
;;; etaf-screensaver-engine.el ends here
