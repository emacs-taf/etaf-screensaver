;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-tests.el --- Public screensaver lifecycle acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Drive the public presentation API, documented configuration and Emacs input.
;; Resource assertions compare Emacs's timer/process inventories, never private
;; callbacks or scene structures.  Actual idle activation is covered in the GUI.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-screensaver)

(defun etaf-screensaver-tests--text (buffer)
  "Read BUFFER without display properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro etaf-screensaver-tests--clean (&rest body)
  "Run BODY with isolated configuration and unconditional presentation cleanup."
  (declare (indent 0))
  `(let ((etaf-screensaver-seed 4242)
         (etaf-screensaver-scene-options nil)
         (etaf-screensaver-scene-duration 30)
         (etaf-screensaver-max-frame-rate 60)
         (etaf-screensaver-idle-delay 300))
     (etaf-screensaver-mode -1)
     ;; Batch Emacs initially reports a body overlapping its menu-bar row;
     ;; even a bare save/restore normalizes it.  Snapshot a settled layout.
     (set-window-configuration (current-window-configuration))
     (unwind-protect (progn ,@body)
       (etaf-screensaver-mode -1)
       (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-tests-restores-and-releases ()
  "Repeated start/stop restores windows and releases presentation resources."
  (etaf-screensaver-tests--clean
    (let ((configuration (current-window-configuration))
          (timers (copy-sequence timer-list))
          (processes (process-list))
          (tracking track-mouse)
          (input-map overriding-terminal-local-map))
      (dotimes (_ 3)
        (let* ((buffer (etaf-screensaver-start 'matrix))
               (again (etaf-screensaver-start 'snow))
               (status (etaf-screensaver-status)))
          (should (eq buffer again))
          (should (eq (plist-get status :scene) 'matrix))
          (should (eq (window-buffer) buffer))
          (should (etaf-runtime-for-buffer buffer))
          (etaf-screensaver-stop)
          (etaf-screensaver-stop)
          (should-not (buffer-live-p buffer))))
      (let ((restored (window-configuration-equal-p configuration (current-window-configuration)))
            (new-timers (cl-set-difference timer-list timers))
            (new-processes (cl-set-difference (process-list) processes)))
        (should restored)
        (should-not new-timers)
        (should-not new-processes)
        (should (eq track-mouse tracking))
        (should (eq overriding-terminal-local-map input-map))))))

(ert-deftest etaf-screensaver-tests-key-wakes-without-editing ()
  "The first key restores the original buffer without inserting the key."
  (etaf-screensaver-tests--clean
    (save-window-excursion
      (with-temp-buffer
        (insert "Original content")
        (switch-to-buffer (current-buffer))
        (let ((original (current-buffer)) (position (point)))
          (dolist (key '("x" "C-x" "C-g" "<f5>"))
            (etaf-screensaver-start 'donut)
            (execute-kbd-macro (kbd key))
            (let ((active (plist-get (etaf-screensaver-status) :active))
                  (text (etaf-screensaver-tests--text original)))
              (should-not active)
              (should (eq (window-buffer) original))
              (should (= (point) position))
              (should (equal text "Original content")))))))))

(ert-deftest etaf-screensaver-tests-pointer-wakes ()
  "Motion, click and wheel input dismiss instead of interacting with a scene."
  (etaf-screensaver-tests--clean
    (dolist (kind '(mouse-movement mouse-1 wheel-down))
      (etaf-screensaver-start 'falling-sand)
      (let ((position (list (selected-window) 1 '(3 . 3) 0)))
        (if (eq kind 'mouse-1)
            (execute-kbd-macro (vector (list 'down-mouse-1 position)
                                      (list 'mouse-1 position)))
          (execute-kbd-macro (vector (list kind position)))))
      (let ((active (plist-get (etaf-screensaver-status) :active)))
        (should-not active)))))

(ert-deftest etaf-screensaver-tests-mode-is-idempotent ()
  "Automatic mode owns only one watcher, then releases it when disabled."
  (etaf-screensaver-tests--clean
    (let ((before (copy-sequence timer-idle-list)))
      (etaf-screensaver-mode 1)
      (etaf-screensaver-mode 1)
      (let ((count (length (cl-set-difference timer-idle-list before))))
        (should (= count 1)))
      (etaf-screensaver-start 'snow)
      (let ((count (length (cl-set-difference timer-idle-list before))))
        (should (zerop count)))
      (etaf-screensaver-mode -1)
      (let ((status (etaf-screensaver-status))
            (remaining (cl-set-difference timer-idle-list before)))
        (should-not (plist-get status :active))
        (should-not (plist-get status :automatic))
        (should-not remaining)))))

(ert-deftest etaf-screensaver-tests-program-order-and-options ()
  "Nested groups preserve sequences and merge Lisp configuration by key."
  (etaf-screensaver-tests--clean
    (let ((etaf-screensaver-scene-options '((matrix :duration 12 :params ((speed . 2)))))
          (etaf-screensaver-max-frame-rate 10))
      (etaf-screensaver-start
       '(:order sequential :scenes
         ((:order sequential :scenes ((:scene matrix :params ((speed . 3))) snow))
          (:order sequential :scenes (donut plasma)))))
      (let ((status (etaf-screensaver-status)))
        (should (eq (plist-get status :scene) 'matrix))
        (should (equal (plist-get status :up-next) '(snow donut plasma)))
        (should (= (cdr (assq 'speed (plist-get status :params))) 3))
        (should (= (plist-get status :frame-rate) 10))))))

(ert-deftest etaf-screensaver-tests-shuffle-and-random ()
  "Shuffled bags cover each scene; random groups honor count and seed."
  (etaf-screensaver-tests--clean
    (let ((program '(:order shuffle :scenes (matrix snow donut plasma))) first)
      (dotimes (round 2)
        (etaf-screensaver-start program)
        (let* ((status (etaf-screensaver-status))
               (order (cons (plist-get status :scene) (plist-get status :up-next))))
          (should (equal (sort (copy-sequence order) #'string-lessp) '(donut matrix plasma snow)))
          (if (zerop round) (setq first order) (should (equal first order))))
        (etaf-screensaver-stop)))
    (etaf-screensaver-start '(:order random :count 12 :scenes (snow matrix)))
    (let* ((status (etaf-screensaver-status))
           (order (cons (plist-get status :scene) (plist-get status :up-next))))
      (should (= (length order) 12))
      (should (cl-every (lambda (scene) (memq scene '(snow matrix))) order)))))

(ert-deftest etaf-screensaver-tests-timed-cycle ()
  "A running presentation advances scenes and repeats its program."
  (etaf-screensaver-tests--clean
    (let ((etaf-screensaver-scene-duration 0.06))
      (etaf-screensaver-start '(:order sequential :scenes (matrix snow)))
      (let ((deadline (+ (float-time) 2)))
        (while (and (< (float-time) deadline)
                    (< (or (plist-get (etaf-screensaver-status) :index) 0) 2))
          (sleep-for 0.01)))
      (let ((status (etaf-screensaver-status)))
        (should (plist-get status :active))
        (should (>= (plist-get status :index) 2))
        (should (eq (plist-get status :scene) 'matrix))))))

(ert-deftest etaf-screensaver-tests-unicode-and-seeded-particles ()
  "Canvas publication preserves Unicode and seeded particle initialization."
  (etaf-screensaver-tests--clean
    (etaf-screensaver-register-scene
     '(:id test-unicode :layers ((:kind text :lines "A 中 B ▓ ○ 🚀 Z" :scroll nil
                                 :color "#66CCAA"))))
    (let* ((buffer (etaf-screensaver-start 'test-unicode))
           (text (etaf-screensaver-tests--text buffer))
           (position (string-match (regexp-quote "A 中 B ▓ ○ 🚀 Z") text)))
      (should position)
      (should-not (string-match-p "SPC\|fps\|参数" text))
      (with-current-buffer buffer
        (let ((face (get-text-property (+ (point-min) position) 'face)))
          (should (cl-some (lambda (spec)
                             (and (listp spec) (equal (plist-get spec :foreground) "#66CCAA")))
                           face)))))
    (etaf-screensaver-stop)
    (let (first)
      (dotimes (round 2)
        (let* ((buffer (etaf-screensaver-start 'snow))
               (digest (secure-hash 'sha256 (etaf-screensaver-tests--text buffer))))
          (if (zerop round) (setq first digest) (should (equal first digest))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-tests-bundled-scenes-run ()
  "All bundled scenes publish autonomous frames without a control surface."
  (etaf-screensaver-tests--clean
    (dolist (scene '(banner donut falling-sand life matrix plasma quotes snow starfield))
      (ert-info ((format "Scene: %s" scene))
        (let ((buffer (etaf-screensaver-start scene)))
          (let ((deadline (+ (float-time) 1)))
            (while (and (< (float-time) deadline)
                        (zerop (or (plist-get (etaf-screensaver-status) :ticks) 0)))
              (sleep-for 0.01)))
          (let ((status (etaf-screensaver-status))
                (text (etaf-screensaver-tests--text buffer)))
            (should (eq (plist-get status :scene) scene))
            (should (> (plist-get status :ticks) 0))
            (should-not (string-match-p "SPC\|fps\|参数" text)))
          (etaf-screensaver-stop))))))

(ert-deftest etaf-screensaver-tests-invalid-start-rolls-back ()
  "Invalid configuration or a scene error leaves no takeover or resources."
  (etaf-screensaver-tests--clean
    (let ((configuration (current-window-configuration))
          (buffers (buffer-list))
          (timers (copy-sequence timer-list)))
      (dolist (program '(5 missing-scene (:order shuffle :scenes 7)
                        (:order unknown :scenes (matrix))
                        (:order shuffle :scenes ()) (:scene matrix :duration -1)
                        (:scene matrix :params ((missing . 5)))))
        (should-error (etaf-screensaver-start program) :type 'etaf-screensaver-error))
      (etaf-screensaver-define-scene test-broken
        :create (lambda (_context) nil)
        :step (lambda (_state _context) nil)
        :render (lambda (_state _context) (error "Scene render failed")))
      (should-error (etaf-screensaver-start 'test-broken))
      (let ((status (etaf-screensaver-status))
            (restored (window-configuration-equal-p configuration (current-window-configuration)))
            (new-buffers (cl-set-difference (buffer-list) buffers))
            (new-timers (cl-set-difference timer-list timers)))
        (should-not (plist-get status :active))
        (should restored)
        (should-not new-buffers)
        (should-not new-timers)))))

(ert-deftest etaf-screensaver-tests-external-buffer-kill-cleans-up ()
  "External buffer death also releases playback and restores the editor."
  (etaf-screensaver-tests--clean
    (let* ((configuration (current-window-configuration))
           (timers (copy-sequence timer-list))
           (buffer (etaf-screensaver-start 'matrix)))
      (kill-buffer buffer)
      (let ((status (etaf-screensaver-status))
            (restored (window-configuration-equal-p configuration (current-window-configuration)))
            (remaining (cl-set-difference timer-list timers)))
        (should-not (plist-get status :active))
        (should restored)
        (should-not remaining)))))

(ert-deftest etaf-screensaver-tests-loader-and-catalog ()
  "Data files override registrations and report malformed files independently."
  (let ((directory (make-temp-file "screensaver-scenes-" t)))
    (unwind-protect
        (progn
          (dolist (id '(banner donut falling-sand life matrix plasma quotes snow starfield))
            (should (memq id (etaf-screensaver-scenes))))
          (with-temp-file (expand-file-name "one.esc" directory)
            (insert "(etaf-scene :id test-file :title \"First\" :layers ((:kind field :value 0 :ramp \"Q\")))"))
          (let ((count (etaf-screensaver-load-scenes (list directory)))) (should (= count 1)))
          (with-temp-file (expand-file-name "one.esc" directory)
            (insert "(etaf-scene :id test-file :title \"Changed\" :layers ((:kind field :value 0 :ramp \"R\")))"))
          (with-temp-file (expand-file-name "broken.esc" directory)
            (insert "(etaf-scene :id test-bad :layers ((:kind unsupported)))"))
          (let ((count (etaf-screensaver-load-scenes (list directory)))
                (title nil))
            (setq title (plist-get (etaf-screensaver-scene-info 'test-file) :title))
            (should (= count 1))
            (should (equal title "Changed"))))
      (delete-directory directory t))))

(provide 'etaf-screensaver-tests)
;;; etaf-screensaver-tests.el ends here
