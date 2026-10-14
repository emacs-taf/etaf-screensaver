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

(defun etaf-screensaver-benchmark--fixture (scene)
  "Return an autonomous, seeded frame fixture for SCENE."
  (let* ((etaf-screensaver-seed 4242)
         (etaf-screensaver-max-frame-rate 30)
         (buffer (etaf-screensaver-start (list :scene scene :duration 3600 :frame-rate 30)))
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

(dolist (scene '(plasma matrix life quotes tte-thunderstorm))
  (taf-benchmark-register
   (format "etaf-screensaver.frame.%s" scene)
   :version 2 :modes '(batch gui) :isolation 'series :impact 'local
   :budget-ms 100
   :description (format "Wait for the next autonomous %s frame at a 30 fps cap" scene)
   :setup (lambda (_mode) (etaf-screensaver-benchmark--fixture scene))))

(provide 'etaf-screensaver-performance-scenarios)
;;; performance-scenarios.el ends here
