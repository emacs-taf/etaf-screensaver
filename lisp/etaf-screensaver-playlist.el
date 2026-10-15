;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-playlist.el --- Declarative playback programs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Validate a finite program tree before taking over a window.  Each group
;; chooses child programs sequentially, in shuffled bags or with replacement.
;; The root repeats after its finite round finishes.  No expression is evaluated.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-model)

(defgroup etaf-screensaver nil
  "Generative, input-dismissed screensavers."
  :group 'multimedia)

(defcustom etaf-screensaver-program
  '(:order sequential
    :scenes ((:pack neon :count 4)
             (:pack space :count 4)
             (:pack ink :count 3)
             (:pack ember :count 3)))
  "Playback program, repeated until input dismisses the screensaver.
A symbol names a scene.  A scene plist holds :scene and optional :duration,
:frame-rate, :background and :params (an alist).  A `(:pack NAME)' item
plays scenes from `etaf-screensaver-packs' and accepts :order, :count and the
same overrides.  A group holds :order (sequential, shuffle or random), a
nonempty :scenes list of programs and optional :count.  COUNT defaults to the
number of children.  Sequential groups wrap in order; shuffle groups draw
from bags without replacement; random groups allow repeats.  Groups can nest,
so a program can rotate whole style packs, hold one pack for a number of
scenes, loop a single work, or mix packs deliberately."
  :type 'sexp :group 'etaf-screensaver)

(defcustom etaf-screensaver-scene-duration 30
  "Default seconds spent on each scene; individual program items override it."
  :type 'number :group 'etaf-screensaver)

(defcustom etaf-screensaver-scene-options nil
  "Per-scene defaults, such as ((matrix :params ((speed . 5)) :duration 20)).
Each entry is a scene identifier followed by :duration, :frame-rate and/or
:params.  Program item values override these defaults; parameter alists merge.
Changes take effect at the next start.  Invalid options fail before takeover."
  :type 'sexp :group 'etaf-screensaver)

(defcustom etaf-screensaver-max-frame-rate 30
  "Maximum frames per second, including a scene's requested frame rate."
  :type 'number :group 'etaf-screensaver)

(defcustom etaf-screensaver-background "#05070B"
  "Canvas background when a scene does not specify its own."
  :type 'color :group 'etaf-screensaver)

(defcustom etaf-screensaver-seed nil
  "Integer seed for repeatable playback, or nil for a fresh seed at each start."
  :type '(choice (const :tag "Fresh each time" nil) integer)
  :group 'etaf-screensaver)

(defun etaf-screensaver--check-plist (value keys label)
  "Validate VALUE against KEYS, using LABEL in errors."
  (unless (and (proper-list-p value) (zerop (% (length value) 2)))
    (etaf-screensaver--fail "%s must be an even plist" label))
  (let ((tail value) seen)
    (while tail
      (let ((key (pop tail)))
        (pop tail)
        (unless (and (memq key keys) (not (memq key seen)))
          (etaf-screensaver--fail "%s has an unknown or duplicate key: %s" label key))
        (push key seen)))))

(defun etaf-screensaver--parameter-key (key)
  "Normalize parameter KEY, accepting symbols and equivalent keywords."
  (if (keywordp key) (intern (substring (symbol-name key) 1)) key))

(defun etaf-screensaver--parameters (scene overrides)
  "Return validated parameter values for SCENE with OVERRIDES."
  (unless (proper-list-p overrides)
    (etaf-screensaver--fail "Scene parameters must be an alist"))
  (let ((descriptors (etaf-screensaver--scene-params scene)) values seen)
    (dolist (entry overrides)
      (unless (and (consp entry) (symbolp (car entry)))
        (etaf-screensaver--fail "Invalid parameter entry: %s" entry))
      (let* ((key (etaf-screensaver--parameter-key (car entry)))
             (descriptor (cl-find key descriptors :key (lambda (p) (plist-get p :key)))))
        (unless descriptor
          (etaf-screensaver--fail "Unknown parameter %s for %s" key (etaf-screensaver--scene-id scene)))
        ;; Earlier entries have precedence (item, per-scene default).
        (unless (memq key seen)
          (etaf-screensaver--param-validate
           (plist-put (copy-sequence descriptor) :default (cdr entry))
           (etaf-screensaver--scene-id scene))
          (push key seen)
          (push (cons key (cdr entry)) values))))
    (dolist (descriptor descriptors)
      (let ((key (plist-get descriptor :key)))
        (unless (assq key values)
          (push (cons key (plist-get descriptor :default)) values))))
    values))

(defun etaf-screensaver--program-item (program)
  "Validate scene PROGRAM and return its effective settings."
  (let* ((id (if (symbolp program) program (plist-get program :scene)))
         (scene (etaf-screensaver--scene id))
         (defaults (cdr (assq id etaf-screensaver-scene-options)))
         (item (if (symbolp program) nil program)))
    (etaf-screensaver--check-plist item '(:scene :duration :frame-rate :params :background)
                                   "Scene item")
    (let ((duration (or (plist-get item :duration) (plist-get defaults :duration)
                        (etaf-screensaver--scene-duration scene)
                        etaf-screensaver-scene-duration))
          (rate (or (plist-get item :frame-rate) (plist-get defaults :frame-rate)
                    (etaf-screensaver--scene-frame-rate scene))))
      (unless (and (numberp duration) (> duration 0) (< duration 86401))
        (etaf-screensaver--fail "Scene duration must be positive and at most one day"))
      (unless (and (numberp rate) (> rate 0) (<= rate 120))
        (etaf-screensaver--fail "Frame rate must be positive and at most 120"))
      (list :scene id :definition scene
            :background (or (plist-get item :background)
                            (etaf-screensaver--scene-background scene)
                            etaf-screensaver-background)
            :duration duration :frame-rate (min rate etaf-screensaver-max-frame-rate)
            :params (etaf-screensaver--parameters
                     scene (append (plist-get item :params) (plist-get defaults :params)))))))

(defcustom etaf-screensaver-packs
  '((neon :title "霓虹合成"
          :summary "黑底霓虹网格、光束与代码流的合成器风格"
          :theme dark :order sequential :background "#03050D"
          :scenes (tte-beams tte-synthgrid tte-decrypt tte-vhstape tte-rain matrix))
    (space :title "深空"
           :summary "黑洞、雷电、烟花与星野"
           :theme dark :order sequential :background "#010207"
           :scenes (tte-blackhole tte-thunderstorm tte-fireworks tte-unstable starfield))
    (ink :title "文墨"
         :summary "米色纸面、深墨字与光影"
         :theme light :order sequential :background "#F4F1EA"
         :scenes (tte-ink-spotlights tte-ink-waves tte-ink-print))
    (ember :title "余烬"
           :summary "暖色粒子与缓缓落下的沙火"
           :theme dark :order sequential :background "#0A0503"
           :scenes (tte-burn tte-bubbles falling-sand)))
  "Named style packs, each a list of scenes sharing one visual language.
An entry is (ID :title TITLE :summary SUMMARY :theme dark|light :order ORDER
:background COLOR :duration SECONDS :frame-rate RATE :params ALIST :scenes
(SCENE...)).  A program item `(:pack ID)' plays the pack; the pack's :order,
:background, :duration, :frame-rate and :params are defaults the item may
override.  Packs keep a screensaver round inside one style; put several pack
items in one program to rotate styles deliberately.  Bundled packs cover the
scenes shipped with the application; users can add their own with
`add-to-list' after baking or registering scenes."
  :type 'sexp :group 'etaf-screensaver)

(defconst etaf-screensaver--pack-keys
  '(:title :summary :theme :order :background :duration :frame-rate :params :scenes)
  "Keys accepted in a scene pack.")

(defun etaf-screensaver--pack (id)
  "Return pack ID's validated plist, or signal `etaf-screensaver-error'."
  (let ((pack (cdr (assq id etaf-screensaver-packs))))
    (unless (and pack (proper-list-p pack))
      (etaf-screensaver--fail "Unknown scene pack: %s" id))
    (etaf-screensaver--check-plist pack etaf-screensaver--pack-keys
                                   (format "Scene pack %s" id))
    (let ((scenes (plist-get pack :scenes))
          (order (plist-get pack :order)))
      (unless (and (proper-list-p scenes) scenes (cl-every #'symbolp scenes))
        (etaf-screensaver--fail "Scene pack %s needs a list of scene symbols" id))
      (unless (or (null order) (memq order '(sequential shuffle random)))
        (etaf-screensaver--fail "Scene pack %s :order must be sequential, shuffle or random" id)))
    pack))

(defun etaf-screensaver--compile-pack (program depth)
  "Expand the `:pack' PROGRAM at nesting DEPTH into validated scene items.
The pack's defaults apply to every item; the program item overrides them."
  (when (> depth 16)
    (etaf-screensaver--fail "Playback groups are nested too deeply"))
  (etaf-screensaver--check-plist program '(:pack :order :count :duration :frame-rate
                                                  :params :background)
                                 "Pack item")
  (let* ((id (plist-get program :pack))
         (pack (etaf-screensaver--pack id))
         (scenes (plist-get pack :scenes))
         (order (or (plist-get program :order) (plist-get pack :order) 'sequential))
         (count (or (plist-get program :count) (length scenes))))
    (unless (memq order '(sequential shuffle random))
      (etaf-screensaver--fail "Pack order must be sequential, shuffle or random"))
    (unless (and (integerp count) (<= 1 count 1000))
      (etaf-screensaver--fail "A pack needs 1..1000 selections"))
    (list :order order :count count
          :scenes
          (mapcar
           (lambda (scene)
             (let ((item (list :scene scene)))
               (dolist (key '(:duration :frame-rate :background))
                 (let ((value (or (plist-get program key) (plist-get pack key))))
                   (when value (setq item (plist-put item key value)))))
               (let ((params (append (plist-get program :params) (plist-get pack :params))))
                 (when params (setq item (plist-put item :params params))))
               (etaf-screensaver--program-item item)))
           scenes))))

(defun etaf-screensaver--compile-program (program &optional depth)
  "Validate PROGRAM, at nesting DEPTH, into a bounded finite tree."
  (when (> (or depth 0) 16)
    (etaf-screensaver--fail "Playback groups are nested too deeply"))
  (unless (or (symbolp program) (proper-list-p program))
    (etaf-screensaver--fail "A program must be a scene symbol or plist"))
  (cond
   ((or (symbolp program) (plist-member program :scene))
    (etaf-screensaver--program-item program))
   ((plist-member program :pack)
    (etaf-screensaver--compile-pack program (or depth 0)))
   (t
    (etaf-screensaver--check-plist program '(:order :scenes :count) "Playback group")
    (let ((order (plist-get program :order))
          (scenes (plist-get program :scenes)))
      (unless (memq order '(sequential shuffle random))
        (etaf-screensaver--fail "Group order must be sequential, shuffle or random"))
      (unless (and (proper-list-p scenes) scenes (<= (length scenes) 1000))
        (etaf-screensaver--fail "A group needs a list of 1..1000 children"))
      (let ((count (or (plist-get program :count) (length scenes))))
        (unless (and (integerp count) (<= 1 count 1000))
          (etaf-screensaver--fail "A group needs 1..1000 selections"))
        (list :order order :count count
              :scenes (mapcar (lambda (child)
                                (etaf-screensaver--compile-program child (1+ (or depth 0))))
                              scenes)))))))

(defun etaf-screensaver--validate-options ()
  "Validate global playback settings before changing any windows."
  (unless (and (numberp etaf-screensaver-max-frame-rate)
               (< 0 etaf-screensaver-max-frame-rate) (<= etaf-screensaver-max-frame-rate 120))
    (etaf-screensaver--fail "Maximum frame rate must be in (0, 120]"))
  (unless (or (null etaf-screensaver-seed) (integerp etaf-screensaver-seed))
    (etaf-screensaver--fail "Seed must be an integer or nil"))
  (unless (proper-list-p etaf-screensaver-scene-options)
    (etaf-screensaver--fail "Scene options must be an alist"))
  (unless (proper-list-p etaf-screensaver-packs)
    (etaf-screensaver--fail "Scene packs must be an alist"))
  (dolist (entry etaf-screensaver-packs)
    (unless (and (consp entry) (symbolp (car entry)))
      (etaf-screensaver--fail "Invalid scene pack entry")))
  (dolist (entry etaf-screensaver-scene-options)
    (unless (and (consp entry) (symbolp (car entry)))
      (etaf-screensaver--fail "Invalid scene options entry"))
    (etaf-screensaver--check-plist (cdr entry) '(:duration :frame-rate :params) "Scene options")
    (etaf-screensaver--program-item (car entry))))

(defun etaf-screensaver--program-round (tree random-state)
  "Choose a finite round from TREE using RANDOM-STATE."
  (let ((remaining 10000) result)
    (cl-labels
        ((visit (node)
           (when (< (cl-decf remaining) 0)
             (etaf-screensaver--fail "A playback round exceeds 10000 nodes"))
           (if (plist-member node :scene)
               (push node result)
             (let* ((children (plist-get node :scenes))
                    (count (length children))
                    bag)
               (dotimes (index (plist-get node :count))
                 (visit
                  (pcase (plist-get node :order)
                    ('sequential (nth (% index count) children))
                    ('random (nth (cl-random count random-state) children))
                    ('shuffle
                     (unless bag (setq bag (copy-sequence children)))
                     (let* ((position (cl-random (length bag) random-state))
                            (chosen (nth position bag)))
                       (setq bag (append (cl-subseq bag 0 position) (nthcdr (1+ position) bag)))
                       chosen)))))))))
      (visit tree))
    (nreverse result)))

(provide 'etaf-screensaver-playlist)
;;; etaf-screensaver-playlist.el ends here
