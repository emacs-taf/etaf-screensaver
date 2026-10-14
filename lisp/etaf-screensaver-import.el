;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-import.el --- Importing recorded animations

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Importing copies a native recording next to a small reel spec file that
;; names its provider.  The recording is validated and described through the
;; provider contract; it is never transcoded, so the original tool can
;; re-render or replace it.  A batch import reports per-file compatibility,
;; dimensions, timing, color depths and the provider license instead of
;; claiming that every file is supported.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-reel)
(require 'etaf-screensaver-loader)

(defun etaf-screensaver--reel-provider-for (file)
  "Return the (ID . PLIST) provider entry that recognizes FILE, or nil."
  (cl-find-if (lambda (entry)
                (let ((match (plist-get (cdr entry) :match)))
                  (condition-case nil
                      (funcall match file)
                    (error nil))))
              etaf-screensaver--reel-providers))

(defun etaf-screensaver--reel-extensions ()
  "Return the distinct recording extensions registered by providers."
  (cl-remove-duplicates
   (cl-loop for (_id . provider) in etaf-screensaver--reel-providers
            append (plist-get provider :extensions))
   :test #'equal))

(defun etaf-screensaver--import-name (provider-id file)
  "Return the reel identifier for FILE imported through PROVIDER-ID."
  (intern (replace-regexp-in-string
           "^-\\|-$" ""
           (concat (symbol-name provider-id) "-"
                   (replace-regexp-in-string
                    "[^a-z0-9]+" "-" (downcase (file-name-base file)))))))

(defun etaf-screensaver--import-directory (destination)
  "Return the directory that receives imported reels.
DESTINATION overrides the user scene directory; it is created on demand."
  (let ((directory (or destination
                       (car (last etaf-screensaver-scene-directories))
                       (locate-user-emacs-file "etaf-screensaver/scenes"))))
    (make-directory directory t)
    directory))

(defun etaf-screensaver--import-summary (provider file source width height
                                                  frame-count frame-rate license)
  "Return the one-line scene summary for an imported recording."
  (let ((named (and (stringp source) (not (equal source "")))))
    (format "%s%s recording, %d×%d, %s frames at %s fps, %s license"
            (if named source (file-name-base file))
            (if named (format " (%s)" (plist-get provider :title)) "")
            width height frame-count frame-rate license)))

(defun etaf-screensaver--import-file (file destination)
  "Import FILE into DESTINATION and return a report plist.
Signal `etaf-screensaver-error' when no provider recognizes FILE or the
recording fails validation."
  (let ((file (expand-file-name file)))
    (let* ((entry (or (etaf-screensaver--reel-provider-for file)
                      (etaf-screensaver--fail "No reel provider recognizes %s" file)))
           (provider-id (car entry))
           (provider (cdr entry))
           (data (etaf-screensaver--reel-read provider-id provider file))
           (width (plist-get data :width))
           (height (plist-get data :height))
           (frame-rate (plist-get data :frame-rate))
           (frames (plist-get data :frames))
           (frame-count (and (vectorp frames) (length frames)))
           (source (plist-get data :source))
           (id (etaf-screensaver--import-name provider-id file))
           (directory (etaf-screensaver--import-directory destination))
           (recording (expand-file-name (file-name-nondirectory file) directory))
           (spec (list :id id
                       :title (format "%s: %s" (plist-get provider :title)
                                      (or (and (stringp source) (not (equal source "")) source)
                                          (file-name-base file)))
                       :summary (etaf-screensaver--import-summary
                                 provider file source width height frame-count
                                 frame-rate (plist-get provider :license))
                       :tags '(imported)
                       :provider provider-id
                       :recording (file-name-nondirectory recording)
                       :width width :height height :frame-rate frame-rate
                       :frame-count frame-count
                       :source source :license (plist-get provider :license)))
           (target (expand-file-name (format "%s.esr" id) directory)))
      (unless (equal (file-truename file) (file-truename recording))
        (copy-file file recording t))
      (with-temp-file target
        (insert ";;; -*- lisp-data -*-\n")
        (prin1 spec (current-buffer))
        (insert "\n"))
      (list :file file :status 'imported :provider provider-id
            :title (plist-get spec :title) :output target :recording recording
            :width width :height height :frame-rate frame-rate
            :frame-count frame-count :colors (plist-get data :colors)
            :attributes (plist-get data :attributes)
            :license (plist-get provider :license) :source source))))

(defun etaf-screensaver-import-recording (file &optional destination)
  "Import one recording FILE as a reel and return its report plist.
DESTINATION defaults to the user scene directory.  The native recording is
copied next to a new .esr reel spec that names its provider, dimensions,
frame count and license.  Validation failures signal
`etaf-screensaver-error' and write nothing; a file no provider recognizes
also signals.
The report contains :file, :status `imported', :provider, :title, :output,
:recording, :width, :height, :frame-rate, :frame-count, :colors,
:attributes, :license and :source."
  (interactive "fRecording file: ")
  (etaf-screensaver--import-file file destination))

(defun etaf-screensaver-import-directory (directory &optional destination)
  "Import every recording DIRECTORY holds and return a report plist.
Candidate files are the extensions registered by reel providers.  A file no
provider recognizes is skipped; a recognized file that fails validation is
reported as failed.  Imported reels are written to DESTINATION, which
defaults to the user scene directory.  The report contains :directory,
:destination and the :imported, :skipped and :failed lists; every entry
carries the file and its provider-visible properties, so callers can audit
compatibility, dimensions, color use and license before playing anything.
Use `etaf-screensaver-load-scenes' afterwards to register the new reels."
  (interactive "DRecording directory: ")
  (let ((directory (expand-file-name directory))
        (extensions (etaf-screensaver--reel-extensions))
        (imported nil) (skipped nil) (failed nil))
    (unless (file-directory-p directory)
      (etaf-screensaver--fail "Not a directory: %s" directory))
    (let ((files (directory-files
                  directory t
                  (concat "\\`[^.#].*\\.\\(" (regexp-opt extensions t) "\\)\\'"))))
      (dolist (file files)
        (if (null (etaf-screensaver--reel-provider-for file))
            (push (list :file file :status 'skipped
                        :reason "no reel provider recognizes this file")
                  skipped)
          (condition-case problem
              (push (etaf-screensaver--import-file file destination) imported)
            (etaf-screensaver-error
             (push (list :file file :status 'failed
                         :reason (car (cdr problem)))
                   failed))))))
    (setq imported (nreverse imported)
          skipped (nreverse skipped)
          failed (nreverse failed))
    (message "Screensaver import: %d imported, %d skipped, %d failed"
             (length imported) (length skipped) (length failed))
    (list :directory directory
          :destination (etaf-screensaver--import-directory destination)
          :imported imported :skipped skipped :failed failed)))

(provide 'etaf-screensaver-import)
;;; etaf-screensaver-import.el ends here
