;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-gui-scenarios.el --- Canvas and wake lifecycle acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run in an owned graphical Emacs.  Native command-loop key/mouse events
;; exercise wake routing without OS synthetic clicks or foreground activation.
;; Automatic idle activation needs a separate foreground idle/input pass.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver)
(require 'emacs-gui-verifier)

(defun etaf-screensaver-gui--action (id execute verify &optional settle-timeout)
  "Create screenshot action ID with EXECUTE and VERIFY."
  (etaf-gui-verifier-action-create
   :id id :execute execute :screenshot t :settled-p verify
   :settle-timeout (or settle-timeout 5)
   :assertions (lambda (context)
                 (list (etaf-gui-verifier-assert id (funcall verify context))))))

(defun etaf-screensaver-gui--scenario ()
  "Return the presentation-only lifecycle scenario."
  (let (editor original-fullscreen)
    (etaf-gui-verifier-scenario-create
     :name "etaf-screensaver"
     :claim "Only animation is shown; input restores the editor and releases playback"
     :initialize
     (lambda (context)
       (etaf-screensaver-mode -1)
       ;; A maximized/fullscreen frame cannot follow the layout actions; the
       ;; user's init may start one, so leave it normal for the run.
       (setq original-fullscreen (frame-parameter nil 'fullscreen))
       (when original-fullscreen
         (set-frame-parameter nil 'fullscreen nil))
       (setq editor (generate-new-buffer " *Screensaver GUI editor*"))
       (with-current-buffer editor (insert "Editor restored. No wake input is replayed."))
       (switch-to-buffer editor)
       (delete-other-windows)
       (setf (etaf-gui-verifier-context-target-buffer context) editor))
     :invariants
     (lambda (context)
       (let ((buffer (etaf-gui-verifier-context-target-buffer context)))
         (append
          (list (etaf-gui-verifier-assert "target-selected" (eq (window-buffer) buffer)))
          (when (plist-get (etaf-screensaver-status) :active)
            (with-current-buffer buffer
              (list
               (etaf-gui-verifier-assert "no-mode-line" (null mode-line-format))
               (etaf-gui-verifier-assert
                "no-workspace-controls"
                (not (string-match-p "SPC\\|fps\\|参数"
                                     (buffer-substring-no-properties (point-min) (point-max))))))))
          (etaf-gui-verifier-line-height-assertions buffer))))
     :actions
     (append
      (mapcar
       (lambda (scene)
         (etaf-screensaver-gui--action
          (format "scene-%s" scene)
          (lambda (context)
            (etaf-screensaver-stop)
            (setf (etaf-gui-verifier-context-target-buffer context)
                  (etaf-screensaver-start scene)))
          (lambda (_context)
            (let ((status (etaf-screensaver-status)))
              (and (eq (plist-get status :scene) scene)
                   (>= (or (plist-get status :ticks) 0) 2))))))
       '(banner donut falling-sand life matrix plasma quotes snow starfield
                tte-beams tte-synthgrid tte-thunderstorm))
      (list
       (etaf-screensaver-gui--action
        "reel-beams-mid"
        (lambda (context)
          (etaf-screensaver-stop)
          (setf (etaf-gui-verifier-context-target-buffer context)
                (etaf-screensaver-start 'tte-beams)))
        (lambda (_context)
          (let ((status (etaf-screensaver-status)))
            (and (eq (plist-get status :scene) 'tte-beams)
                 (>= (or (plist-get status :ticks) 0) 120))))
        12)
       (etaf-screensaver-gui--action
        "reel-synthgrid-mid"
        (lambda (context)
          (etaf-screensaver-stop)
          (setf (etaf-gui-verifier-context-target-buffer context)
                (etaf-screensaver-start 'tte-synthgrid)))
        (lambda (_context)
          (let ((status (etaf-screensaver-status)))
            (and (eq (plist-get status :scene) 'tte-synthgrid)
                 (>= (or (plist-get status :ticks) 0) 80))))
        10))
      (mapcar
       (lambda (size)
         (etaf-screensaver-gui--action
          (format "layout-%dx%d" (car size) (cdr size))
          (lambda (_context) (set-frame-size (selected-frame) (car size) (cdr size)))
          (lambda (_context)
            (let ((status (etaf-screensaver-status)))
              (and (= (frame-width) (car size)) (= (frame-height) (cdr size))
                   (= (or (plist-get status :columns) 0) (1- (window-body-width)))
                   (= (or (plist-get status :rows) 0) (window-body-height)))))))
       '((130 . 46) (90 . 40) (64 . 30) (100 . 16)))
      (mapcar
       (lambda (event)
         (etaf-screensaver-gui--action
          (format "wake-%s" event)
          (lambda (context)
            (unless (plist-get (etaf-screensaver-status) :active)
              (etaf-screensaver-start 'matrix))
            (if (eq event 'key)
                (execute-kbd-macro (kbd "x"))
              (let ((position (list (selected-window) 1 '(3 . 3) 0)))
                (if (eq event 'mouse-1)
                    (execute-kbd-macro (vector (list 'down-mouse-1 position)
                                              (list 'mouse-1 position)))
                  (execute-kbd-macro (vector (list event position))))))
            (setf (etaf-gui-verifier-context-target-buffer context) editor))
          (lambda (_context)
            (and (not (plist-get (etaf-screensaver-status) :active))
                 (eq (window-buffer) editor)
                 (with-current-buffer editor
                   (equal (buffer-substring-no-properties (point-min) (point-max))
                          "Editor restored. No wake input is replayed."))))))
       '(key mouse-movement mouse-1 wheel-down)))
     :completion (lambda (_context)
                   (when original-fullscreen
                     (set-frame-parameter nil 'fullscreen original-fullscreen))
                   (and (not (plist-get (etaf-screensaver-status) :active))
                        (eq (window-buffer) editor))))))

(defun etaf-screensaver-gui-run (directory)
  "Run the maintained GUI scenario into fresh evidence DIRECTORY."
  (unwind-protect
      (etaf-gui-verifier-run (etaf-screensaver-gui--scenario) directory)
    (etaf-screensaver-mode -1)))

(provide 'etaf-screensaver-gui-scenarios)
;;; etaf-screensaver-gui-scenarios.el ends here
