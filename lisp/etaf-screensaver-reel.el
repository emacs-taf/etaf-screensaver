;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-reel.el --- Adapting recorded frame sequences

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A reel is a recorded animation from an external animation tool, shown
;; through the ordinary scene contract.  Providers translate one native
;; format into frames; the reel layer owns pacing, center fitting and the
;; lazy conversion shared by every provider.  Recording bytes stay in their
;; native format: importing references and copies them, it does not
;; transcode them.  Frames are read when the reel's scene is created, so an
;; unused reel costs nothing after registration.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-ansi)

(defvar etaf-screensaver--reel-directory nil
  "Directory of the reel file being read, used to resolve :recording.")

(defconst etaf-screensaver--reel-provider-keys
  '(:title :license :extensions :match :read)
  "Keys accepted in a reel provider description.
:TITLE and :LICENSE are display strings.  :EXTENSIONS lists file name
suffixes without a leading dot for batch import.  :MATCH takes a file path
and returns non-nil when the provider recognizes it.  :READ takes a file
path and returns a plist with :width and :height (positive integers),
:frame-rate (positive number), :frames (a nonempty vector of frame strings)
and optional :durations (seconds per frame), :ansi (frame text carries SGR
runs) and :source (a short display description).")

(defvar etaf-screensaver--reel-providers nil
  "Registered reel providers as (ID . PLIST) pairs.")

(defun etaf-screensaver-define-reel-provider (id &rest properties)
  "Register the reel provider ID with PROPERTIES and return ID.
PROPERTIES is a plist with :title, :license, :extensions, :match and :read;
see `etaf-screensaver--reel-provider-keys' for their meaning.  Re-registering
an ID replaces the provider in place, so a provider can be refined without
disturbing imported reels."
  (unless (symbolp id)
    (etaf-screensaver--fail "Reel provider must be a symbol: %S" id))
  (let ((plist properties))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--reel-provider-keys)
          (etaf-screensaver--fail "Reel provider %s has unknown key %S" id key)))))
  (let ((title (plist-get properties :title))
        (license (plist-get properties :license))
        (extensions (plist-get properties :extensions)))
    (unless (and (stringp title) (not (equal title "")))
      (etaf-screensaver--fail "Reel provider %s needs a nonempty :title" id))
    (unless (and (stringp license) (not (equal license "")))
      (etaf-screensaver--fail "Reel provider %s needs a nonempty :license" id))
    (unless (and (proper-list-p extensions)
                 (cl-every (lambda (extension)
                             (and (stringp extension) (not (equal extension ""))))
                           extensions))
      (etaf-screensaver--fail "Reel provider %s :extensions must be file name suffixes" id))
    (dolist (key '(:match :read))
      (unless (functionp (plist-get properties key))
        (etaf-screensaver--fail "Reel provider %s needs a function for %s" id key))))
  (setf etaf-screensaver--reel-providers
        (cons (cons id properties)
              (assq-delete-all id etaf-screensaver--reel-providers)))
  id)

(defconst etaf-screensaver--reel-keys
  '(:id :title :summary :tags :provider :recording :width :height :frame-rate
    :frame-count :source :license :background)
  "Keys accepted in a reel spec.")

(defconst etaf-screensaver--reel-read-cache-limit 2
  "Number of unchanged recordings a session keeps for instant replay.")

(defconst etaf-screensaver--reel-read-cache-chars (* 48 1024 1024)
  "Largest recording, in frame characters, stored in the read cache.")

(defvar etaf-screensaver--reel-read-cache nil
  "Most recent provider reads as (KEY . DATA) pairs, newest first.
KEY identifies the provider, file and its size and modification time, so an
edited recording is read again.  The cache bounds how much recording text a
session retains; a larger recording is read again for every playback.")

(defun etaf-screensaver--reel-read-cache-key (provider-id file)
  "Return the read-cache key of FILE read through PROVIDER-ID."
  (let ((attributes (file-attributes file)))
    (list provider-id (file-truename file)
          (file-attribute-size attributes)
          (float-time (file-attribute-modification-time attributes)))))

(defun etaf-screensaver--reel-data-size (data)
  "Return DATA's frame text size in characters."
  (let ((frames (plist-get data :frames)) (total 0))
    (when (vectorp frames)
      (dotimes (index (length frames))
        (cl-incf total (length (aref frames index)))))
    total))

(defun etaf-screensaver--reel-read (provider-id provider file)
  "Read FILE through PROVIDER, reusing a recent unchanged result.
Read errors are not cached.  Only recordings whose frame text fits the cache
budget are retained, newest first."
  (let* ((key (etaf-screensaver--reel-read-cache-key provider-id file))
         (cached (assoc key etaf-screensaver--reel-read-cache)))
    (or (cdr cached)
        (let ((data (funcall (plist-get provider :read) file)))
          (when (<= (etaf-screensaver--reel-data-size data)
                    etaf-screensaver--reel-read-cache-chars)
            (setq etaf-screensaver--reel-read-cache
                  (cons (cons key data)
                        (cl-subseq etaf-screensaver--reel-read-cache
                                   0 (min (1- etaf-screensaver--reel-read-cache-limit)
                                          (length etaf-screensaver--reel-read-cache))))))
          data))))

(defun etaf-screensaver--reel-file (recording)
  "Return RECORDING as an absolute file name.
A relative RECORDING resolves against the reel file's directory, or the
current `default-directory' when a reel is registered from Lisp."
  (if (file-name-absolute-p recording)
      recording
    (expand-file-name recording (or etaf-screensaver--reel-directory
                                    default-directory))))

(defun etaf-screensaver--reel-validate (spec)
  "Validate reel spec SPEC and return it.
Signal `etaf-screensaver-error' for unknown keys or invalid values."
  (unless (proper-list-p spec)
    (etaf-screensaver--fail "Reel spec must be a plist: %S" spec))
  (let ((plist spec))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--reel-keys)
          (etaf-screensaver--fail "Reel spec has unknown key %S" key)))))
  (let ((id (plist-get spec :id))
        (title (plist-get spec :title))
        (summary (plist-get spec :summary))
        (tags (plist-get spec :tags))
        (provider (plist-get spec :provider))
        (recording (plist-get spec :recording))
        (width (plist-get spec :width))
        (height (plist-get spec :height))
        (frame-rate (plist-get spec :frame-rate))
        (frame-count (plist-get spec :frame-count))
        (source (plist-get spec :source))
        (license (plist-get spec :license))
        (background (plist-get spec :background)))
    (unless (symbolp id)
      (etaf-screensaver--fail "Reel spec needs a symbol :id: %S" id))
    (unless (and (symbolp provider) provider)
      (etaf-screensaver--fail "Reel %s needs a :provider symbol" id))
    (unless (cdr (assq provider etaf-screensaver--reel-providers))
      (etaf-screensaver--fail "Reel %s uses an unknown provider: %s" id provider))
    (unless (and (stringp recording) (not (equal recording "")))
      (etaf-screensaver--fail "Reel %s needs a nonempty :recording file name" id))
    (unless (or (null title) (and (stringp title) (not (equal title ""))))
      (etaf-screensaver--fail "Reel %s :title must be a nonempty string" id))
    (unless (or (null summary) (stringp summary))
      (etaf-screensaver--fail "Reel %s :summary must be a string" id))
    (unless (or (null tags) (proper-list-p tags))
      (etaf-screensaver--fail "Reel %s :tags must be a list" id))
    (dolist (entry (list (cons :width width) (cons :height height)
                         (cons :frame-count frame-count)))
      (let ((value (cdr entry)))
        (unless (or (null value)
                    (and (integerp value) (>= value 1)
                         (if (eq (car entry) :frame-count)
                             t
                           (<= value 4096))))
          (etaf-screensaver--fail "Reel %s %s must be a positive integer" id (car entry)))))
    (unless (or (null frame-rate) (and (numberp frame-rate) (> frame-rate 0)))
      (etaf-screensaver--fail "Reel %s :frame-rate must be a positive number" id))
    (unless (or (null source) (stringp source))
      (etaf-screensaver--fail "Reel %s :source must be a string" id))
    (unless (or (null license) (stringp license))
      (etaf-screensaver--fail "Reel %s :license must be a string" id))
    (unless (or (null background) (stringp background))
      (etaf-screensaver--fail "Reel %s :background must be a color string" id)))
  spec)

(defconst etaf-screensaver--reel-continuation 'continuation
  "Cell marker for the second display cell of a wide character.")

(defun etaf-screensaver--reel-entry (state index)
  "Return INDEX's cached (ROWS . CELLS) entry of STATE, converting it once."
  (let* ((cache (plist-get state :cache))
         (entry (aref cache index)))
    (unless entry
      (let* ((frame (aref (plist-get state :frames) index))
             (text (if (plist-get state :ansi)
                       (etaf-screensaver--ansi-render frame)
                     frame))
             (rows (vconcat (split-string text "\n"))))
        (unless (= (length rows) (plist-get state :height))
          (etaf-screensaver--fail "Reel frame %d has %d rows, expected %d"
                                  index (length rows) (plist-get state :height)))
        (setq entry (cons rows nil))
        (aset cache index entry)))
    entry))

(defun etaf-screensaver--reel-cells (entry)
  "Return ENTRY's rows expanded to one (CHARACTER . FACE) per display cell.
The second cell of a wide character holds `etaf-screensaver--reel-continuation'."
  (or (cdr entry)
      (setcdr entry
              (vconcat
               (mapcar
                (lambda (row)
                  (let ((cells nil) (index 0))
                    (while (< index (length row))
                      (let* ((character (aref row index))
                             (width (char-width character))
                             (face (get-text-property index 'face row)))
                        (push (cons character face) cells)
                        (dotimes (_ (1- width))
                          (push (cons etaf-screensaver--reel-continuation face) cells))
                        (cl-incf index)))
                    (vconcat (nreverse cells))))
                (car entry))))))

(defun etaf-screensaver--reel-run (run face)
  "Return the characters collected in RUN with FACE applied."
  (let ((text (apply #'concat (nreverse run))))
    (if face (propertize text 'face face) text)))

(defun etaf-screensaver--reel-slice (cells start width)
  "Return display cells START..START+WIDTH-1 of CELLS as one propertized string.
A window edge that splits a wide character shows a space for the excluded
half, so the result always occupies exactly WIDTH display cells."
  (let ((end (min (length cells) (+ start width)))
        (index start)
        (parts nil)
        (run nil)
        (run-face :unset))
    (cl-labels
        ((emit (character face)
           (if (and run (equal face run-face))
               (push (string character) run)
             (when run
               (push (etaf-screensaver--reel-run run run-face) parts))
             (setq run (list (string character))
                   run-face face))))
      (while (< index end)
        (let ((character (car (aref cells index)))
              (face (cdr (aref cells index))))
          (if (eq character etaf-screensaver--reel-continuation)
              (progn (emit ?\s face) (cl-incf index))
            (let ((size (char-width character)))
              (if (<= (+ index size) end)
                  (progn (emit character face) (cl-incf index size))
                (emit ?\s face)
                (cl-incf index))))))
      (when run
        (push (etaf-screensaver--reel-run run run-face) parts))
      (apply #'concat (nreverse parts)))))

(defun etaf-screensaver--reel-render (state context)
  "Return STATE's current frame fitted into CONTEXT's canvas.
The frame is centered both ways; a canvas smaller than the recording crops
both edges and a larger one pads with spaces."
  (let* ((columns (plist-get context :columns))
         (rows (plist-get context :rows))
         (source-width (plist-get state :width))
         (source-height (plist-get state :height))
         (entry (etaf-screensaver--reel-entry state (plist-get state :index)))
         (frame-rows (car entry))
         (first (max 0 (/ (- source-height rows) 2)))
         (visible (min rows source-height))
         (top (max 0 (/ (- rows source-height) 2)))
         (left (max 0 (/ (- columns source-width) 2)))
         (right (max 0 (- columns source-width left)))
         (crop (max 0 (/ (- source-width columns) 2))))
    (append
     (make-list top "")
     (cl-loop for row below visible
              collect
              (let ((line (aref frame-rows (+ first row))))
                (if (<= source-width columns)
                    (concat (make-string left ?\s) line (make-string right ?\s))
                  (etaf-screensaver--reel-slice
                   (aref (etaf-screensaver--reel-cells entry) (+ first row))
                   crop columns))))
     (make-list (- rows top visible) ""))))

(defun etaf-screensaver--reel-step (state context)
  "Advance STATE by CONTEXT's elapsed seconds, following frame durations.
A scene duration shorter than the recording loops it from the start."
  (let* ((durations (plist-get state :durations))
         (count (length durations))
         (clock (+ (plist-get state :clock) (float (or (plist-get context :dt) 0))))
         (index (plist-get state :index))
         (guard 0))
    (while (and (< guard 10000) (>= clock (aref durations index)))
      (setq clock (- clock (aref durations index))
            index (% (1+ index) count)
            guard (1+ guard)))
    (when (= guard 10000)
      ;; An unreasonably large step should not walk the whole recording.
      (setq clock 0.0))
    (setf (plist-get state :clock) clock)
    (setf (plist-get state :index) index)))

(defun etaf-screensaver--reel-create (reel provider file)
  "Read FILE through PROVIDER for REEL and return its playback state."
  (let ((data (condition-case problem
                  (etaf-screensaver--reel-read (plist-get reel :provider) provider file)
                (etaf-screensaver-error (signal (car problem) (cdr problem)))
                (error (etaf-screensaver--fail "Cannot read recording %s: %s"
                                               file (error-message-string problem))))))
    (let* ((width (plist-get data :width))
           (height (plist-get data :height))
           (frames (plist-get data :frames))
           (count (and (vectorp frames) (length frames)))
           (rate (or (plist-get data :frame-rate) (plist-get reel :frame-rate) 15))
           (durations (or (plist-get data :durations)
                          (make-vector (or count 0) (/ 1.0 rate))))
           (id (plist-get reel :id)))
      (unless (and (integerp width) (<= 1 width 4096)
                   (integerp height) (<= 1 height 4096))
        (etaf-screensaver--fail "Reel %s reports an invalid canvas size" id))
      (unless (and count (> count 0) (cl-every #'stringp frames))
        (etaf-screensaver--fail "Reel %s did not produce any frames" id))
      (unless (and (vectorp durations) (= (length durations) count)
                   (cl-every (lambda (duration)
                               (and (numberp duration) (> duration 0)))
                             durations))
        (etaf-screensaver--fail "Reel %s has invalid frame durations" id))
      (list :frames frames :durations durations :ansi (plist-get data :ansi)
            :width width :height height :index 0 :clock 0.0
            :cache (make-vector count nil)))))

(defun etaf-screensaver-register-reel (spec)
  "Register the recorded animation described by SPEC and return the scene.
SPEC is a plist, optionally wrapped as (etaf-reel ...), with :id, :provider
and :recording plus optional :title, :summary, :tags, :width, :height,
:frame-rate, :frame-count, :source, :license and :background.  :recording is
resolved relative to the reel file's directory.  Registering the same :id
again replaces the previous scene in place.

The scene reads the recording when it is created, so a registered but unused
reel holds only metadata.  Playback follows the recording's own per-frame
timing and centers its fixed canvas; a smaller canvas crops both edges."
  (let* ((reel (if (eq (car-safe spec) 'etaf-reel) (cdr spec) spec)))
    (etaf-screensaver--reel-validate reel)
    (let* ((id (plist-get reel :id))
           (provider-id (plist-get reel :provider))
           (provider (cdr (assq provider-id etaf-screensaver--reel-providers)))
           (file (etaf-screensaver--reel-file (plist-get reel :recording)))
           (title (or (plist-get reel :title) (file-name-base file)))
           (rate (or (plist-get reel :frame-rate) 15)))
      (unless (file-regular-p file)
        (etaf-screensaver--fail "Reel %s recording does not exist: %s" id file))
      (etaf-screensaver--register
       id
       (list
        :title title
        :summary
        (or (plist-get reel :summary)
            (format "%s recording (%s%s); %d frames at %s fps"
                    provider-id (plist-get provider :title)
                    (if-let* ((source (plist-get reel :source)))
                        (format ": %s" source)
                      "")
                    (or (plist-get reel :frame-count) 0) rate))
        :tags (append (plist-get reel :tags) (list 'reel provider-id))
        :frame-rate rate
        :background (plist-get reel :background)
        :create (lambda (_context) (etaf-screensaver--reel-create reel provider file))
        :step #'etaf-screensaver--reel-step
        :render #'etaf-screensaver--reel-render
        :resize (lambda (state _context) state))))))

(provide 'etaf-screensaver-reel)
;;; etaf-screensaver-reel.el ends here
