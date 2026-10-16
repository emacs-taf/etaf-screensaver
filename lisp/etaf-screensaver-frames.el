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
  (unless (<= (file-attribute-size (file-attributes file)) (* 1024 1024))
    (etaf-screensaver--fail "Frame manifest exceeds 1 MiB: %s" file))
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
        (unless (and (integerp width) (<= 1 width 2048)
                     (integerp height) (<= 1 height 2048)
                     (<= (* width height) 2073600))
          (etaf-screensaver--fail "Frame manifest has no valid bounded pixel size: %s" file))
        (unless (and (numberp frame-rate) (<= 1 frame-rate 120))
          (etaf-screensaver--fail "Frame manifest has no valid frame rate: %s" file))
        (unless (and (proper-list-p names) (<= 1 (length names) 7200)
                     (cl-every (lambda (name)
                                 (and (stringp name) (not (member name '("." "..")))
                                      (not (equal name ""))
                                      (not (string-match-p "[/\\\\\0]" name))))
                               names))
          (etaf-screensaver--fail "Frame manifest needs 1–7200 local basenames: %s" file))
        (let* ((directory (file-name-directory (expand-file-name file)))
               (paths (mapcar (lambda (name) (expand-file-name name directory)) names))
               (bytes 0))
          (dolist (path paths)
            (unless (file-regular-p path)
              (etaf-screensaver--fail "Frame file is missing: %s" path))
            (unless (file-in-directory-p (file-truename path) directory)
              (etaf-screensaver--fail "Frame file escapes its bundle: %s" path))
            (let ((size (file-attribute-size (file-attributes path))))
              (cl-incf bytes size)
              (unless (and (<= size (* 16 1024 1024)) (<= bytes (* 1024 1024 1024)))
                (etaf-screensaver--fail "Frame bundle exceeds its byte limit: %s" file)))
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
