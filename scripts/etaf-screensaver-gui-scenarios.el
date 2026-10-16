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

(defun etaf-screensaver-gui--presentations ()
  "Return the real-content viewport matrix and image composition checks."
  (append
   (cl-loop for size in '((130 . 46) (90 . 40) (64 . 30) (100 . 16))
            append
            (cl-loop for style in '(full card band mosaic)
                     collect
                     (let ((size size) (style style))
                       (etaf-screensaver-gui--action
                        (format "%s-%dx%d" style (car size) (cdr size))
                        (lambda (context)
                          (etaf-screensaver-stop)
                          (set-frame-size (selected-frame) (car size) (cdr size))
                          (setf (etaf-gui-verifier-context-target-buffer context)
                                (etaf-screensaver-start
                                 (if (eq style 'mosaic)
                                     '(:pack neon :presentation mosaic :duration 60)
                                   (list :scene (if (eq style 'card) 'tte-ink-waves 'tte-thunderstorm)
                                         :presentation style :duration 60)))))
                        (lambda (_context)
                          (let ((status (etaf-screensaver-status)))
                            (and (eq (plist-get status :presentation) style)
                                 (= (frame-width) (car size)) (= (frame-height) (cdr size))
                                 (>= (or (plist-get status :ticks) 0) 5)
                                 (= (or (plist-get status :columns) 0) (1- (window-body-width)))
                                 (= (or (plist-get status :rows) 0) (window-body-height)))))))))
   (mapcar
    (lambda (style)
      (etaf-screensaver-gui--action
       (format "image-%s" style)
       (lambda (context)
         (etaf-screensaver-stop)
         (set-frame-size (selected-frame) 90 40)
         (setf (etaf-gui-verifier-context-target-buffer context)
               (etaf-screensaver-start
                (list :presentation style :scenes
                      '(frames-sample tte-ink-waves tte-synthgrid starfield)))))
       (lambda (_context)
         (let ((status (etaf-screensaver-status)))
           (and (eq (plist-get status :presentation) style)
                (>= (or (plist-get status :ticks) 0) 3))))))
    '(full card band mosaic))
   (list
    (etaf-screensaver-gui--action
     "cross-style-round"
     (lambda (context)
       (etaf-screensaver-stop)
       (setf (etaf-gui-verifier-context-target-buffer context)
             (etaf-screensaver-start
              '(:scenes ((:scene tte-ink-waves :presentation card :duration 0.3)
                         (:scene starfield :presentation band :duration 0.3)
                         (:presentation mosaic :scenes
                          ((:scene tte-beams :duration 0.3)
                           (:scene tte-synthgrid :duration 0.3)
                           (:scene tte-bubbles :duration 0.3)
                           (:scene tte-thunderstorm :duration 0.3))))))))
     (lambda (_context)
       (>= (or (plist-get (etaf-screensaver-status) :index) 0) 6)) 12)
    (etaf-screensaver-gui--action
     "natural-recording-round"
     (lambda (context)
       (etaf-screensaver-stop)
       (setf (etaf-gui-verifier-context-target-buffer context)
             (etaf-screensaver-start
              '(:scenes ((:scene tte-beams :presentation full)
                         (:scene tte-ink-waves :presentation card))))))
     (lambda (_context)
       (let ((status (etaf-screensaver-status)))
         (unless (plist-get status :active)
           (error "Natural recording presentation ended before completing its round (focus %s, pending input %s)"
                  (frame-focus-state) (input-pending-p)))
         (>= (or (plist-get status :index) 0) 2))) 120))))

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
      (list
       (etaf-screensaver-gui--action
        "focus-recheck"
        (lambda (context)
          (setf (etaf-gui-verifier-context-target-buffer context)
                (etaf-screensaver-start 'matrix))
          ;; The notification is global: a recheck without a focus transition
          ;; must leave a manual preview alive, even in a background frame.
          (funcall after-focus-change-function))
        (lambda (_context)
          (let ((status (etaf-screensaver-status)))
            (and (plist-get status :active)
                 (>= (or (plist-get status :ticks) 0) 2))))))
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
        10)
       (etaf-screensaver-gui--action
        "scene-frames-fixture"
        (lambda (context)
          (etaf-screensaver-stop)
          (let* ((library (file-name-directory (locate-library "etaf-screensaver-loader")))
                 (fixture (expand-file-name "../tests/fixtures/frames/sample.frames.json" library)))
            (etaf-screensaver-register-reel
             (list :id 'frames-sample :provider 'frames :recording fixture :title "Image fixture"))
            (setf (etaf-gui-verifier-context-target-buffer context)
                  (etaf-screensaver-start 'frames-sample))))
        (lambda (_context)
          (let ((status (etaf-screensaver-status)))
            (and (eq (plist-get status :scene) 'frames-sample)
                 (>= (or (plist-get status :ticks) 0) 2))))))
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
      (etaf-screensaver-gui--presentations)
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

(defun etaf-screensaver-gui-run-gallery (directory gallery-file)
  "Review the installed GALLERY-FILE through public playback in DIRECTORY.
Run only in an owned GUI.  Captures cover every work and four layouts at
four viewport sizes; visual inspection remains a separate requirement."
  (load (expand-file-name gallery-file) nil t)
  (let* ((packs (cl-remove-if-not
                 (lambda (pack) (string-prefix-p "gallery-" (symbol-name (car pack))))
                 etaf-screensaver-packs))
         (works (apply #'append (mapcar (lambda (pack) (plist-get (cdr pack) :scenes)) packs)))
         (page '(frames-cloud-atlas frames-orbital-mobile frames-royal-flow frames-living-cells))
         (editor (generate-new-buffer " *Gallery review editor*")))
    (unless works (error "The installed gallery has no works"))
    (unwind-protect
        (etaf-gui-verifier-run
         (etaf-gui-verifier-scenario-create
          :name "etaf-screensaver-gallery"
          :claim "Installed artwork moves in every layout and releases playback on input"
          :initialize
          (lambda (context)
            (etaf-screensaver-mode -1)
            (switch-to-buffer editor) (delete-other-windows)
            (set-frame-size nil 130 46)
            (setf (etaf-gui-verifier-context-target-buffer context) editor))
          :invariants
          (lambda (context)
            (let ((buffer (etaf-gui-verifier-context-target-buffer context)))
              (append (list (etaf-gui-verifier-assert "target-selected" (eq (window-buffer) buffer)))
                      (etaf-gui-verifier-line-height-assertions buffer))))
          :actions
          (append
           (mapcar
            (lambda (scene)
              (etaf-screensaver-gui--action
               (symbol-name scene)
               (lambda (context)
                 (etaf-screensaver-stop)
                 (setf (etaf-gui-verifier-context-target-buffer context)
                       (etaf-screensaver-start (list :scene scene :presentation 'full))))
               (lambda (_context)
                 (let ((status (etaf-screensaver-status)))
                   (and (eq (plist-get status :scene) scene)
                        (>= (or (plist-get status :ticks) 0) 12))))))
            works)
           (cl-loop for size in '((130 . 46) (90 . 40) (64 . 30) (100 . 16)) append
                    (cl-loop for style in '(full card band mosaic) collect
                             (let ((size size) (style style))
                               (etaf-screensaver-gui--action
                                (format "gallery-%s-%dx%d" style (car size) (cdr size))
                                (lambda (context)
                                  (etaf-screensaver-stop)
                                  (set-frame-size nil (car size) (cdr size))
                                  (setf (etaf-gui-verifier-context-target-buffer context)
                                        (etaf-screensaver-start
                                         (list :presentation style :scenes page))))
                                (lambda (_context)
                                  (let ((status (etaf-screensaver-status)))
                                    (and (eq (plist-get status :presentation) style)
                                         (= (frame-width) (car size)) (= (frame-height) (cdr size))
                                         (>= (or (plist-get status :ticks) 0) 5))))))))
           (list
            (etaf-screensaver-gui--action
             "gallery-natural-round"
             (lambda (context)
               (etaf-screensaver-stop)
               (set-frame-size nil 130 46)
               (setf (etaf-gui-verifier-context-target-buffer context)
                     (etaf-screensaver-start
                      '(:scenes ((:scene frames-porcelain-mist :presentation card)
                                 (:scene frames-royal-flow :presentation band))))))
             (lambda (_context)
               (let ((status (etaf-screensaver-status)))
                 (unless (plist-get status :active) (error "Gallery stopped before its round finished"))
                 (>= (or (plist-get status :index) 0) 2))) 65)
            (etaf-screensaver-gui--action
             "gallery-wake"
             (lambda (context)
               (execute-kbd-macro (kbd "x"))
               (setf (etaf-gui-verifier-context-target-buffer context) editor))
             (lambda (_context)
               (and (not (plist-get (etaf-screensaver-status) :active))
                    (eq (window-buffer) editor)
                    (with-current-buffer editor (zerop (buffer-size))))))))
          :completion (lambda (_context) (not (plist-get (etaf-screensaver-status) :active))))
         directory)
      (etaf-screensaver-mode -1)
      (when (buffer-live-p editor) (kill-buffer editor)))))

(provide 'etaf-screensaver-gui-scenarios)
;;; etaf-screensaver-gui-scenarios.el ends here
