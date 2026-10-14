;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-reel-tests.el --- Recording adapter acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Drive the public reel provider, registration, playback and import APIs.
;; Provider data uses temporary files so no network or external tool runs.
;; The bundled recordings under lisp/reels were produced once with Terminal
;; Text Effects 0.15.0 (commit 6dbc34a0) from the text "ETAF" on an 80x24
;; canvas at 20 fps; tests/fixtures/tte/bad-row.tterec is a hand-built
;; recording whose first row is two cells wide instead of three.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-screensaver)

(defconst etaf-screensaver-reel-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file and its fixtures.")

(defun etaf-screensaver-reel-tests--fixture (name)
  "Return the path of fixture NAME under tests/fixtures/tte."
  (expand-file-name (format "fixtures/tte/%s" name)
                    etaf-screensaver-reel-tests--directory))

(defun etaf-screensaver-reel-tests--bundled (name)
  "Return the path of the bundled recording NAME under lisp/reels."
  (expand-file-name (format "reels/%s" name)
                    (file-name-directory (locate-library "etaf-screensaver-loader"))))

(defmacro etaf-screensaver-reel-tests--clean (&rest body)
  "Run BODY with isolated configuration and guaranteed presentation cleanup."
  (declare (indent 0))
  `(let ((etaf-screensaver-seed 4242)
         (etaf-screensaver-scene-options nil)
         (etaf-screensaver-scene-duration 30)
         (etaf-screensaver-max-frame-rate 60)
         (etaf-screensaver-idle-delay 300))
     (etaf-screensaver-mode -1)
     (set-window-configuration (current-window-configuration))
     (unwind-protect (progn ,@body)
       (etaf-screensaver-mode -1)
       (etaf-screensaver-stop))))

(defun etaf-screensaver-reel-tests--text (buffer)
  "Read BUFFER without display properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-screensaver-reel-tests--provider (id frames width height
                                                 &optional durations ansi)
  "Register test provider ID serving FRAMES of WIDTH by HEIGHT."
  (etaf-screensaver-define-reel-provider
   id
   :title "Reel test provider"
   :license "Test license"
   :extensions '("testreel")
   :match (lambda (file) (string-suffix-p ".testreel" file))
   :read (lambda (_file)
           (list :width width :height height :frame-rate 20 :ansi ansi
                 :durations durations :frames frames :source "test"))))

(defun etaf-screensaver-reel-tests--file ()
  "Create the placeholder recording file reused by fake providers."
  (make-temp-file "reel-test" nil ".testreel"))

(ert-deftest etaf-screensaver-reel-tests-playback-follows-recording ()
  "Registered reels play their frames in recording order and loop."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (etaf-screensaver-reel-tests--provider
       'reel-test-pulse (vector "AAAA\nAAAA" "BBBB\nBBBB") 4 2 [0.6 0.6])
      (etaf-screensaver-register-reel
       (list :id 'reel-test-pulse-reel :provider 'reel-test-pulse
             :recording file :title "Pulse" :frame-rate 20))
      (let ((info (etaf-screensaver-scene-info 'reel-test-pulse-reel)))
        (should (equal (plist-get info :title) "Pulse"))
        (should (= (plist-get info :frame-rate) 20))
        (should (memq 'reel (plist-get info :tags)))
        (should (memq 'reel-test-pulse (plist-get info :tags))))
      (let ((buffer (etaf-screensaver-start 'reel-test-pulse-reel))
            (deadline (+ (float-time) 3)))
        (should (string-match-p "AAAA" (etaf-screensaver-reel-tests--text buffer)))
        (while (and (< (float-time) deadline)
                    (not (string-match-p "BBBB" (etaf-screensaver-reel-tests--text buffer))))
          (sleep-for 0.02))
        (should (string-match-p "BBBB" (etaf-screensaver-reel-tests--text buffer)))
        (setq deadline (+ (float-time) 3))
        (while (and (< (float-time) deadline)
                    (not (string-match-p "AAAA" (etaf-screensaver-reel-tests--text buffer))))
          (sleep-for 0.02))
        (should (string-match-p "AAAA" (etaf-screensaver-reel-tests--text buffer)))
        (etaf-screensaver-stop)
        (should-not (plist-get (etaf-screensaver-status) :active))))))

(ert-deftest etaf-screensaver-reel-tests-wide-ansi-frames-keep-colors ()
  "ANSI frames with wide characters publish centered colored cells."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (etaf-screensaver-reel-tests--provider
       'reel-test-unicode (vector "\e[31m中文\e[0mA B") 7 1 nil t)
      (etaf-screensaver-register-reel
       (list :id 'reel-test-unicode-reel :provider 'reel-test-unicode
             :recording file :title "Unicode" :frame-rate 20))
      (let* ((buffer (etaf-screensaver-start 'reel-test-unicode-reel))
             (status (etaf-screensaver-status))
             (text (etaf-screensaver-reel-tests--text buffer))
             (position (string-match "中文A B" text)))
        (should position)
        (with-current-buffer buffer
          (let ((face (get-text-property (+ (point-min) position) 'face)))
            (should (cl-some (lambda (spec)
                               (and (listp spec) (equal (plist-get spec :foreground) "#cd0000")))
                             face))))
        (dolist (row (split-string text "\n"))
          (unless (equal row "")
            (should (= (string-width row) (plist-get status :columns)))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-reel-tests-imports-a-recording ()
  "Importing a recording copies it, writes a reel spec and plays it."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "reel-import-" t))
           (source (expand-file-name "thunderstorm.tterec" directory))
           (target (expand-file-name "imported" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--bundled "thunderstorm.tterec")
                       source)
            (let ((report (etaf-screensaver-import-recording source target)))
              (should (eq (plist-get report :status) 'imported))
              (should (eq (plist-get report :provider) 'tte))
              (should (= (plist-get report :width) 80))
              (should (= (plist-get report :height) 24))
              (should (= (plist-get report :frame-rate) 20))
              (should (= (plist-get report :frame-count) 480))
              (should (equal (plist-get report :license) "MIT"))
              (should (memq 'truecolor (plist-get report :colors)))
              (should (file-regular-p (plist-get report :output)))
              (should (file-regular-p (plist-get report :recording))))
            (should (= (etaf-screensaver-load-scenes (list target)) 1))
            (let ((info (etaf-screensaver-scene-info 'tte-thunderstorm)))
              (should (equal (plist-get info :title) "Terminal Text Effects: thunderstorm"))
              (should (= (plist-get info :frame-rate) 20)))
            (let ((buffer (etaf-screensaver-start 'tte-thunderstorm)))
              (should (string-match-p "ETAF" (etaf-screensaver-reel-tests--text buffer)))
              (etaf-screensaver-stop)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-batch-report-classifies-files ()
  "A batch import separates compatible, unrecognized and invalid files."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "reel-batch-" t))
           (target (expand-file-name "imported" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--bundled "beams.tterec")
                       (expand-file-name "good.tterec" directory))
            (with-temp-file (expand-file-name "notes.txt" directory)
              (insert "not a recording"))
            (let ((data (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally
                           (etaf-screensaver-reel-tests--bundled "beams.tterec"))
                          (buffer-substring-no-properties (point-min) (point-max)))))
              (with-temp-file (expand-file-name "wrong.tterec" directory)
                (set-buffer-multibyte nil)
                (insert "X" (substring data 1)))
              (with-temp-file (expand-file-name "cut.tterec" directory)
                (set-buffer-multibyte nil)
                (insert (substring data 0 (/ (length data) 2)))))
            (let ((report (etaf-screensaver-import-directory directory target)))
              (should (= (length (plist-get report :imported)) 1))
              (should (= (length (plist-get report :skipped)) 1))
              (should (= (length (plist-get report :failed)) 1))
              (let ((imported (car (plist-get report :imported)))
                    (skipped (car (plist-get report :skipped)))
                    (failed (car (plist-get report :failed))))
                (should (= (plist-get imported :frame-count) 322))
                (should (equal (file-name-nondirectory (plist-get imported :file)) "good.tterec"))
                (should (eq (plist-get skipped :status) 'skipped))
                (should (equal (file-name-nondirectory (plist-get skipped :file)) "wrong.tterec"))
                (should (eq (plist-get failed :status) 'failed))
                (should (equal (file-name-nondirectory (plist-get failed :file)) "cut.tterec"))
                (should (stringp (plist-get failed :reason)))))
            (should (= (etaf-screensaver-load-scenes (list target)) 1))
            (should (memq 'tte-beams (etaf-screensaver-scenes))))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-rejects-invalid-recordings ()
  "Invalid recordings signal etaf-screensaver-error and write nothing."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "reel-invalid-" t))
           (target (expand-file-name "imported" directory))
           (data (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally
                    (etaf-screensaver-reel-tests--bundled "beams.tterec"))
                   (buffer-substring-no-properties (point-min) (point-max)))))
      (unwind-protect
          (progn
            (let ((versioned (expand-file-name "version.tterec" directory)))
              (with-temp-file versioned
                (set-buffer-multibyte nil)
                (insert (substring data 0 6) "\x02" (substring data 7)))
              (let ((error (should-error (etaf-screensaver-import-recording versioned target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "version" (car (cdr error))))))
            (let ((truncated (expand-file-name "truncated.tterec" directory)))
              (with-temp-file truncated
                (set-buffer-multibyte nil)
                (insert (substring data 0 (/ (length data) 2))))
              (let ((error (should-error (etaf-screensaver-import-recording truncated target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "damaged\\|truncated\\|compressed"
                                        (car (cdr error))))))
            (let ((error (should-error (etaf-screensaver-import-recording
                                        (etaf-screensaver-reel-tests--fixture
                                         "bad-row.tterec")
                                        target)
                                       :type 'etaf-screensaver-error)))
              (should (string-match-p "cells wide" (car (cdr error)))))
            (should-not (file-directory-p target)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-loader-skips-broken-reels ()
  "A reel spec with a missing recording reports and skips independently."
  (etaf-screensaver-reel-tests--clean
    (let ((directory (make-temp-file "reel-loader-" t))
          (file (etaf-screensaver-reel-tests--file)))
      (unwind-protect
          (progn
            (etaf-screensaver-reel-tests--provider
             'reel-test-loader (vector "OK\nOK") 2 1)
            (etaf-screensaver-register-reel
             (list :id 'reel-test-loader-reel :provider 'reel-test-loader
                   :recording file :frame-rate 20))
            (with-temp-file (expand-file-name "missing.esr" directory)
              (prin1 (list :id 'reel-test-missing :provider 'reel-test-loader
                           :recording (expand-file-name "absent.testreel" directory)
                           :frame-rate 20)
                     (current-buffer)))
            (let ((loaded (etaf-screensaver-load-scenes (list directory))))
              (should (= loaded 0)))
            (should-not (memq 'reel-test-missing (etaf-screensaver-scenes))))
        (delete-directory directory t)))))

(provide 'etaf-screensaver-reel-tests)
;;; etaf-screensaver-reel-tests.el ends here
