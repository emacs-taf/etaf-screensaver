;;; etaf-screensaver-banner.el --- ASCII banner with terminal effects -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The Omarchy-style screensaver: an ASCII banner is revealed by a terminal
;; text effect, the effect holds, then the next effect takes over, looping
;; forever.  Effects come from one registry: print, wipe, dissolve, decrypt,
;; rain, beams, middleout and spray.  Every effect computes, per art cell, the
;; progress at which it settles plus an optional transient position, so the
;; layer stays a pure projection of its state.
;;
;; The whole effect runs in one color chosen from :colors, and the art block
;; is centered in the canvas, so a spec only carries the banner text and the
;; timing.

;;; Code:

(require 'cl-lib)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-dsl)

(defconst etaf-screensaver--banner-effects
  '(print wipe dissolve decrypt rain beams middleout spray)
  "Effects a banner layer may run, in rotation order.")

(defconst etaf-screensaver--banner-glyphs "01<>*+=-#"
  "Glyphs an unsettled effect cell shows.")

(defun etaf-screensaver--banner-art (art)
  "Return ART as a list of nonempty line strings."
  (let ((lines (cond ((stringp art) (split-string art "\n"))
                     ((proper-list-p art) art)
                     (t (etaf-screensaver--fail
                         "banner :art must be a string or a list of lines")))))
    (when (cl-some (lambda (line) (not (stringp line))) lines)
      (etaf-screensaver--fail "banner :art lines must be strings"))
    (when (cl-every (lambda (line) (equal "" line)) lines)
      (etaf-screensaver--fail "banner :art must not be blank"))
    lines))

(defun etaf-screensaver--banner-cells (lines random)
  "Return banner cells for LINES as (WIDTH . VECTOR).
Each cell is a [ROW COLUMN CHAR R1 R2] vector; COLUMN is the character's
display column, so wide characters keep a consistent grid."
  (let ((width 0)
        (cells nil)
        (row 0))
    (dolist (line lines)
      (let ((column 0))
        (dotimes (index (length line))
          (let* ((character (aref line index))
                 (cell-width (char-width character)))
            (unless (eq character ?\s)
              (push (vector row column character
                            (funcall random) (funcall random))
                    cells))
            (cl-incf column cell-width)))
        (setq width (max width column)))
      (cl-incf row))
    (cons width (vconcat (nreverse cells)))))

(defun etaf-screensaver--banner-glyph (random)
  "Return a random transient glyph for RANDOM."
  (aref etaf-screensaver--banner-glyphs
        (funcall random (length etaf-screensaver--banner-glyphs))))

(defun etaf-screensaver--banner-threshold (effect cell width rows index count progress random)
  "Return when CELL settles for EFFECT and its transient, if any.
CELL is [ROW COLUMN CHAR R1 R2], INDEX its order and COUNT the cell total.
The result is (THRESHOLD . GHOST); GHOST is nil until THRESHOLD passes, then
a (ROW-OFFSET COLUMN-OFFSET GLYPH) drawn at that offset instead of the final
character."
  (let* ((row (aref cell 0))
         (column (aref cell 1))
         (r1 (aref cell 3))
         (r2 (aref cell 4))
         (last (max 1 (1- count)))
         (settled (lambda (threshold)
                    (if (>= progress threshold)
                        (cons threshold nil)
                      (cons threshold
                            (pcase effect
                              ('decrypt (when (< r2 0.35)
                                          (list 0 0 (etaf-screensaver--banner-glyph random))))
                              ('rain (let ((head (- (* progress (+ rows 6.0))
                                                    3.0 (* r1 4.0))))
                                       (when (and (<= row head) (< (- head row) 3.0))
                                         (list 0 0 (etaf-screensaver--banner-glyph random)))))
                              ('spray (let* ((angle (* r2 2 float-pi))
                                             (distance (* (- 1.0 (min 1.0 progress)) 8.0)))
                                        (list (round (* distance (sin angle)))
                                              (round (* 1.5 distance (cos angle)))
                                              (etaf-screensaver--banner-glyph random))))
                              (_ nil)))))))
    (pcase effect
      ('print (funcall settled (/ (float index) last)))
      ('wipe (funcall settled (+ (* 0.9 (/ (float column) (max 1 width)))
                                 (* 0.1 r1))))
      ('dissolve (funcall settled r1))
      ('decrypt (funcall settled r1))
      ('beams (funcall settled (/ (float (+ row column))
                                  (max 1 (+ width rows)))))
      ('middleout
       (let* ((half-row (/ rows 2.0))
              (half-column (/ width 2.0))
              (distance (sqrt (+ (expt (- row half-row) 2)
                                 (expt (* 2 (- column half-column)) 2))))
              (far (sqrt (+ (expt half-row 2) (expt (* 2 half-column) 2)))))
         (funcall settled (min 1.0 (/ distance (max 1.0 far))))))
      ('rain (funcall settled (/ (float row) (max 1 rows))))
      ('spray (funcall settled r1))
      (_ (funcall settled r1)))))

(defun etaf-screensaver--banner-next-effect (effects current random)
  "Return EFFECTS' next effect after CURRENT, chosen with RANDOM."
  (let ((others (cl-remove current effects)))
    (if others (nth (funcall random (length others)) others) current)))

(etaf-screensaver--define-layer-kind 'banner
  :validate (lambda (layer)
              (etaf-screensaver--banner-art (plist-get layer :art))
              (let ((effects (plist-get layer :effects)))
                (when effects
                  (unless (and (proper-list-p effects)
                               (cl-every (lambda (effect)
                                           (memq effect etaf-screensaver--banner-effects))
                                         effects))
                    (etaf-screensaver--fail
                     "banner :effects must be a list of %S"
                     etaf-screensaver--banner-effects)))))
  :create (lambda (layer context)
            (let* ((lines (etaf-screensaver--banner-art (plist-get layer :art)))
                   (cells (etaf-screensaver--banner-cells lines
                                                          (plist-get context :random)))
                   (effects (or (plist-get layer :effects)
                                etaf-screensaver--banner-effects)))
              (list :cells (cdr cells)
                    :width (car cells)
                    :rows (length lines)
                    :effects effects
                    :effect (car effects)
                    :elapsed 0.0
                    :color (or (car (plist-get layer :colors)) "#E8ECF1"))))
  :step (lambda (layer state context)
          (let* ((random (plist-get context :random))
                 (etaf-screensaver--dsl-random random)
                 (env (etaf-screensaver--dsl-env context))
                 (effect-time (max 0.05 (etaf-screensaver--layer-number
                                         (etaf-screensaver--layer-property layer :effect-time 3.0)
                                         env 3.0)))
                 (hold (max 0.0 (etaf-screensaver--layer-number
                                 (etaf-screensaver--layer-property layer :hold 0.8)
                                 env 0.8)))
                 (elapsed (+ (plist-get state :elapsed) (plist-get context :dt))))
            (if (>= elapsed (+ effect-time hold))
                (progn
                  (setf (plist-get state :elapsed) 0.0
                        (plist-get state :effect)
                        (etaf-screensaver--banner-next-effect
                         (plist-get state :effects) (plist-get state :effect) random)
                        (plist-get state :color)
                        (let ((colors (plist-get layer :colors)))
                          (if (and (proper-list-p colors) colors)
                              (nth (funcall random (length colors)) colors)
                            (or (car-safe colors) "#E8ECF1")))))
              (setf (plist-get state :elapsed) elapsed))))
  :draw (lambda (layer state context canvas)
          (let* ((random (plist-get context :random))
                 (rows (plist-get context :rows))
                 (columns (plist-get context :columns))
                 (etaf-screensaver--dsl-random random)
                 (env (etaf-screensaver--dsl-env context))
                 (effect-time (max 0.05 (etaf-screensaver--layer-number
                                         (etaf-screensaver--layer-property layer :effect-time 3.0)
                                         env 3.0)))
                 (progress (min 1.0 (/ (plist-get state :elapsed) effect-time)))
                 (cells (plist-get state :cells))
                 (width (plist-get state :width))
                 (art-rows (plist-get state :rows))
                 (effect (plist-get state :effect))
                 (color (plist-get state :color))
                 (offset-row (max 0 (/ (- rows art-rows) 2)))
                 (offset-column (max 0 (/ (- columns width) 2))))
            (dotimes (index (length cells))
              (let* ((cell (aref cells index))
                     (outcome (etaf-screensaver--banner-threshold
                               effect cell width art-rows index (length cells)
                               progress random)))
                (pcase-let ((`(,settle . ,ghost) outcome))
                  (if (>= progress settle)
                      (etaf-screensaver--canvas-draw
                       canvas (+ offset-row (aref cell 0))
                       (+ offset-column (aref cell 1))
                       (aref cell 2) color)
                    (when ghost
                      (pcase-let ((`(,row-offset ,column-offset ,glyph) ghost))
                        (etaf-screensaver--canvas-draw
                         canvas (+ offset-row (aref cell 0) row-offset)
                         (+ offset-column (aref cell 1) column-offset)
                         glyph color))))))))))

(provide 'etaf-screensaver-banner)
;;; etaf-screensaver-banner.el ends here
