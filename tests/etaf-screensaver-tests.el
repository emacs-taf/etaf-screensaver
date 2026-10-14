;;; etaf-screensaver-tests.el --- Acceptance tests for etaf-screensaver -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the workspace through the
;; interfaces declared in `etaf-screensaver.el' and asserts what a person
;; would see.  Keep internals out: no private helpers, structures or call
;; counts.  The counter below is a code scene registered through the public
;; macro; the specs registered by the tests prove that data scenes join the
;; catalog, evaluate the spec language and load from .esc files.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-screensaver)

(etaf-screensaver-define-scene test-counter
  :title "Test counter"
  :summary "Deterministic scene used by the acceptance tests."
  :frame-rate 10
  :params '((:key step :label "Step" :type number :min 1 :max 5 :step 1 :default 1)
            (:key paint :label "Paint" :type toggle :default nil))
  :create (lambda (context)
            (ignore context)
            (list :count 0 :mark nil))
  :step (lambda (state context)
          (setf (plist-get state :count)
                (+ (plist-get state :count)
                   (funcall (plist-get context :param) :step))))
  :render (lambda (state context)
            (let ((rows (plist-get context :rows))
                  (columns (plist-get context :columns)))
              (cl-loop for row below rows
                       collect (truncate-string-to-width
                                (cond ((= row 0) (format "count=%d" (plist-get state :count)))
                                      ((and (= row 1) (plist-get state :mark))
                                       (plist-get state :mark))
                                      (t ""))
                                columns nil ?\s))))
  :pointer (lambda (state context event)
             (ignore context)
             (setf (plist-get state :mark)
                   (format "paint %d,%d %s"
                           (plist-get event :row)
                           (plist-get event :column)
                           (plist-get event :phase)))
             t))

(etaf-screensaver-register-scene
 '(:id test-spec
   :title "Test spec"
   :summary "Deterministic data scene used by the acceptance tests."
   :frame-rate 10
   :params ((:key level :label "Level" :type number
             :min 0 :max 1 :step 1 :default 0))
   :layers ((:kind field
             :value (if (> x cx) (- 1 level) level)
             :ramp "XY"))))

(defun etaf-screensaver-tests--text (buffer)
  "Return BUFFER's visible text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest etaf-screensaver-tests-open-mounts-and-close-releases ()
  "Opening mounts a live runtime and closing kills its buffer."
  (let ((buffer (etaf-screensaver-open 'donut "*test-etaf-screensaver-open*")))
    (unwind-protect
        (progn
          (should (buffer-live-p buffer))
          (should (etaf-runtime-for-buffer buffer))
          (should (string-match-p "旋转甜甜圈"
                                  (etaf-screensaver-tests--text buffer)))
          (should (string-match-p "[.,-~:;=!*#$@]"
                                  (etaf-screensaver-tests--text buffer))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-open*"))))
  (should-not (get-buffer "*test-etaf-screensaver-open*")))

(ert-deftest etaf-screensaver-tests-scenes-register-and-describe ()
  "The catalog lists the built-in scenes and describes each of them."
  (dolist (id '(banner donut falling-sand life matrix plasma quotes snow starfield))
    (should (memq id (etaf-screensaver-scenes))))
  (let ((info (etaf-screensaver-scene-info 'donut)))
    (should (eq (plist-get info :id) 'donut))
    (should (equal (plist-get info :title) "旋转甜甜圈"))
    (should (stringp (plist-get info :summary)))
    (should (numberp (plist-get info :frame-rate)))
    (should (listp (plist-get info :params))))
  (should (eq 'donut (plist-get (etaf-screensaver-scene-info "旋转甜甜圈") :id)))
  (should (eq 'plasma (plist-get (etaf-screensaver-scene-info "等离子") :id)))
  (should-error (etaf-screensaver-scene-info 'no-such-scene)
                :type 'etaf-screensaver-error))

(ert-deftest etaf-screensaver-tests-step-advances-one-frame ()
  "Stepping pauses the workspace and advances exactly one frame."
  (let ((buffer (etaf-screensaver-open 'test-counter "*test-etaf-screensaver-step*")))
    (unwind-protect
        (progn
          (etaf-screensaver-step "*test-etaf-screensaver-step*")
          (should (string-match-p "count=1" (etaf-screensaver-tests--text buffer)))
          (etaf-screensaver-step "*test-etaf-screensaver-step*")
          (should (string-match-p "count=2" (etaf-screensaver-tests--text buffer)))
          (let ((status (etaf-screensaver-status "*test-etaf-screensaver-step*")))
            (should (eq (plist-get status :scene) 'test-counter))
            (should (eq (plist-get status :status) 'paused))
            (should (= 2 (plist-get status :ticks)))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-step*")))))

(ert-deftest etaf-screensaver-tests-controls-publish-status ()
  "Pause, resume, reset, seed and frame rate each publish their state."
  (let ((buffer (etaf-screensaver-open 'test-counter "*test-etaf-screensaver-controls*")))
    (unwind-protect
        (progn
          (etaf-screensaver-pause "*test-etaf-screensaver-controls*")
          (should (eq (plist-get (etaf-screensaver-status "*test-etaf-screensaver-controls*")
                                 :status)
                      'paused))
          (etaf-screensaver-resume "*test-etaf-screensaver-controls*")
          (should (eq (plist-get (etaf-screensaver-status "*test-etaf-screensaver-controls*")
                                 :status)
                      'running))
          (etaf-screensaver-set-frame-rate 30 "*test-etaf-screensaver-controls*")
          (should (= 30 (plist-get (etaf-screensaver-status "*test-etaf-screensaver-controls*")
                                   :frame-rate)))
          (etaf-screensaver-set-seed 4242 "*test-etaf-screensaver-controls*")
          (let ((status (etaf-screensaver-status "*test-etaf-screensaver-controls*")))
            (should (= 4242 (plist-get status :seed)))
            (should (zerop (plist-get status :ticks))))
          (etaf-screensaver-step "*test-etaf-screensaver-controls*")
          (etaf-screensaver-reset "*test-etaf-screensaver-controls*")
          (should (zerop (plist-get (etaf-screensaver-status "*test-etaf-screensaver-controls*")
                                    :ticks))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-controls*")))))

(ert-deftest etaf-screensaver-tests-params-drive-the-scene ()
  "A scene parameter changes what the next frame renders."
  (let ((buffer (etaf-screensaver-open 'test-counter "*test-etaf-screensaver-params*")))
    (unwind-protect
        (progn
          (etaf-screensaver-set-param :step 3 "*test-etaf-screensaver-params*")
          (etaf-screensaver-step "*test-etaf-screensaver-params*")
          (should (string-match-p "count=3" (etaf-screensaver-tests--text buffer)))
          (etaf-screensaver-set-param :step 1 "*test-etaf-screensaver-params*")
          (etaf-screensaver-step "*test-etaf-screensaver-params*")
          (should (string-match-p "count=4" (etaf-screensaver-tests--text buffer))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-params*")))))

(ert-deftest etaf-screensaver-tests-select-scene-switches-and-validates ()
  "Switching scenes updates the workspace and unknown names are rejected."
  (let ((buffer (etaf-screensaver-open 'test-counter "*test-etaf-screensaver-select*")))
    (unwind-protect
        (progn
          (etaf-screensaver-select-scene 'matrix "*test-etaf-screensaver-select*")
          (should (eq 'matrix (plist-get (etaf-screensaver-status
                                          "*test-etaf-screensaver-select*")
                                         :scene)))
          (etaf-screensaver-select-scene "数字雨" "*test-etaf-screensaver-select*")
          (should (eq 'matrix (plist-get (etaf-screensaver-status
                                          "*test-etaf-screensaver-select*")
                                         :scene)))
          (should-error (etaf-screensaver-select-scene 'no-such-scene
                                                       "*test-etaf-screensaver-select*")
                        :type 'etaf-screensaver-error)
          (etaf-screensaver-select-scene 'test-counter "*test-etaf-screensaver-select*")
          (should (string-match-p "Test counter"
                                  (etaf-screensaver-tests--text buffer))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-select*")))))

(ert-deftest etaf-screensaver-tests-spec-scene-renders-and-takes-params ()
  "A data scene evaluates its expressions and follows its parameters."
  (let ((buffer (etaf-screensaver-open 'test-spec "*test-etaf-screensaver-spec*")))
    (unwind-protect
        (progn
          (should (string-match-p "X+Y+"
                                  (etaf-screensaver-tests--text buffer)))
          (etaf-screensaver-pause "*test-etaf-screensaver-spec*")
          (etaf-screensaver-set-param :level 1 "*test-etaf-screensaver-spec*")
          (should (string-match-p "Y+X+"
                                  (etaf-screensaver-tests--text buffer)))
          (should-not (string-match-p "X+Y+"
                                      (etaf-screensaver-tests--text buffer)))
          (etaf-screensaver-set-param :level 0 "*test-etaf-screensaver-spec*")
          (should (string-match-p "X+Y+"
                                  (etaf-screensaver-tests--text buffer))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-spec*")))))

(ert-deftest etaf-screensaver-tests-unicode-scene-publishes-text ()
  "ASCII, wide text and Unicode symbols survive canvas composition."
  (let ((name "*test-etaf-screensaver-unicode*")
        (content "A 中 B ▓ ○ 🚀 Z"))
    (etaf-screensaver-register-scene
     `(:id test-unicode :title "Unicode"
       :layers ((:kind text :lines ,content :align left :scroll nil
                 :color "#66CCAA"))))
    (unwind-protect
        (let ((buffer (etaf-screensaver-open 'test-unicode name)))
          (etaf-screensaver-pause name)
          (dotimes (_ 3)
            (etaf-screensaver-step name)
            (let* ((text (etaf-screensaver-tests--text buffer))
                   (position (string-match (regexp-quote content) text))
                   (status (etaf-screensaver-status name)))
              (should position)
              (should-not (plist-get status :notice))
              (with-current-buffer buffer
                (let ((face (get-text-property (+ (point-min) position) 'face)))
                  (should (cl-some (lambda (spec)
                                     (and (listp spec)
                                          (equal (plist-get spec :foreground) "#66CCAA")))
                                   face)))))))
      (when (get-buffer name) (etaf-screensaver-close name)))))

(ert-deftest etaf-screensaver-tests-random-particles-follow-seed ()
  "Particle creation and updates use the reproducible session generator."
  (let ((name "*test-etaf-screensaver-random*"))
    (etaf-screensaver-register-scene
     '(:id test-random :title "Random particles"
       :layers ((:kind particles :count 12
                 :init ((x (rndi w)) (y (rndi h)))
                 :update ((x (rndi w)) (y (rndi h)))
                 :draw (:char "*")))))
    (unwind-protect
        (let ((buffer (etaf-screensaver-open 'test-random name)))
          (etaf-screensaver-pause name)
          (etaf-screensaver-set-seed 4242 name)
          (etaf-screensaver-step name)
          (let ((first (etaf-screensaver-tests--text buffer)))
            (etaf-screensaver-reset name)
            (etaf-screensaver-step name)
            (let ((replayed (etaf-screensaver-tests--text buffer))
                  (status (etaf-screensaver-status name)))
              (should (equal first replayed))
              (should-not (plist-get status :notice))
              (should (string-match-p "\\*" first)))))
      (when (get-buffer name) (etaf-screensaver-close name)))))

(ert-deftest etaf-screensaver-tests-bundled-scenes-publish-frames ()
  "Every bundled scene opens and advances without a canvas error."
  (dolist (scene '(banner donut falling-sand life matrix plasma quotes snow starfield))
    (ert-info ((format "Scene: %s" scene))
      (let ((name "*test-etaf-screensaver-bundled*"))
        (unwind-protect
            (let ((buffer (etaf-screensaver-open scene name)))
              (etaf-screensaver-pause name)
              (etaf-screensaver-set-seed 4242 name)
              (dotimes (_ 3) (etaf-screensaver-step name))
              (let ((status (etaf-screensaver-status name))
                    (text (etaf-screensaver-tests--text buffer)))
                (should (eq (plist-get status :scene) scene))
                (should (= (plist-get status :ticks) 3))
                (should-not (plist-get status :notice))
                (should (string-match-p "已暂停" text))))
          (when (get-buffer name) (etaf-screensaver-close name)))))))

(ert-deftest etaf-screensaver-tests-reload-rebuilds-the-mounted-scene ()
  "Reloading the scene files refreshes the mounted scene in place."
  (let ((buffer (etaf-screensaver-open 'plasma "*test-etaf-screensaver-reload*")))
    (unwind-protect
        (progn
          (should (>= (etaf-screensaver-reload-scenes) 7))
          (should (buffer-live-p buffer))
          (should (eq 'plasma (plist-get (etaf-screensaver-status
                                          "*test-etaf-screensaver-reload*")
                                         :scene))))
      (when (buffer-live-p buffer)
        (etaf-screensaver-close "*test-etaf-screensaver-reload*")))))

(ert-deftest etaf-screensaver-tests-loader-reads-and-overrides-files ()
  "Scene files load, replace by id and skip broken files."
  (let ((directory (make-temp-file "etaf-screensaver-scenes-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "one.esc" directory)
            (insert "(etaf-scene\n"
                    " :id test-file\n"
                    " :title \"Test file\"\n"
                    " :layers ((:kind field :value 0 :ramp \"Q\")))"))
          (should (= 1 (etaf-screensaver-load-scenes (list directory))))
          (should (memq 'test-file (etaf-screensaver-scenes)))
          (should (equal "Test file"
                         (plist-get (etaf-screensaver-scene-info 'test-file) :title)))
          (with-temp-file (expand-file-name "one.esc" directory)
            (insert "(etaf-scene\n"
                    " :id test-file\n"
                    " :title \"Updated file\"\n"
                    " :layers ((:kind field :value 1 :ramp \"R\")))"))
          (should (= 1 (etaf-screensaver-load-scenes (list directory))))
          (should (equal "Updated file"
                         (plist-get (etaf-screensaver-scene-info 'test-file) :title)))
          (with-temp-file (expand-file-name "broken.esc" directory)
            (insert "(etaf-scene :id test-broken :layers ((:kind unsupported)))"))
          (should (= 1 (etaf-screensaver-load-scenes (list directory))))
          (should-not (memq 'test-broken (etaf-screensaver-scenes))))
      (delete-directory directory t))))

(provide 'etaf-screensaver-tests)
;;; etaf-screensaver-tests.el ends here
