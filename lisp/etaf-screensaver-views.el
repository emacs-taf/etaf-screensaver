;;; etaf-screensaver-views.el --- Views of etaf-screensaver -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Views are pure projections: they read the session's refs and return
;; structure.  The canvas is one fixed text Host whose content the engine
;; replaces through the retained boundary; the HUD line is a second Host, so a
;; running scene never re-renders the application.  Chrome changes (cinema
;; mode, the parameter panel) bump refs the shell reads and re-render once.
;;
;; Parameter rows reuse the catalog's controlled Components: a number is a
;; Slider, a choice a Segmented selector and a toggle a Switch, each reading
;; the session's parameter ref and writing it back through the session.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-screensaver-theme)
(require 'etaf-screensaver-engine)

(defun etaf-screensaver--canvas-color (session)
  "Return SESSION's canvas background color."
  (or (etaf-screensaver--scene-background (etaf-screensaver--session-scene session))
      (etaf-screensaver-color :canvas)))

(etaf-define-component etaf-screensaver-canvas (&key session)
  "Draw SESSION's frame in one fixed, retained text Host.
The Host size follows the session's SIZE ref; the scene's POINTER callback,
when present, receives every pointer gesture on the canvas."
  :bindings ((size (etaf-screensaver--session-size session))
             (pointer (etaf-screensaver--session-pointer session)))
  :view
  ;; Placement is declared on the canvas node itself so Ebox's retained
  ;; content route can prove an inline placement winner; a call-site prop
  ;; that only reached the node through component scoping would keep every
  ;; published frame on the ordinary re-render route.
  (box :width (list 'ch (car (etaf-value size)))
       :height (list 'lh (cdr (etaf-value size)))
       :position 'static :left '(px 0) :top '(lh 0) :z-index 0
       :wrap-mode 'none :overflow 'hidden
       :background-color (etaf-screensaver--canvas-color session)
       :on-drag (when (etaf-value pointer)
                  (lambda (gesture)
                    (etaf-screensaver--session-pointer-event session gesture)))
    (text :ref (etaf-screensaver--session-canvas-ref session)
          :id (etaf-screensaver--session-canvas-id session)
          (expr (etaf-screensaver--session-frame session)))))

(etaf-define-component etaf-screensaver-param-row (&key session param)
  "Render one parameter control for SESSION from descriptor PARAM."
  :bindings ((value (etaf-screensaver--session-param-ref
                     session (plist-get param :key))))
  :view
  (flex :width 'stretch :align-items 'center :justify-content 'space-between
        :column-gap '(ch 2) :padding '((lh 0) (ch 2))
        :background-color (etaf-screensaver-color :surface)
    (etaf-label :text (plist-get param :label) :variant 'strong :width '(ch 22))
    (expr
     (pcase (plist-get param :type)
       ('number
        (etaf-view
         (etaf-slider :label (plist-get param :label)
                      :value value
                      :min (plist-get param :min)
                      :max (plist-get param :max)
                      :step (or (plist-get param :step) 1)
                      :on-change
                      (lambda (next)
                        (etaf-screensaver--session-set-param
                         session (plist-get param :key) next)))))
       ('choice
        (etaf-view
         (etaf-segmented :value value
                         :options (plist-get param :options)
                         :on-change
                         (lambda (next)
                           (etaf-screensaver--session-set-param
                            session (plist-get param :key) next)))))
       ('toggle
        (etaf-view
         (etaf-switch :checked value
                      :label (plist-get param :label)
                      :on-change
                      (lambda (next)
                        (etaf-screensaver--session-set-param
                         session (plist-get param :key) next)))))))))

(etaf-define-component etaf-screensaver-params (&key session revision)
  "Render SESSION's open parameter panel.
REVISION is read so switching scenes rebuilds the panel's rows."
  :view
  (column :width 'stretch :background-color (etaf-screensaver-color :surface)
    (expr
     (when (>= (etaf-value revision) 0)
       (mapcar (lambda (param)
                 (etaf-view (etaf-screensaver-param-row
                             :key (plist-get param :key)
                             :session session :param param)))
               (etaf-screensaver--scene-params
                (etaf-screensaver--session-scene session)))))))

(etaf-define-component etaf-screensaver-shell (&key session)
  "Render the mounted workspace for SESSION.
The canvas fills every row the chrome does not take; cinema mode removes the
chrome entirely and an open parameter panel adds one row per parameter."
  :setup
  (etaf-theme-provide (etaf-screensaver-theme-defaults))
  :bindings ((cinema (etaf-screensaver--session-cinema session))
             (params-open (etaf-screensaver--session-params-open session))
             (revision (etaf-screensaver--session-revision session)))
  :view
  (column :width 'stretch :height 'stretch
          :background-color (etaf-screensaver--canvas-color session)
    (etaf-screensaver-canvas :session session)
    (box :if (not (etaf-value cinema))
         :width 'stretch :height '(lh 1) :wrap-mode 'none :overflow 'hidden
         :background-color (etaf-screensaver-color :bg)
      (text :ref (etaf-screensaver--session-hud-ref session)
            :id (etaf-screensaver--session-hud-id session)
            :color (etaf-screensaver-color :muted)
            (expr (etaf-screensaver--session-hud-text session))))
    (expr (if (and (not (etaf-value cinema)) (etaf-value params-open))
              (etaf-view (etaf-screensaver-params :session session
                                                  :revision (etaf-value revision)))
            nil))
    (flex :if (not (etaf-value cinema))
          :width 'stretch :justify-content 'space-between
          :background-color (etaf-screensaver-color :surface)
          :padding '((lh 0) (ch 2))
      (text :color (etaf-screensaver-color :muted)
            "SPC 播放/暂停 · n 单步 · s/S 场景 · +/- 速度 · TAB 参数 · r 重置 · R 换种子")
      (text :color (etaf-screensaver-color :muted)
            "c 影院 · ? 帮助 · q 关闭"))))

(defun etaf-screensaver-view (session)
  "Return the mounted View for SESSION."
  (etaf-view (etaf-screensaver-shell :session session)))

(provide 'etaf-screensaver-views)
;;; etaf-screensaver-views.el ends here
