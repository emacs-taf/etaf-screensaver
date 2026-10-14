;;; etaf-screensaver-theme.el --- Semantic palette of etaf-screensaver -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; One palette read through `etaf-screensaver-color', so a palette change can
;; never leak a half-updated set of colors.  Scenes default to the canvas
;; background; a scene may override it with its own `:background'.  The UI
;; tokens cover the catalog Components the workspace uses (labels, sliders,
;; segmented selectors, switches and buttons).

;;; Code:

(defconst etaf-screensaver-palette
  '((:bg . "#0B0E14")
    (:canvas . "#05070B")
    (:surface . "#11161F")
    (:surface-2 . "#181F2A")
    (:ink . "#E6EDF3")
    (:muted . "#8B98A9")
    (:accent . "#5AA9FF")
    (:accent-soft . "#12263D")
    (:border . "#2A3441")
    (:ok . "#4ADE80")
    (:warn . "#FBBF24"))
  "Semantic palette of the screensaver workspace.")

(defun etaf-screensaver-color (key)
  "Return the palette color for KEY.
An unknown KEY falls back to the current frame's default foreground."
  (or (alist-get key etaf-screensaver-palette)
      (if (eq (frame-parameter nil 'background-mode) 'light)
          "#1F2328" "#E6EDF3")))

(defun etaf-screensaver-theme-defaults ()
  "Return the ETAF UI token plist for this palette.
The workspace passes the result to `etaf-theme-provide' before mounting;
otherwise etaf-ui Components keep their own defaults and the workspace looks
half-themed.  Keep this list in step with the Components actually used."
  (let ((accent (etaf-screensaver-color :accent)))
    (list :ui-fg (etaf-screensaver-color :ink)
          :ui-bg (etaf-screensaver-color :bg)
          :ui-border (etaf-screensaver-color :border)
          :ui-muted-fg (etaf-screensaver-color :muted)
          :ui-disabled-fg (etaf-screensaver-color :muted)
          :ui-disabled-bg (etaf-screensaver-color :surface)
          :ui-disabled-border (etaf-screensaver-color :border)
          :ui-accent accent
          :ui-accent-fg "#FFFFFF"
          :ui-accent-soft-bg (etaf-screensaver-color :accent-soft)
          :ui-button-primary-fg "#FFFFFF"
          :ui-button-primary-bg accent
          :ui-button-secondary-fg accent
          :ui-button-secondary-bg (etaf-screensaver-color :accent-soft)
          :ui-button-ghost-fg (etaf-screensaver-color :muted)
          :ui-button-ghost-bg (etaf-screensaver-color :surface)
          :ui-range-track (etaf-screensaver-color :border)
          :ui-range-fill accent
          :ui-success-fg (etaf-screensaver-color :ok)
          :ui-success-bg (etaf-screensaver-color :surface-2)
          :ui-success-border (etaf-screensaver-color :border)
          :ui-danger-fg (etaf-screensaver-color :muted)
          :ui-danger-bg (etaf-screensaver-color :surface-2)
          :ui-danger-border (etaf-screensaver-color :border)
          :ui-warning-fg (etaf-screensaver-color :warn)
          :ui-warning-bg (etaf-screensaver-color :surface-2)
          :ui-warning-border (etaf-screensaver-color :border))))

(provide 'etaf-screensaver-theme)
;;; etaf-screensaver-theme.el ends here
