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

(defun etaf-screensaver--glyph-image (char face scale metrics cache)
  "Return CHAR's vector shape in FACE at SCALE, using METRICS and CACHE.
Colors come from the displaying character's face, not the image descriptor.
Keep at most 256 shapes for the current font/scale geometry."
  (let* ((bold (memq (etaf-screensaver--glyph-attribute face :weight) '(bold semi-bold extra-bold ultra-bold)))
         (italic (memq (etaf-screensaver--glyph-attribute face :slant) '(italic oblique)))
         (decoration (mapconcat #'identity
                                (delq nil (list (and (etaf-screensaver--glyph-attribute face :underline) "underline")
                                                (and (etaf-screensaver--glyph-attribute face :strike-through) "line-through")
                                                (and (etaf-screensaver--glyph-attribute face :overline) "overline"))) " "))
         (key (list char bold italic decoration))
         (image (gethash key cache)))
    (unless image
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
        (setq image (svg-image svg :scale 1 :ascent (plist-get metrics :ascent)
                               :max-width width :max-height height))
        (when (>= (hash-table-count cache) 256) (clrhash cache))
        (puthash key image cache)))
    image))

(defun etaf-screensaver--glyph-rows (source focus columns rows scale metrics cache base)
  "Enlarge SOURCE's FOCUS over BASE, retaining the surrounding animation.
Fit into COLUMNS by ROWS with SCALE-cell glyphs.  METRICS and bounded CACHE
belong to the current work geometry.  Never alter source rows."
  (let* ((source-columns (- (nth 2 focus) (nth 0 focus)))
         (source-rows (- (nth 3 focus) (nth 1 focus)))
         (source-left (nth 0 focus))
         (source-top (nth 1 focus))
         (left (/ (- columns (* source-columns scale)) 2))
         (top (/ (- rows (* source-rows scale)) 2))
         (right (+ left (* source-columns scale)))
         (bottom (+ top (* source-rows scale)))
         (base (vconcat base))
         (line-height (plist-get metrics :line-height))
         (cell-width (plist-get metrics :char-width))
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
                  (let ((image (unless (= char ?\s)
                                 (etaf-screensaver--glyph-image char face scale metrics cache))))
                    (dotimes (slice scale)
                      (let* ((y (+ top (* row scale) slice))
                             (end (aref ends y))
                             ;; A wide character stays one character while
                             ;; its replacing run reserves every covered cell.
                             (text (if (= slice 0)
                                       (concat (char-to-string char) (make-string (- span width) ?\s))
                                     (make-string span ?\s))))
                        (when (> x end) (push (make-string (- x end) ?\s) (aref output y)))
                        (when face (put-text-property 0 (length text) 'face face text))
                        (when image
                          (put-text-property
                           0 (length text) 'display
                           (list (list 'slice 0 (* slice line-height)
                                       (* span cell-width) line-height)
                                 image)
                           text))
                        (push text (aref output y))
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
