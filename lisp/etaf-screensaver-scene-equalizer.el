;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-scene-equalizer.el --- Monochrome bars on paper

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A quiet equalizer for the light page: solid bars rise and fall like a
;; level meter, drawn in one ink color.  Bar count, width and height follow
;; the canvas, so a wide window shows wider bars rather than a stretched
;; image.  No recording, no image, no color gradient.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-model)

(defconst etaf-screensaver--equalizer-ink "#2B3036"
  "Ink color for the light equalizer page.")

(etaf-screensaver-define-scene equalizer
  :title "墨线律动"
  :summary "单色竖柱随节拍起伏"
  :tags '(bars ink)
  :frame-rate 24
  :background "#F4F1EA"
  :create
  (lambda (context)
    (let ((random (plist-get context :random)))
      (list :phases (cl-loop repeat 32 collect (* (funcall random) 6.283))
            :rates (cl-loop repeat 32 collect (+ .7 (* (funcall random) 1.5)))
            :ink (list :foreground etaf-screensaver--equalizer-ink))))
  :step (lambda (_state _context) nil)
  :render
  (lambda (state context)
    (let* ((columns (plist-get context :columns))
           (rows (plist-get context :rows))
           (elapsed (plist-get context :elapsed))
           (count (max 6 (min 28 (/ (- columns 6) 5))))
           (gap (if (>= columns 60) 2 1))
           (bar (max 1 (/ (- columns 4 (* gap (1- count))) count)))
           (baseline (- rows 4))
           (height (max 1 (- baseline 3)))
           (phases (plist-get state :phases))
           (rates (plist-get state :rates))
           (ink (list :foreground etaf-screensaver--equalizer-ink))
           (left (/ (- columns (+ (* count bar) (* gap (1- count)))) 2))
           (bar-text (propertize (make-string bar ?█) 'face ink))
           (levels (make-vector count 1)))
      (dotimes (index count)
        (let ((level (+ (* .5 (sin (+ (* elapsed (nth index rates)) (nth index phases))))
                        (* .32 (sin (+ (* elapsed (nth index rates) 2.7)
                                       (* 1.7 (nth index phases)))))
                        .5)))
          (aset levels index (max 1 (round (* height (max .06 (min 1 level))))))))
      ;; Rows are assembled left to right: a bar owns a fixed column range,
      ;; so one pass per row emits its own cells without splicing strings.
      (cl-loop for row below rows
               collect
               (if (or (>= row baseline) (< row (- baseline height)))
                   (make-string columns ?\s)
                 (let ((parts nil) (column 0))
                   (dotimes (index count)
                     (let* ((cells (aref levels index))
                            (x (+ left (* index (+ bar gap))))
                            (top (- baseline cells)))
                       (when (and (>= row top) (< row baseline))
                         (when (> x column)
                           (push (make-string (- x column) ?\s) parts)
                           (setq column x))
                         (push bar-text parts)
                         (setq column (+ x bar)))))
                   (when (< column columns)
                     (push (make-string (- columns column) ?\s) parts))
                   (apply #'concat (nreverse parts))))))))

(provide 'etaf-screensaver-scene-equalizer)
;;; etaf-screensaver-scene-equalizer.el ends here
