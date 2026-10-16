;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-engine.el --- Scene frames and retained publication

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One owner supplies time and viewport changes.  Mosaic children have their
;; own scene states and random streams, but no Runtime, timer or input owner.
;; Only the composed parent frame crosses ETAF's retained Host boundary.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-playlist)
(require 'etaf-screensaver-presentation)
(declare-function image-flush "image.c" (image &optional frame))

(declare-function image-flush "image.c" (image &optional frame))

(cl-defstruct (etaf-screensaver--session (:constructor etaf-screensaver--session-new))
  scene state item seed random-state columns rows window-columns window-rows
  size revision params ticks elapsed dt frame published-frame images canvas-ref runtime buffer
  children layout metrics composition-context template previous-rows transition-duration)

(defun etaf-screensaver--frame-display (frame)
  "Project FRAME's image footprints and blank runs as replacing display units.
Composition and clipping still use complete character-cell footprints.  At
publication, an image slice needs only one glyph.  Adjacent ordinary spaces
with identical properties share one fixed-width space glyph, preserving
face metrics without allocating a renderer unit per empty cell.
Neither projection mutates the logical frame or its scene's source strings."
  (save-match-data
    (let ((position 0) (start 0) (length (length frame)) pieces)
      (while (< position length)
        (let* ((display (get-text-property position 'display frame))
               (end (if display
                        (next-single-property-change position 'display frame length)
                      (next-property-change position frame length))))
          (when (> (- end position) 1)
            (cond
             ((and (eq (car-safe (car-safe display)) 'slice)
                   (eq (car-safe (cadr display)) 'image))
              (push (substring frame start position) pieces)
              (push (substring frame position (1+ position)) pieces)
              (setq start end))
             ((not (or display
                       (get-text-property position 'composition frame)
                       (get-text-property position 'invisible frame)))
              (let ((part (substring frame position end)) (offset 0) space-width)
                (while (string-match "  +" part offset)
                  (let* ((from (match-beginning 0))
                         (to (match-end 0))
                         (blank (substring part from (1+ from))))
                    ;; Identically styled spaces have additive widths.  Measure
                    ;; one with its own face, not the default character width.
                    (unless space-width
                      (setq space-width (etaf-string-pixel-width
                                         blank)))
                    (put-text-property
                     0 (length blank) 'display
                     (list 'space :width (list (* (- to from) space-width))) blank)
                    (push (substring frame start (+ position from)) pieces)
                    (push blank pieces)
                    (setq start (+ position to) offset to)))))))
          (setq position end)))
      (if pieces
          (apply #'concat (nreverse (cons (substring frame start) pieces)))
        frame))))

(defun etaf-screensaver--frame-images (frame)
  "Return the distinct image objects FRAME displays."
  (let ((position 0) (length (length frame)) images)
    (while (< position length)
      (let ((display (get-text-property position 'display frame)))
        (when (eq (car-safe (car-safe (cdr-safe display))) 'image)
          (cl-pushnew (cadr display) images :test #'equal)))
      (setq position (next-single-property-change position 'display frame length)))
    images))

(defun etaf-screensaver--session-flush-images (session keep)
  "Flush SESSION's previously published images absent from KEEP."
  ;; A terminal frame has no decoded-image cache.  The public image-flush
  ;; operation requires a graphical frame rather than being a no-op there.
  (when (display-graphic-p)
    (dolist (image (etaf-screensaver--session-images session))
      (unless (member image keep) (image-flush image))))
  (setf (etaf-screensaver--session-images session) keep))

(defun etaf-screensaver--session-context (session)
  "Return SESSION's pure callback context, including inherited display metrics."
  (let ((random-state (etaf-screensaver--session-random-state session)))
    (list :columns (etaf-screensaver--session-columns session)
          :rows (etaf-screensaver--session-rows session)
          :seed (etaf-screensaver--session-seed session)
          :tick (etaf-screensaver--session-ticks session)
          :elapsed (etaf-screensaver--session-elapsed session)
          :dt (etaf-screensaver--session-dt session)
          :metrics (etaf-screensaver--session-metrics session)
          :params (mapcar #'car (etaf-screensaver--session-params session))
          :param (lambda (key)
                   (let ((entry (assq (etaf-screensaver--parameter-key key)
                                      (etaf-screensaver--session-params session))))
                     (unless entry (etaf-screensaver--fail "Unknown parameter: %s" key))
                     (cdr entry)))
          :random (lambda (&optional limit)
                    (if limit (cl-random limit random-state)
                      (/ (float (cl-random 1000000 random-state)) 1000000.0))))))

(defun etaf-screensaver--session-scene-rows (session &optional paint-background)
  "Render SESSION's rectangular rows, optionally adding PAINT-BACKGROUND.
A full-canvas work already inherits its background from the retained Host;
only framed works need an explicit background on each row."
  (let* ((frame (funcall (etaf-screensaver--scene-render (etaf-screensaver--session-scene session))
                         (etaf-screensaver--session-state session)
                         (etaf-screensaver--session-context session)))
         (lines (cond ((stringp frame) (split-string frame "\n"))
                      ((proper-list-p frame) frame)
                      (t (etaf-screensaver--fail "Scene must render a string or row list"))))
         (columns (etaf-screensaver--session-columns session))
         (background (plist-get (etaf-screensaver--session-item session) :background)))
    (cl-loop repeat (etaf-screensaver--session-rows session)
             for line = (or (pop lines) "")
             collect
             (progn
               (unless (stringp line) (etaf-screensaver--fail "Scene rows must be strings"))
               (let ((row (etaf-screensaver--presentation-crop
                           (string-replace "\r" "" (string-replace "\t" " " line)) columns)))
                 (when paint-background
                   ;; An exact-width crop may return the recording's cached row.
                   ;; Do not add page-specific faces to that shared source.
                   (setq row (copy-sequence row))
                   (add-face-text-property 0 (length row) (list :background background) t row))
                 row)))))

(defun etaf-screensaver--session-render (session)
  "Project SESSION's independent works into its window rectangle."
  (let* ((runtime (etaf-screensaver--session-runtime session))
         (children (etaf-screensaver--session-children session))
         (works (or children (list session)))
         (item (etaf-screensaver--session-item session))
         (style (plist-get item :presentation)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (setf (etaf-screensaver--session-metrics session) (etaf-display-metrics runtime)))
    (dolist (child children)
      (setf (etaf-screensaver--session-metrics child) (etaf-screensaver--session-metrics session)))
    (setf (etaf-screensaver--session-frame session)
          (mapconcat
           #'identity
           (if (eq style 'full)
               (etaf-screensaver--session-scene-rows session)
             (let* ((context (or (etaf-screensaver--session-composition-context session)
                                 (setf (etaf-screensaver--session-composition-context session)
                                       (list :layout (etaf-screensaver--session-layout session)
                                             :columns (etaf-screensaver--session-window-columns session)
                                             :rows (etaf-screensaver--session-window-rows session)
                                             :backgrounds (mapcar (lambda (work) (plist-get (etaf-screensaver--session-item work) :background)) works)
                                             :titles (mapcar (lambda (work) (etaf-screensaver--scene-title (etaf-screensaver--session-scene work))) works)
                                             :pack-title (plist-get item :pack-title) :clock nil))))
                    (clock (and (eq style 'band) (format-time-string "%H:%M"))))
               (when (or (null (etaf-screensaver--session-template session))
                         (not (equal clock (plist-get context :clock))))
                 (setf (plist-get context :clock) clock
                       (etaf-screensaver--session-template session)
                       (etaf-screensaver--presentation-template style context)))
               (etaf-screensaver--presentation-compose
                (mapcar (lambda (work) (etaf-screensaver--session-scene-rows work t)) works)
                context (etaf-screensaver--session-template session))))
           "\n"))
    (when (etaf-screensaver--session-previous-rows session)
      (let ((progress (/ (etaf-screensaver--session-elapsed session)
                         (etaf-screensaver--session-transition-duration session))))
        (if (>= progress 1)
            (setf (etaf-screensaver--session-previous-rows session) nil)
          ;; Reuse complete native image slices and text rows.  Smoothstep
          ;; eases both ends without recompressing images or making SVGs.
          (let* ((rows (etaf-screensaver--session-window-rows session))
                 (revealed (round (* rows progress progress (- 3 (* 2 progress)))))
                 (incoming (split-string (etaf-screensaver--session-frame session) "\n")))
            (setf (etaf-screensaver--session-frame session)
                  (mapconcat #'identity
                             (append (cl-subseq incoming 0 revealed)
                                     (nthcdr revealed (etaf-screensaver--session-previous-rows session)))
                             "\n"))))))))

(defun etaf-screensaver--session-select (session item seed &optional transition)
  "Initialize SESSION for ITEM at SEED, with optional TRANSITION seconds."
  ;; A delayed tick must not carry unfinished snapshots across many pages.
  ;; Finish the prior reveal before retaining at most one outgoing page.
  (when (etaf-screensaver--session-previous-rows session)
    (setf (etaf-screensaver--session-previous-rows session) nil)
    (etaf-screensaver--session-render session))
  (let* ((previous (when (and transition (> transition 0)
                              (etaf-screensaver--session-frame session)
                              (not (equal item (etaf-screensaver--session-item session))))
                     (let ((frame (copy-sequence (etaf-screensaver--session-frame session))))
                       ;; The outgoing full canvas may have inherited its
                       ;; background.  Freeze that color before the Host changes.
                       (add-face-text-property
                        0 (length frame)
                        (list :background (etaf-screensaver--session-background session)) t frame)
                       (split-string frame "\n"))))
         (tiles (plist-get item :tiles))
         (layout (etaf-screensaver--presentation-layout
                  (plist-get item :presentation)
                  (etaf-screensaver--session-window-columns session)
                  (etaf-screensaver--session-window-rows session)
                  (max 1 (length tiles))))
         (slot (car (plist-get layout :slots))))
    (setf (etaf-screensaver--session-layout session) layout
          (etaf-screensaver--session-previous-rows session) previous
          (etaf-screensaver--session-transition-duration session)
          (and previous (min transition (/ (plist-get item :duration) 2.0)))
          (etaf-screensaver--session-composition-context session) nil
          (etaf-screensaver--session-template session) nil
          (etaf-screensaver--session-columns session) (nth 2 slot)
          (etaf-screensaver--session-rows session) (nth 3 slot)
          (etaf-screensaver--session-item session) item
          (etaf-screensaver--session-scene session) (plist-get item :definition)
          (etaf-screensaver--session-seed session) seed
          (etaf-screensaver--session-random-state session) (cl-make-random-state seed)
          (etaf-screensaver--session-params session) (plist-get item :params)
          (etaf-screensaver--session-ticks session) 0
          (etaf-screensaver--session-elapsed session) 0.0
          (etaf-screensaver--session-dt session) 0.0
          (etaf-screensaver--session-published-frame session) nil
          (etaf-screensaver--session-children session)
          (cl-loop for tile in tiles for rect in (plist-get layout :slots) for index from 0
                   collect (etaf-screensaver--session-create
                            (plist-put (copy-sequence tile) :presentation 'full)
                            (+ seed index) (nth 2 rect) (nth 3 rect) nil))
          (etaf-screensaver--session-state session)
          (unless tiles
            (funcall (etaf-screensaver--scene-create (etaf-screensaver--session-scene session))
                     (etaf-screensaver--session-context session)))))
  (when (etaf-screensaver--session-buffer session)
    (etaf-screensaver--session-render session))
  (cl-incf (etaf-value (etaf-screensaver--session-revision session))))

(defun etaf-screensaver--session-create (item seed columns rows buffer)
  "Create ITEM at SEED and window size COLUMNS by ROWS for BUFFER."
  (let ((session (etaf-screensaver--session-new
                  :window-columns columns :window-rows rows :buffer buffer
                  :size (etaf-ref (cons columns rows)) :revision (etaf-ref 0)
                  :canvas-ref (make-symbol "screensaver-canvas"))))
    (etaf-screensaver--session-select session item seed)
    session))

(defun etaf-screensaver--session-publish (session)
  "Publish SESSION's changed text, colors and images through the retained Host."
  (let ((runtime (etaf-screensaver--session-runtime session))
        (ref (etaf-screensaver--session-canvas-ref session))
        (frame (etaf-screensaver--session-frame session)))
    ;; The canvas Host exists for the whole mount, even when old oversized
    ;; glyphs own no painted cells after a shrink.  Visibility is not a
    ;; precondition for publishing the newly fitted frame that restores them.
    (when (and runtime (etaf-runtime-mounted-p runtime)
               (not (equal-including-properties frame (etaf-screensaver--session-published-frame session))))
      (etaf-runtime-update-host-content
       runtime ref (etaf-screensaver--frame-display frame))
      (etaf-screensaver--session-flush-images session (etaf-screensaver--frame-images frame))
      (setf (etaf-screensaver--session-published-frame session) frame))))

(defun etaf-screensaver--session-step (session dt)
  "Advance SESSION and every independent child by DT, without publishing."
  (setf (etaf-screensaver--session-dt session) dt)
  (if (etaf-screensaver--session-children session)
      (dolist (child (etaf-screensaver--session-children session))
        (etaf-screensaver--session-step child dt))
    (funcall (etaf-screensaver--scene-step (etaf-screensaver--session-scene session))
             (etaf-screensaver--session-state session)
             (etaf-screensaver--session-context session)))
  (cl-incf (etaf-screensaver--session-ticks session))
  (cl-incf (etaf-screensaver--session-elapsed session) dt))

(defun etaf-screensaver--session-advance (session dt)
  "Advance SESSION by DT seconds, compose and publish once."
  (etaf-screensaver--session-step session dt)
  (etaf-screensaver--session-render session)
  (etaf-screensaver--session-publish session))

(defun etaf-screensaver--session-resize (session columns rows)
  "Resize SESSION and each independent work without changing playback order."
  (unless (and (= columns (etaf-screensaver--session-window-columns session))
               (= rows (etaf-screensaver--session-window-rows session)))
    (let* ((children (etaf-screensaver--session-children session))
           (layout (etaf-screensaver--presentation-layout
                    (plist-get (etaf-screensaver--session-item session) :presentation)
                    columns rows (max 1 (length children))))
           (slot (car (plist-get layout :slots)))
           (changed (or (/= (nth 2 slot) (etaf-screensaver--session-columns session))
                        (/= (nth 3 slot) (etaf-screensaver--session-rows session)))))
      ;; A snapshot belongs to its original geometry.  Finish the reveal on
      ;; resize instead of stretching or clipping an obsolete page over it.
      (setf (etaf-screensaver--session-previous-rows session) nil
            (etaf-screensaver--session-window-columns session) columns
            (etaf-screensaver--session-window-rows session) rows
            (etaf-screensaver--session-layout session) layout
            (etaf-screensaver--session-composition-context session) nil
            (etaf-screensaver--session-template session) nil
            (etaf-screensaver--session-columns session) (nth 2 slot)
            (etaf-screensaver--session-rows session) (nth 3 slot))
      (cond
       (children
        (cl-loop for child in children for rect in (plist-get layout :slots)
                 do (etaf-screensaver--session-resize child (nth 2 rect) (nth 3 rect))))
       (changed
        (let ((resize (etaf-screensaver--scene-resize (etaf-screensaver--session-scene session))))
          (if resize
              (setf (etaf-screensaver--session-state session)
                    (funcall resize (etaf-screensaver--session-state session)
                             (etaf-screensaver--session-context session)))
            (etaf-screensaver--session-select session (etaf-screensaver--session-item session)
                                              (etaf-screensaver--session-seed session))))))
      (setf (etaf-value (etaf-screensaver--session-size session)) (cons columns rows))
      (when (etaf-screensaver--session-buffer session)
        (etaf-screensaver--session-render session)
        (etaf-screensaver--session-publish session)))))

(defun etaf-screensaver--session-background (session)
  "Return SESSION's outer canvas color, including its framing mat."
  (let* ((item (etaf-screensaver--session-item session))
         (background (plist-get item :background)))
    (if (eq (plist-get item :presentation) 'full) background
      (plist-get (etaf-screensaver--presentation-palette background) :mat))))

(provide 'etaf-screensaver-engine)
;;; etaf-screensaver-engine.el ends here
