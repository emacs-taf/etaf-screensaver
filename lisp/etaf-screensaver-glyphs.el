;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-glyphs.el --- Scalable recorded text on fixed canvas rows

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Vector glyphs enlarge text, not recorded pixels.  Their slices retain the
;; canvas line metrics and original characters; framing keeps its normal font.
;; SVG currentColor inherits each character's face, so changing color never
;; rebuilds its image descriptor or flushes a still-visible glyph shape.

;;; Code:
(require 'cl-lib)
(require 'svg)
(require 'etaf-screensaver-presentation)

(defun etaf-screensaver--glyph-attribute (face attribute)
  "Read ATTRIBUTE from a face plist, named face or ordered list of faces."
  (let ((value
         (cond ((keywordp (car-safe face)) (plist-get face attribute))
               ((consp face)
                (cl-some (lambda (part) (etaf-screensaver--glyph-attribute part attribute)) face))
               ((and face (facep face)) (face-attribute face attribute nil t)))))
    (unless (eq value 'unspecified) value)))

(defun etaf-screensaver--glyph-focus (rows)
  "Return the nonblank cell bounds (LEFT TOP RIGHT BOTTOM) of ROWS."
  (let (left top right bottom)
    (dotimes (y (length rows))
      (let ((row (aref rows y)) (x 0))
        (dotimes (i (length row))
          (let* ((char (aref row i)) (width (char-width char)))
            (unless (or (zerop width) (memq char '(?\s ?\t)))
              (setq left (if left (min left x) x)
                    top (if top (min top y) y)
                    right (max (or right 0) (+ x width))
                    bottom (1+ y)))
            (cl-incf x width)))))
    (when left (list left top right bottom))))

(defun etaf-screensaver--glyph-slices (char face scale metrics cache)
  "Return CHAR's immutable display slices in FACE at SCALE using METRICS.
Colors come from the displaying character's face, not the image descriptor.
CACHE keeps at most 64 shapes for the current font/scale geometry."
  (let* ((bold (memq (etaf-screensaver--glyph-attribute face :weight) '(bold semi-bold extra-bold ultra-bold)))
         (italic (memq (etaf-screensaver--glyph-attribute face :slant) '(italic oblique)))
         (decoration (mapconcat #'identity
                                (delq nil (list (and (etaf-screensaver--glyph-attribute face :underline) "underline")
                                                (and (etaf-screensaver--glyph-attribute face :strike-through) "line-through")
                                                (and (etaf-screensaver--glyph-attribute face :overline) "overline"))) " "))
         (key (list char bold italic decoration))
         (slices (gethash key cache)))
    (unless slices
      (let* ((width (* scale (char-width char) (plist-get metrics :char-width)))
             (height (* scale (plist-get metrics :line-height)))
             (svg (svg-create width height)))
        (svg-text svg (char-to-string char) :x 0
                  :y (/ (* height (plist-get metrics :ascent)) 100.0)
                  :font-family (plist-get metrics :family)
                  :font-size (* scale (plist-get metrics :font-size))
                  :font-weight (if bold "bold" "normal")
                  :font-style (if italic "italic" "normal")
                  :text-decoration decoration :fill "currentColor")
        (let ((image (svg-image svg :scale 1 :ascent (plist-get metrics :ascent)
                                :max-width width :max-height height))
              (line-height (plist-get metrics :line-height)))
          (setq slices (vconcat (cl-loop for row below scale
                                         collect (list (list 'slice 0 (* row line-height) width line-height) image)))))
        ;; At the bound, keep live entries and compute a transient shape for
        ;; this frame; clearing would rebuild every shape on every frame.
        (when (< (hash-table-count cache) 64) (puthash key slices cache))))
    slices))

(defun etaf-screensaver--glyph-runs (char face scale metrics shapes paints)
  "Return immutable styled slice strings for CHAR and FACE.
SHAPES caches geometry; PAINTS keeps at most 512 styled glyphs, separately
from the shape's native image so color changes never rebuild its SVG."
  (let* ((key (cons char face)) (runs (gethash key paints)))
    (unless runs
      (let* ((width (char-width char)) (span (* width scale))
             (slices (unless (= char ?\s) (etaf-screensaver--glyph-slices char face scale metrics shapes))))
        (setq runs (make-vector scale nil))
        (dotimes (slice scale)
          (let ((text (if (= slice 0)
                          (concat (char-to-string char) (make-string (- span width) ?\s))
                        (make-string span ?\s))))
            (when face (put-text-property 0 (length text) 'face face text))
            (when slices (put-text-property 0 (length text) 'display (aref slices slice) text))
            (aset runs slice text)))
        (when (< (hash-table-count paints) 512) (puthash key runs paints))))
    runs))

(defun etaf-screensaver--glyph-rows (source focus columns rows scale metrics cache paints base)
  "Enlarge SOURCE's FOCUS over BASE, retaining the surrounding animation.
Fit into COLUMNS by ROWS with SCALE-cell glyphs.  METRICS, bounded shape
CACHE and styled PAINTS belong to this geometry.  Never alter source rows."
  (let* ((source-columns (- (nth 2 focus) (nth 0 focus)))
         (source-rows (- (nth 3 focus) (nth 1 focus)))
         (source-left (nth 0 focus))
         (source-top (nth 1 focus))
         (left (/ (- columns (* source-columns scale)) 2))
         (top (/ (- rows (* source-rows scale)) 2))
         (right (+ left (* source-columns scale)))
         (bottom (+ top (* source-rows scale)))
         (base (vconcat base))
         (output (make-vector rows nil))
         (ends (make-vector rows left)))
    (cl-loop for y from top below bottom
             do (aset output y (list (etaf-screensaver--presentation-crop (aref base y) left))))
    (dotimes (row source-rows)
      (let ((y (+ source-top row)))
        (when (and (>= y 0) (< y (length source)))
          (let ((text (aref source y)) (column 0))
            (dotimes (index (length text))
              (let* ((char (aref text index)) (width (char-width char))
                     (x (+ left (* (- column source-left) scale)))
                     (span (* width scale))
                     (face (get-text-property index 'face text)))
                (when (and (> width 0) (>= column source-left)
                           (<= (+ column width) (nth 2 focus))
                           (>= x left) (<= (+ x span) right)
                           (or (/= char ?\s) (etaf-screensaver--glyph-attribute face :background)
                               (etaf-screensaver--glyph-attribute face :inverse-video)))
                  (let ((runs (etaf-screensaver--glyph-runs char face scale metrics cache paints)))
                    (dotimes (slice scale)
                      (let* ((y (+ top (* row scale) slice))
                             (end (aref ends y)))
                        (when (> x end) (push (make-string (- x end) ?\s) (aref output y)))
                        (push (aref runs slice) (aref output y))
                        (aset ends y (+ x span))))))
                (cl-incf column width)))))))
    (cl-loop for y below rows
             for parts = (aref output y)
             collect (if (or (< y top) (>= y bottom)) (aref base y)
                       (concat (apply #'concat (nreverse parts))
                               (make-string (- right (aref ends y)) ?\s)
                               (etaf-screensaver--presentation-crop (aref base y) (- columns right) right))))))

(provide 'etaf-screensaver-glyphs)
;;; etaf-screensaver-glyphs.el ends here
