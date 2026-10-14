;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Screensaver frame publication workloads

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run through the workspace scripts/performance.py driver.  Each workload
;; steps a paused, seeded scene through its public API and checks the published
;; HUD.  This measures frame computation and publication, not timer cadence.

;;; Code:
(require 'etaf-screensaver)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-screensaver-benchmark--fixture (scene)
  "Return a seeded frame-publication fixture for SCENE."
  (let* ((name (generate-new-buffer-name " *Screensaver benchmark*"))
         (buffer (etaf-screensaver-open scene name))
         (ticks 0))
    (etaf-screensaver-pause name)
    (etaf-screensaver-set-seed 4242 name)
    (list
     :buffer buffer
     :invoke (lambda (_index)
               (etaf-screensaver-step name)
               (cl-incf ticks))
     :verify (lambda ()
               (let ((status (etaf-screensaver-status name))
                     (text (with-current-buffer buffer
                             (buffer-substring-no-properties (point-min) (point-max)))))
                 (if (and (eq (plist-get status :scene) scene)
                          (eq (plist-get status :status) 'paused)
                          (= (plist-get status :ticks) ticks)
                          (not (plist-get status :notice))
                          (string-match-p "已暂停" text))
                     t
                   "Scene did not publish a paused frame without an error")))
     :cleanup (lambda ()
                (when (buffer-live-p buffer)
                  (etaf-screensaver-close name))))))

(dolist (scene '(plasma matrix life quotes))
  (taf-benchmark-register
   (format "etaf-screensaver.frame.%s" scene)
   :version 1 :modes '(batch gui) :isolation 'series :impact 'local
   :budget-ms 50
   :description (format "Step and publish a seeded %s scene" scene)
   :setup (lambda (_mode) (etaf-screensaver-benchmark--fixture scene))))

(provide 'etaf-screensaver-performance-scenarios)
;;; performance-scenarios.el ends here
