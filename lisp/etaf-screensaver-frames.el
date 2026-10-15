;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-frames.el --- Baked image-frame recordings

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A baked image recording is a set of still frames plus a small JSON
;; manifest.  This provider reads the manifest, validates every frame file
;; and reports the pixel size and timing to the reel layer.  Frames may come
;; from any renderer that can export stills: an offline browser canvas, a
;; shader preview or a decoder.  Playback replays the files; it never runs
;; the renderer.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'image)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-reel)

(defconst etaf-screensaver-frames--version 1
  "Manifest format version this provider reads.")

(defconst etaf-screensaver-frames--suffix ".frames.json"
  "File name suffix of an image-frame manifest.")

(defun etaf-screensaver-frames-manifest-p (file)
  "Return non-nil when FILE names an image-frame manifest."
  (and (stringp file) (string-suffix-p etaf-screensaver-frames--suffix file)))

(defun etaf-screensaver--frames-read (file)
  "Read the baked image manifest FILE and return its frames.
The manifest holds version, width, height, frame_rate and a frames list of
file names relative to the manifest; optional source and license describe
the work."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((manifest (condition-case nil
                        (json-parse-string (buffer-string)
                                           :object-type 'plist :array-type 'list)
                      (error (etaf-screensaver--fail
                              "Frame manifest is not valid JSON: %s" file)))))
      (unless (and (listp manifest)
                   (equal (plist-get manifest :version) etaf-screensaver-frames--version))
        (etaf-screensaver--fail "Unsupported frame manifest version: %s" file))
      (let ((width (plist-get manifest :width))
            (height (plist-get manifest :height))
            (frame-rate (plist-get manifest :frame_rate))
            (names (plist-get manifest :frames)))
        (unless (and (integerp width) (> width 0) (integerp height) (> height 0))
          (etaf-screensaver--fail "Frame manifest has no valid pixel size: %s" file))
        (unless (and (numberp frame-rate) (> frame-rate 0))
          (etaf-screensaver--fail "Frame manifest has no valid frame rate: %s" file))
        (unless (and (proper-list-p names) names (cl-every #'stringp names))
          (etaf-screensaver--fail "Frame manifest has no frame list: %s" file))
        (let* ((directory (file-name-directory file))
               (paths (mapcar (lambda (name) (expand-file-name name directory)) names)))
          (dolist (path paths)
            (unless (file-regular-p path)
              (etaf-screensaver--fail "Frame file is missing: %s" path))
            (unless (image-type-from-file-header path)
              (etaf-screensaver--fail "Frame file is not a supported image: %s" path)))
          (list :image-frames (vconcat paths)
                :image-size (cons width height)
                :frame-rate frame-rate
                :source (or (plist-get manifest :source)
                            (replace-regexp-in-string
                             "\\.frames\\'" "" (file-name-base file)))
                :license (plist-get manifest :license)
                :assets (cons file paths)))))))

(etaf-screensaver-define-reel-provider 'frames
  :title "Baked image frames"
  :license "See recording manifest"
  :extensions '("frames.json")
  :match #'etaf-screensaver-frames-manifest-p
  :read #'etaf-screensaver--frames-read)

(provide 'etaf-screensaver-frames)
;;; etaf-screensaver-frames.el ends here
