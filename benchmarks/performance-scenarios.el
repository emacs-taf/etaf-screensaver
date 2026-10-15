;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Autonomous screensaver frame cadence

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run through the workspace performance.py driver.  A sample waits for the
;; next autonomous frame, including timer wait, computation and publication.
;; Version 2 replaces the retired manual-step workspace workload and is not
;; comparable to it.  Cleanup restores the driver's original window state.

;;; Code:
(require 'etaf-screensaver)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-screensaver-benchmark--fixture (scene &optional presentation)
  "Return a seeded cadence fixture for SCENE with PRESENTATION."
  (let* ((etaf-screensaver-seed 4242)
         (etaf-screensaver-max-frame-rate 30)
         (buffer (etaf-screensaver-start
                  (if (eq presentation 'mosaic)
                      '(:presentation mosaic :scenes
                        ((:scene tte-beams :duration 3600 :frame-rate 30)
                         (:scene tte-synthgrid :duration 3600)
                         (:scene tte-ink-waves :duration 3600)
                         (:scene benchmark-large :duration 3600)))
                    (list :scene scene :duration 3600 :frame-rate 30
                          :presentation (or presentation 'full)))))
         (ticks 0))
    (list :buffer buffer
          :prepare (lambda () (setq ticks (plist-get (etaf-screensaver-status) :ticks)))
          :invoke #'ignore
          :settled (lambda ()
                     (let ((now (plist-get (etaf-screensaver-status) :ticks)))
                       (and now (> now ticks))))
          :verify (lambda ()
                    (let ((status (etaf-screensaver-status)))
                      (if (and (plist-get status :active)
                               (eq (plist-get status :scene) scene)
                               (> (plist-get status :ticks) ticks))
                          t "The autonomous scene did not publish another frame")))
          :cleanup #'etaf-screensaver-stop)))

(etaf-screensaver-register-reel
 (list :id 'benchmark-frames :provider 'frames :frame-rate 30
       :recording (expand-file-name "../tests/fixtures/frames/sample.frames.json"
                                    (file-name-directory
                                     (locate-library "etaf-screensaver-loader")))
       :title "Baked fixture"))

(dolist (scene '(plasma matrix life quotes tte-thunderstorm benchmark-frames))
  (taf-benchmark-register
   (format "etaf-screensaver.frame.%s" scene)
   :version 2 :modes '(batch gui) :isolation 'series :impact 'local
   :budget-ms 100
   :description (format "Wait for the next autonomous %s frame at a 30 fps cap" scene)
   :setup (lambda (_mode) (etaf-screensaver-benchmark--fixture scene))))

(etaf-screensaver-register-reel
 (list :id 'benchmark-large :provider 'frames :frame-rate 30
       :recording (expand-file-name "../tests/fixtures/frames/large.frames.json"
                                    (file-name-directory
                                     (locate-library "etaf-screensaver-loader")))
       :title "960x540 JPEG fixture"))

(dolist (style '(full card band mosaic))
  (let ((style style))
    (taf-benchmark-register
     (format "etaf-screensaver.presentation.%s" style)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'local
     :budget-ms 100
     :description (format "Autonomous %s composition with native 960x540 JPEG frames" style)
     :setup (lambda (_mode)
              (etaf-screensaver-benchmark--fixture
               (if (eq style 'mosaic) 'tte-beams 'benchmark-large) style)))))

(provide 'etaf-screensaver-performance-scenarios)
;;; performance-scenarios.el ends here
