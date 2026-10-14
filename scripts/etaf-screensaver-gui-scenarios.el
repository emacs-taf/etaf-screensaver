;;; etaf-screensaver-gui-scenarios.el --- Workspace GUI acceptance -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One ordered scenario for the maintained workspace.  It opens the real
;; workspace in a graphical frame, drives the documented keys through the
;; command loop, settles on visible text and leaves every screenshot in the
;; verifier's evidence directory.  Mouse painting is exercised separately
;; because OS-level synthetic clicks do not reach Emacs text areas.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-screensaver)
(require 'emacs-gui-verifier)

(defun etaf-screensaver-gui--runtime (context)
  "Return CONTEXT's mounted runtime."
  (etaf-runtime-for-buffer (etaf-gui-verifier-context-target-buffer context)))

(defun etaf-screensaver-gui--text (context)
  "Return CONTEXT's published text."
  (with-current-buffer (etaf-gui-verifier-context-target-buffer context)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-screensaver-gui--action (id execute verify &optional timeout)
  "Create an ordered screenshot action ID with EXECUTE and VERIFY."
  (etaf-gui-verifier-action-create
   :id id :execute execute :screenshot t
   :settled-p verify
   :settle-timeout (or timeout 5)
   :assertions (lambda (context)
                 (list (etaf-gui-verifier-assert id (funcall verify context))))))

(defun etaf-screensaver-gui--invariants (context)
  "Return CONTEXT's mounted and row-height assertions."
  (append
   (list (etaf-gui-verifier-assert "workspace-mounted"
                                   (etaf-screensaver-gui--runtime context))
         (etaf-gui-verifier-assert
          "target-selected"
          (eq (window-buffer (selected-window))
              (etaf-gui-verifier-context-target-buffer context)))
         (etaf-gui-verifier-assert
          "no-render-error"
          (not (string-match-p "runtime error\\|Wrong type argument\\|could not render"
                               (etaf-screensaver-gui--text context)))))
   (etaf-gui-verifier-line-height-assertions
    (etaf-gui-verifier-context-target-buffer context))))

(defun etaf-screensaver-gui--resize (width height)
  "Resize the selected frame to WIDTH by HEIGHT."
  (set-frame-parameter (selected-frame) 'fullscreen nil)
  (set-frame-size (selected-frame) width height))

(defun etaf-screensaver-gui--layout (width height)
  "Create a layout action for WIDTH and HEIGHT."
  (etaf-screensaver-gui--action
   (format "layout-%dx%d" width height)
   (lambda (_context) (etaf-screensaver-gui--resize width height))
   (lambda (_context) (and (= (frame-width) width) (= (frame-height) height)))))

(defun etaf-screensaver-gui--scenario ()
  "Return the maintained workspace scenario."
  (etaf-gui-verifier-scenario-create
   :name "etaf-screensaver"
   :claim "A data scene plays, steps, takes parameters, switches, reloads and follows layouts in the GUI"
   :initialize
   (lambda (context)
     (let ((buffer (get-buffer-create "*ETAF 屏保 GUI 验收*")))
       (setf (etaf-gui-verifier-context-target-buffer context) buffer)
       (etaf-screensaver-open 'falling-sand (buffer-name buffer))
       (switch-to-buffer buffer)
       (delete-other-windows)
       (etaf-refit (etaf-screensaver-gui--runtime context) (selected-window))))
   :invariants #'etaf-screensaver-gui--invariants
   :adapter (lambda (context)
              (list (cons 'title (string-trim (etaf-screensaver-gui--text context)))
                    (cons 'frame_width (frame-width))
                    (cons 'frame_height (frame-height))))
   :actions
   (append
    (list
     (etaf-screensaver-gui--action
      "initial-frame" #'ignore
      (lambda (context)
        (and (string-match-p "落沙" (etaf-screensaver-gui--text context))
             (string-match-p "SPC 播放/暂停" (etaf-screensaver-gui--text context)))))
     (etaf-screensaver-gui--action
      "key-step-pauses" (lambda (_context) (execute-kbd-macro (kbd "n")))
      (lambda (context)
        (string-match-p "已暂停" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-toggle-resumes" (lambda (_context) (execute-kbd-macro (kbd "SPC")))
      (lambda (context)
        (string-match-p "运行中" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-params-open" (lambda (_context) (execute-kbd-macro (kbd "TAB")))
      (lambda (context)
        (string-match-p "自动下沙" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-params-close" (lambda (_context) (execute-kbd-macro (kbd "TAB")))
      (lambda (context)
        (not (string-match-p "自动下沙" (etaf-screensaver-gui--text context)))))
     (etaf-screensaver-gui--action
      "key-next-scene" (lambda (_context) (execute-kbd-macro (kbd "s")))
      (lambda (context)
        (string-match-p "生命游戏" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-previous-scene" (lambda (_context) (execute-kbd-macro (kbd "S")))
      (lambda (context)
        (string-match-p "落沙" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-speed-up" (lambda (_context) (execute-kbd-macro (kbd "+")))
      (lambda (context)
        (string-match-p "30 fps" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-speed-down" (lambda (_context) (execute-kbd-macro (kbd "-")))
      (lambda (context)
        (string-match-p "20 fps" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-cinema-hides-chrome" (lambda (_context) (execute-kbd-macro (kbd "c")))
      (lambda (context)
        (not (string-match-p "SPC 播放/暂停" (etaf-screensaver-gui--text context)))))
     (etaf-screensaver-gui--action
      "key-cinema-restores-chrome" (lambda (_context) (execute-kbd-macro (kbd "c")))
      (lambda (context)
        (string-match-p "SPC 播放/暂停" (etaf-screensaver-gui--text context))))
     (etaf-screensaver-gui--action
      "key-reload-keeps-the-scene" (lambda (_context) (execute-kbd-macro (kbd "l")))
      (lambda (context)
        (string-match-p "落沙" (etaf-screensaver-gui--text context)))))
    (mapcar (lambda (size) (etaf-screensaver-gui--layout (car size) (cdr size)))
            '((130 . 46) (90 . 40) (64 . 30)))
    (list
     (etaf-screensaver-gui--action
      "short-window-keeps-the-hud"
      (lambda (_context) (etaf-screensaver-gui--resize 100 16))
      (lambda (context)
        (and (string-match-p "落沙" (etaf-screensaver-gui--text context))
             (string-match-p "SPC 播放/暂停" (etaf-screensaver-gui--text context)))))
     (etaf-screensaver-gui--layout 110 42)
     (etaf-screensaver-gui--action
      "reopen-starts-clean"
      (lambda (context)
        (etaf-screensaver-open
         'plasma (buffer-name (etaf-gui-verifier-context-target-buffer context))))
      (lambda (context)
        (and (string-match-p "等离子" (etaf-screensaver-gui--text context))
             (string-match-p "运行中" (etaf-screensaver-gui--text context)))))))
   :completion (lambda (context)
                 (and (etaf-screensaver-gui--runtime context)
                      (string-match-p "等离子" (etaf-screensaver-gui--text context))))))

(defun etaf-screensaver-gui-run (directory)
  "Run the maintained scenario into fresh evidence DIRECTORY."
  (etaf-gui-verifier-run (etaf-screensaver-gui--scenario) directory))

(provide 'etaf-screensaver-gui-scenarios)
;;; etaf-screensaver-gui-scenarios.el ends here
