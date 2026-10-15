;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-presentation.el --- Viewport geometry and composition

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Geometry is computed once for both scene contexts and composition.  A wall
;; holds independent works, never pieces of one frame.  Below the minimum
;; canvas we clip the same geometry instead of passing negative sizes to scenes.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-model)

(defconst etaf-screensaver--presentation-styles '(full card band mosaic)
  "Supported presentation styles.")

(defun etaf-screensaver--presentation-rgb (color)
  "Return the RGB channels of a six-digit hex COLOR, or nil."
  (when (and (stringp color) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color))
    (cl-loop for start in '(1 3 5)
             collect (string-to-number (substring color start (+ start 2)) 16))))

(defun etaf-screensaver--presentation-mix (color toward share)
  "Mix COLOR with TOWARD by SHARE, a fraction from zero to one."
  (apply #'format "#%02x%02x%02x"
         (cl-mapcar (lambda (a b) (round (+ (* a (- 1 share)) (* b share))))
                    (etaf-screensaver--presentation-rgb color)
                    (etaf-screensaver--presentation-rgb toward))))

(defun etaf-screensaver--presentation-palette (background)
  "Derive framing colors from BACKGROUND, without recoloring the work."
  (let* ((base (if (etaf-screensaver--presentation-rgb background) background "#05070B"))
         (rgb (etaf-screensaver--presentation-rgb base))
         (light (> (+ (* .299 (nth 0 rgb)) (* .587 (nth 1 rgb)) (* .114 (nth 2 rgb))) 128))
         (contrast (if light "#000000" "#FFFFFF"))
         (mat (etaf-screensaver--presentation-mix base "#000000" (if light .92 .4))))
    (list :mat mat :mat-text (etaf-screensaver--presentation-mix mat "#FFFFFF" .65)
          :paper base
          :border (etaf-screensaver--presentation-mix base contrast .28)
          :text (etaf-screensaver--presentation-mix base contrast .72))))

(defun etaf-screensaver--presentation-crop (text width &optional start)
  "Fit TEXT to WIDTH display columns starting at START, preserving properties.
A partially visible wide character becomes padding.  Cropped image runs keep
only the corresponding horizontal slice, rather than displaying the full image
from a shortened character span.  Reel image runs reserve their cell footprint."
  (let ((start (or start 0)) (position 0) (column 0) pieces)
    (while (and (< position (length text)) (< column (+ start width)))
      (let* ((end (next-single-property-change position 'display text (length text)))
             (run (substring text position end))
             (cells (string-width run))
             (from (max 0 (- start column)))
             (to (min cells (- (+ start width) column))))
        (when (< from to)
          (let* ((piece (truncate-string-to-width run to from ?\s))
                 (display (get-text-property position 'display text))
                 (slice (car-safe display)))
            (when (and (eq (car-safe slice) 'slice) (> cells 0)
                       (or (> from 0) (< to cells)))
              (let* ((x (nth 1 slice)) (w (nth 3 slice))
                     (left (round (* w (/ (float from) cells)))))
                (put-text-property
                 0 (length piece) 'display
                 (list (list 'slice (+ x left) (nth 2 slice)
                             (- (round (* w (/ (float to) cells))) left)
                             (nth 4 slice))
                       (cadr display)) piece)))
            (push piece pieces)))
        (setq column (+ column cells) position end)))
    (let ((result (apply #'concat (nreverse pieces))))
      (concat result (make-string (max 0 (- width (string-width result))) ?\s)))))

(defun etaf-screensaver--presentation-layout (style columns rows &optional count)
  "Return STYLE's layout with COLUMNS, ROWS and COUNT independent works.
Slots are (X Y WIDTH HEIGHT) content rectangles.  The same slots size the
callbacks and place their output.  A narrow wall stacks works vertically."
  (let* ((width (if (eq style 'full) columns (max 24 columns)))
         (height (if (eq style 'full) rows (max 10 rows)))
         (count (or count 1)))
    (pcase style
      ('full (list :width width :height height :slots (list (list 0 0 width height))))
      ('card
       (let* ((w (max 8 (round (* width .7))))
              (h (max 6 (round (* height .74))))
              (x (/ (- width w) 2)) (y (/ (- height h) 2)))
         (list :width width :height height
               :slots (list (list (1+ x) (1+ y) (- w 2) (- h 3))))))
      ('band
       (let* ((h (max 3 (min (- height 5) (round (* height .5)))))
              (y (max 1 (/ (- height (+ h 3)) 2))))
         ;; Reserve a clock row below the picture, within the band.  It never
         ;; overwrites a work's last line or replaces an image slice.
         (list :width width :height height :slots (list (list 0 (1+ y) width h)))))
      ('mosaic
       (let* ((across (if (and (> count 1) (>= width 64)) 2 1))
              (down (ceiling count across))
              (height (max height (* down 6)))
              (cell-w (/ (- width (1- across)) across))
              (cell-h (/ (- height (1- down)) down))
              slots)
         (dotimes (index count)
           (let* ((col (% index across)) (row (/ index across))
                  (x (* col (1+ cell-w))) (y (* row (1+ cell-h)))
                  (w (if (= col (1- across)) (- width x) cell-w))
                  (h (if (= row (1- down)) (- height y) cell-h)))
             (push (list (1+ x) (1+ y) (- w 2) (- h 3)) slots)))
         (list :width width :height height :slots (nreverse slots))))
      (_ (etaf-screensaver--fail "Unknown presentation style: %s" style)))))

(defun etaf-screensaver--presentation-put (canvas x y text)
  "Place property-bearing TEXT at X,Y in row-vector CANVAS."
  (when (and (>= y 0) (< y (length canvas)))
    (let* ((row (aref canvas y)) (width (string-width row))
           (text (etaf-screensaver--presentation-crop text (min (- width x) (string-width text))))
           (end (+ x (string-width text))))
      (aset canvas y (concat (etaf-screensaver--presentation-crop row x)
                            text (etaf-screensaver--presentation-crop row (- width end) end))))))

(defun etaf-screensaver--presentation-label (text width foreground background)
  "Return a WIDTH-column TEXT label in FOREGROUND on BACKGROUND."
  (propertize (etaf-screensaver--presentation-crop text width)
              'face (list :foreground foreground :background background)))

(defun etaf-screensaver--presentation-compose (style frames context)
  "Compose STYLE's independent FRAMES using CONTEXT's layout and captions.
FRAMES is a list of row lists.  CONTEXT holds :layout, actual :columns/:rows,
:backgrounds and :titles in work order, :pack-title and optional :clock."
  (let* ((layout (plist-get context :layout))
         (width (plist-get layout :width))
         (height (plist-get layout :height))
         (backgrounds (plist-get context :backgrounds))
         (palette (etaf-screensaver--presentation-palette (car backgrounds)))
         (mat (plist-get palette :mat))
         (blank (propertize (make-string width ?\s) 'face (list :background mat)))
         (canvas (make-vector height blank)))
    (cl-loop for frame in frames
             for slot in (plist-get layout :slots)
             for title in (plist-get context :titles)
             for background in backgrounds
             do
             (pcase-let ((`(,x ,y ,w ,h) slot))
               (let* ((colors (etaf-screensaver--presentation-palette background))
                      (paper (plist-get colors :paper))
                      (border (list :foreground (plist-get colors :border) :background paper))
                      (caption (if (and (not (eq style 'mosaic)) (plist-get context :pack-title))
                                   (format "%s · %s" (plist-get context :pack-title) title)
                                 title)))
                 (cl-loop for row in frame for index from 0 below h
                          do (etaf-screensaver--presentation-put canvas x (+ y index) row))
                 (pcase style
                   ((or 'card 'mosaic)
                    (etaf-screensaver--presentation-put
                     canvas (1- x) (1- y)
                     (propertize (concat "┌" (make-string w ?─) "┐") 'face border))
                    (dotimes (row (1+ h))
                      (etaf-screensaver--presentation-put canvas (1- x) (+ y row) (propertize "│" 'face border))
                      (etaf-screensaver--presentation-put canvas (+ x w) (+ y row) (propertize "│" 'face border)))
                    (etaf-screensaver--presentation-put
                     canvas x (+ y h)
                     (etaf-screensaver--presentation-label caption w (plist-get colors :text) paper))
                    (etaf-screensaver--presentation-put
                     canvas (1- x) (+ y h 1)
                     (propertize (concat "└" (make-string w ?─) "┘") 'face border)))
                   ('band
                    (let* ((clock (or (plist-get context :clock) (format-time-string "%H:%M")))
                           (clock-row (concat (make-string (max 0 (- w (string-width clock) 2)) ?\s) clock "  ")))
                      (etaf-screensaver--presentation-put canvas 0 (1- y) (propertize (make-string w ?─) 'face border))
                      (etaf-screensaver--presentation-put
                       canvas 0 (+ y h) (etaf-screensaver--presentation-label clock-row w (plist-get colors :text) paper))
                      (etaf-screensaver--presentation-put canvas 0 (+ y h 1) (propertize (make-string w ?─) 'face border))
                      (etaf-screensaver--presentation-put
                       canvas 0 (+ y h 2)
                       (etaf-screensaver--presentation-label (concat " " caption) w (plist-get palette :mat-text) mat))))))))
    (cl-loop for index below (plist-get context :rows)
             collect (etaf-screensaver--presentation-crop
                      (if (< index height) (aref canvas index) blank)
                      (plist-get context :columns)))))

(provide 'etaf-screensaver-presentation)
;;; etaf-screensaver-presentation.el ends here
