;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-engine.el --- Scene frames and retained publication

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The scene engine owns no timers, windows or input hooks.  Its owner passes
;; elapsed time, changes the viewport and disposes the mounted Runtime.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-playlist)
(declare-function image-flush "image.c" (image &optional frame))

(cl-defstruct (etaf-screensaver--session (:constructor etaf-screensaver--session-new))
  scene state item seed random-state columns rows size revision params
  ticks elapsed dt frame published-frame images canvas-ref runtime buffer)

(defun etaf-screensaver--session-metrics (session)
  "Return SESSION's effective display metrics, or nil before it is mounted."
  (let ((runtime (etaf-screensaver--session-runtime session)))
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (ignore-errors (etaf-display-metrics runtime)))))

(defun etaf-screensaver--frame-images (frame)
  "Return the distinct image objects FRAME displays."
  (let ((position 0) (length (length frame)) (images nil))
    (while (< position length)
      (let ((display (get-text-property position 'display frame)))
        (when (and (listp display) (listp (cdr display))
                   (listp (cadr display)) (eq (car (cadr display)) 'image))
          (cl-pushnew (cadr display) images :test #'equal)))
      (setq position (next-single-property-change position 'display frame length)))
    images))

(defun etaf-screensaver--session-flush-images (session keep)
  "Flush SESSION's retained images that KEEP does not contain, then keep KEEP."
  (dolist (image (etaf-screensaver--session-images session))
    (unless (member image keep)
      (ignore-errors (image-flush image))))
  (setf (etaf-screensaver--session-images session) keep))

(defun etaf-screensaver--session-context (session)
  "Return the pure scene callback context for SESSION."
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

(defun etaf-screensaver--session-render (session)
  "Project SESSION into a property-preserving rectangular frame."
  (let* ((frame (funcall (etaf-screensaver--scene-render (etaf-screensaver--session-scene session))
                         (etaf-screensaver--session-state session)
                         (etaf-screensaver--session-context session)))
         (lines (cond ((stringp frame) (split-string frame "\n"))
                      ((proper-list-p frame) frame)
                      (t (etaf-screensaver--fail "Scene must render a string or row list"))))
         (columns (etaf-screensaver--session-columns session)))
    (setf (etaf-screensaver--session-frame session)
          (mapconcat
           (lambda (row)
             (let ((line (or (nth row lines) "")))
               (unless (stringp line) (etaf-screensaver--fail "Scene rows must be strings"))
               (truncate-string-to-width
                (string-replace "\r" "" (string-replace "\t" " " line)) columns nil ?\s)))
           (number-sequence 0 (1- (etaf-screensaver--session-rows session))) "\n"))))

(defun etaf-screensaver--session-select (session item seed)
  "Recreate SESSION for ITEM at SEED, before notifying the view."
  (etaf-screensaver--session-flush-images session nil)
  (setf (etaf-screensaver--session-item session) item
        (etaf-screensaver--session-scene session) (plist-get item :definition)
        (etaf-screensaver--session-seed session) seed
        (etaf-screensaver--session-random-state session) (cl-make-random-state seed)
        (etaf-screensaver--session-params session) (plist-get item :params)
        (etaf-screensaver--session-ticks session) 0
        (etaf-screensaver--session-elapsed session) 0.0
        (etaf-screensaver--session-dt session) 0.0
        (etaf-screensaver--session-published-frame session) nil
        (etaf-screensaver--session-state session)
        (funcall (etaf-screensaver--scene-create (etaf-screensaver--session-scene session))
                 (etaf-screensaver--session-context session)))
  (etaf-screensaver--session-render session)
  (cl-incf (etaf-value (etaf-screensaver--session-revision session))))

(defun etaf-screensaver--session-create (item seed columns rows buffer)
  "Create a scene from ITEM and SEED at COLUMNS by ROWS for BUFFER."
  (let ((session (etaf-screensaver--session-new
                  :columns columns :rows rows :buffer buffer
                  :size (etaf-ref (cons columns rows)) :revision (etaf-ref 0)
                  :canvas-ref (make-symbol "screensaver-canvas"))))
    (etaf-screensaver--session-select session item seed)
    session))

(defun etaf-screensaver--session-publish (session)
  "Publish SESSION's changed frame through the committed retained Host."
  (let ((runtime (etaf-screensaver--session-runtime session))
        (ref (etaf-screensaver--session-canvas-ref session))
        (frame (etaf-screensaver--session-frame session)))
    (when (and runtime (etaf-runtime-mounted-p runtime)
               (etaf-host-ref-bounds runtime ref)
               (not (equal frame (etaf-screensaver--session-published-frame session))))
      (etaf-runtime-update-host-content runtime ref frame)
      (etaf-screensaver--session-flush-images
       session (etaf-screensaver--frame-images frame))
      (setf (etaf-screensaver--session-published-frame session) frame))))

(defun etaf-screensaver--session-advance (session dt)
  "Advance SESSION by DT seconds, render and publish it."
  (setf (etaf-screensaver--session-dt session) dt)
  (funcall (etaf-screensaver--scene-step (etaf-screensaver--session-scene session))
           (etaf-screensaver--session-state session)
           (etaf-screensaver--session-context session))
  (cl-incf (etaf-screensaver--session-ticks session))
  (cl-incf (etaf-screensaver--session-elapsed session) dt)
  (etaf-screensaver--session-render session)
  (etaf-screensaver--session-publish session))

(defun etaf-screensaver--session-resize (session columns rows)
  "Resize SESSION to COLUMNS by ROWS without changing playback policy."
  (unless (and (= columns (etaf-screensaver--session-columns session))
               (= rows (etaf-screensaver--session-rows session)))
    (setf (etaf-screensaver--session-columns session) columns
          (etaf-screensaver--session-rows session) rows)
    (let ((resize (etaf-screensaver--scene-resize (etaf-screensaver--session-scene session))))
      (if resize
          (progn
            (setf (etaf-screensaver--session-state session)
                  (funcall resize (etaf-screensaver--session-state session)
                           (etaf-screensaver--session-context session)))
            (etaf-screensaver--session-render session))
        (etaf-screensaver--session-select session (etaf-screensaver--session-item session)
                                         (etaf-screensaver--session-seed session))))
    (setf (etaf-value (etaf-screensaver--session-size session)) (cons columns rows)
          (etaf-screensaver--session-published-frame session) nil)
    (etaf-screensaver--session-publish session)))

(provide 'etaf-screensaver-engine)
;;; etaf-screensaver-engine.el ends here
