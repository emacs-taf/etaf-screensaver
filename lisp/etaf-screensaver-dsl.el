;;; etaf-screensaver-dsl.el --- Scene specs, expressions and the canvas -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A scene spec is inert data: a plist of title, parameters and a stack of
;; layers.  This module turns a spec into the callbacks `etaf-screensaver--register'
;; expects, so a new screensaver is a data file, never a new Lisp file.
;;
;; A layer's kind is registered in `etaf-screensaver--layer-kinds' with a
;; VALIDATE, CREATE, STEP, DRAW and optional RESIZE and POINTER function; the
;; built-in kinds live in etaf-screensaver-layers.el and new kinds are an
;; ordinary extension point.  Layer properties may be a literal, a parameter
;; symbol resolved at run time, or an expression in the small pure language
;; evaluated here -- the evaluator never calls `eval'.
;;
;; Expressions hold numbers, strings, `if', `and', `or', `not' and the pure
;; functions below; variables are the scene parameters, the layer's own
;; fields and the globals w, h, cx, cy, t, dt, tick and i.
;;
;; A frame is composed into one canvas: layers draw characters and optional
;; per-cell colors back to front, and adjacent cells with the same color
;; become one text-property run, so a sparse colored layer publishes a few
;; runs instead of one per cell.

;;; Code:

(require 'cl-lib)
(require 'etaf-screensaver-model)

(defvar etaf-screensaver--dsl-random nil
  "Random function returning [0, 1), bound while a spec is evaluated.")

;;; Expressions.

(defun etaf-screensaver--expr-eval (expression environment)
  "Evaluate EXPRESSION in ENVIRONMENT and return its value.
ENVIRONMENT is an alist of symbols to values.  Only the documented pure
functions are callable; an unknown function, variable or form signals
`etaf-screensaver-error'."
  (cond
   ((or (numberp expression) (stringp expression)) expression)
   ((symbolp expression)
    (if (assq expression environment)
        (cdr (assq expression environment))
      (cond ((eq expression t) t)
            ((null expression) nil)
            (t (etaf-screensaver--fail "Unbound scene variable: %s" expression)))))
   ((consp expression)
    (let ((operator (car expression)))
      (pcase operator
        ('if (let ((test (etaf-screensaver--expr-eval (nth 1 expression) environment)))
               (if test
                   (etaf-screensaver--expr-eval (nth 2 expression) environment)
                 (when (nth 3 expression)
                   (etaf-screensaver--expr-eval (nth 3 expression) environment)))))
        ('and (let ((rest (cdr expression))
                    (result t))
                (while (and rest result)
                  (setq result (etaf-screensaver--expr-eval (pop rest) environment)))
                result))
        ('or (let ((rest (cdr expression))
                   (result nil))
               (while (and rest (not result))
                 (setq result (etaf-screensaver--expr-eval (pop rest) environment)))
               result))
        ('not (not (etaf-screensaver--expr-eval (nth 1 expression) environment)))
        (_ (let (arguments)
             (dolist (argument (cdr expression))
               (push (etaf-screensaver--expr-eval argument environment) arguments))
             (etaf-screensaver--expr-call operator (nreverse arguments)))))))
   (t (etaf-screensaver--fail "Invalid scene expression: %S" expression))))

(defun etaf-screensaver--expr-call (function arguments)
  "Call pure FUNCTION on evaluated ARGUMENTS."
  (pcase function
    ('+ (apply #'+ arguments))
    ('- (apply #'- arguments))
    ('* (apply #'* arguments))
    ('/ (if (cdr arguments)
            (apply #'/ (mapcar #'float arguments))
          (/ 1.0 (float (car arguments)))))
    ((or 'mod '%)
     (let ((divisor (cadr arguments)))
       (if (and (numberp divisor) (/= divisor 0))
           (mod (car arguments) divisor)
         (etaf-screensaver--fail "mod needs a nonzero divisor: %S" arguments))))
    ('min (apply #'min arguments))
    ('max (apply #'max arguments))
    ('abs (abs (car arguments)))
    ((or '< '<= '> '>= '=)
     (cl-every (pcase function
                 ('< #'<) ('<= #'<=) ('> #'>) ('>= #'>=) ('= #'=))
               arguments (cdr arguments)))
    ('/= (cl-every (lambda (pair) (/= (car pair) (cadr pair)))
                   (cl-mapcar #'cons arguments (cdr arguments))))
    ('floor (floor (car arguments)))
    ('ceiling (ceiling (car arguments)))
    ('round (round (car arguments)))
    ('float (float (car arguments)))
    ('sqrt (sqrt (float (car arguments))))
    ('sin (sin (car arguments)))
    ('cos (cos (car arguments)))
    ('tan (tan (car arguments)))
    ('pow (expt (car arguments) (cadr arguments)))
    ('clamp (max (cadr arguments) (min (caddr arguments) (car arguments))))
    ('sign (cond ((> (car arguments) 0) 1) ((< (car arguments) 0) -1) (t 0)))
    ('rnd (if arguments
              (* (float (car arguments)) (funcall etaf-screensaver--dsl-random))
            (funcall etaf-screensaver--dsl-random)))
    ('rndi (if arguments
               (floor (* (float (car arguments)) (funcall etaf-screensaver--dsl-random)))
             (if (zerop (funcall etaf-screensaver--dsl-random)) 0 1)))
    (_ (etaf-screensaver--fail "Unknown scene function: %S" function))))

(defun etaf-screensaver--dsl-globals (context)
  "Return the global expression bindings of CONTEXT."
  (list (cons 'w (float (plist-get context :columns)))
        (cons 'h (float (plist-get context :rows)))
        (cons 'cx (/ (plist-get context :columns) 2.0))
        (cons 'cy (/ (plist-get context :rows) 2.0))
        (cons 't (float (or (plist-get context :elapsed) 0.0)))
        (cons 'dt (float (or (plist-get context :dt) 0.0)))
        (cons 'tick (or (plist-get context :tick) 0))
        (cons 'pi float-pi)
        (cons 'e (exp 1.0))))

(defun etaf-screensaver--dsl-params (context)
  "Return the scene parameter bindings of CONTEXT."
  (let ((param (plist-get context :param)))
    (mapcar (lambda (key) (cons key (funcall param key)))
            (plist-get context :params))))

(defun etaf-screensaver--dsl-env (context &optional extras)
  "Return the evaluation environment of CONTEXT merged with EXTRAS.
EXTRAS (layer fields) shadow the scene parameters, which shadow the globals."
  (append extras (etaf-screensaver--dsl-params context)
          (etaf-screensaver--dsl-globals context)))

(defun etaf-screensaver--dsl-value (value environment)
  "Return VALUE resolved against ENVIRONMENT.
A symbol names a binding, a list is an expression and anything else is
returned as it is.  Structured properties (rules, material tables) are read
raw by their layer kind and never go through this function."
  (cond ((null value) nil)
        ((symbolp value)
         (if (assq value environment)
             (cdr (assq value environment))
           (etaf-screensaver--fail "Unbound scene variable: %s" value)))
        ((consp value) (etaf-screensaver--expr-eval value environment))
        (t value)))

;;; Canvas.

(cl-defstruct (etaf-screensaver--canvas (:constructor etaf-screensaver--canvas-new))
  "One frame under composition: characters with per-cell colors.
WIDTH and HEIGHT are the canvas size in cells, CHARS a WIDTH times HEIGHT
character vector, FACES a vector of color strings or nil per cell and COLORED non-nil
once any cell carries a color.  A wide character owns the cell after it,
which holds `etaf-screensaver--canvas-continuation' and never renders."
  width height chars faces colored)

(defconst etaf-screensaver--canvas-continuation ?\uE000
  "Cell marker that belongs to the wide character before it.")

(defun etaf-screensaver--canvas-create (width height)
  "Return a blank WIDTH by HEIGHT canvas."
  (etaf-screensaver--canvas-new :width width :height height
                                :chars (make-vector (* width height) ?\s)
                                :faces (make-vector (* width height) nil)))

(defun etaf-screensaver--canvas-draw (canvas row column character &optional color)
  "Draw CHARACTER at ROW,COLUMN of CANVAS, optionally in COLOR.
Out-of-canvas positions are ignored, so layers need no bounds checks.  A wide
character claims the cell after it so the canvas keeps one character per
display column."
  (let ((width (etaf-screensaver--canvas-width canvas))
        (height (etaf-screensaver--canvas-height canvas)))
    (when (and (>= row 0) (< row height) (>= column 0) (< column width))
      (let* ((index (+ (* row width) column))
             (character (cond ((characterp character) character)
                              ((and (stringp character) (> (length character) 0))
                               (aref character 0))
                              (t ?\s))))
        (aset (etaf-screensaver--canvas-chars canvas) index character)
        (when (and (> (char-width character) 1) (< (1+ column) width))
          (aset (etaf-screensaver--canvas-chars canvas) (1+ index)
                etaf-screensaver--canvas-continuation)
          (aset (etaf-screensaver--canvas-faces canvas) (1+ index) color))
        (when color
          (aset (etaf-screensaver--canvas-faces canvas) index color)
          (setf (etaf-screensaver--canvas-colored canvas) t))))))

(defun etaf-screensaver--canvas-draw-text (canvas row column text &optional color)
  "Draw TEXT at ROW,COLUMN of CANVAS, optionally in COLOR."
  (let ((cell column))
    (dotimes (index (length text))
      (let ((character (aref text index)))
        (etaf-screensaver--canvas-draw canvas row cell character color)
        (cl-incf cell (char-width character))))))

(defun etaf-screensaver--canvas-run-string (run run-face run-color)
  "Return RUN's text with RUN-FACE applied when it was set."
  (let ((text (apply #'concat (nreverse run))))
    (if (eq run-face :unset)
        text
      (propertize text 'face (list :foreground run-color)))))

(defun etaf-screensaver--canvas-row (canvas row)
  "Return ROW of CANVAS as one string with merged color runs."
  (let* ((width (etaf-screensaver--canvas-width canvas))
         (chars (etaf-screensaver--canvas-chars canvas))
         (faces (etaf-screensaver--canvas-faces canvas))
         (start (* row width))
         (end (+ start width)))
    (if (not (cl-position etaf-screensaver--canvas-continuation chars
                          :start start :end end))
        (if (not (etaf-screensaver--canvas-colored canvas))
            (concat (substring chars start end))
          (let ((column 0)
                (parts nil))
            (while (< column width)
              (let ((face (aref faces (+ start column)))
                    (run-start column))
                (while (and (< column width)
                            (equal face (aref faces (+ start column))))
                  (cl-incf column))
                (let ((text (concat (substring chars (+ start run-start) (+ start column)))))
                  (push (if face
                            (propertize text 'face (list :foreground face))
                          text)
                        parts))))
            (apply #'concat (nreverse parts))))
      ;; A wide character owns the cell after it; build the row cell by cell
      ;; and drop the continuation cells from the output.
      (let ((column 0)
            (parts nil)
            (run nil)
            (run-face :unset)
            (run-color nil))
        (while (< column width)
          (let* ((index (+ start column))
                 (character (aref chars index))
                 (face (aref faces index)))
            (if (eq character etaf-screensaver--canvas-continuation)
                (progn
                  (when run
                    (push (etaf-screensaver--canvas-run-string run run-face run-color)
                          parts)
                    (setq run nil run-face :unset run-color nil))
                  (cl-incf column))
              (progn
                (unless (equal (and (not (eq run-face :unset)) run-color) face)
                  (when run
                    (push (etaf-screensaver--canvas-run-string run run-face run-color)
                          parts))
                  (setq run nil run-face face run-color face))
                (push (string character) run)
                (cl-incf column)))))
        (when run
          (push (etaf-screensaver--canvas-run-string run run-face run-color) parts))
        (apply #'concat (nreverse parts))))))

(defun etaf-screensaver--canvas-compose (canvas)
  "Return CANVAS as a list of row strings with merged color runs."
  (cl-loop for row below (etaf-screensaver--canvas-height canvas)
           collect (etaf-screensaver--canvas-row canvas row)))

;;; Layer helpers.

(defun etaf-screensaver--layer-property (layer key default)
  "Return LAYER's KEY when present, else DEFAULT."
  (if (plist-member layer key) (plist-get layer key) default))

(defun etaf-screensaver--layer-number (value environment default)
  "Resolve VALUE in ENVIRONMENT to a number, or return DEFAULT."
  (let ((resolved (etaf-screensaver--dsl-value value environment)))
    (cond ((null resolved) default)
          ((numberp resolved) resolved)
          (t (or (ignore-errors (float resolved)) default)))))

(defun etaf-screensaver--layer-char (value environment default)
  "Resolve VALUE in ENVIRONMENT to a display character, or return DEFAULT."
  (let ((resolved (etaf-screensaver--dsl-value value environment)))
    (cond ((null resolved) default)
          ((characterp resolved) resolved)
          ((and (stringp resolved) (> (length resolved) 0)) (aref resolved 0))
          (t default))))

(defun etaf-screensaver--layer-ramp-char (ramp intensity)
  "Return the character of RAMP at clamped INTENSITY between 0 and 1."
  (when (and (stringp ramp) (> (length ramp) 0))
    (aref ramp (min (1- (length ramp)) (floor (* intensity (length ramp)))))))

(defun etaf-screensaver--layer-palette-color (palette intensity)
  "Return the color of PALETTE at clamped INTENSITY between 0 and 1."
  (when (and (proper-list-p palette) palette)
    (nth (min (1- (length palette)) (floor (* intensity (length palette)))) palette)))

(defun etaf-screensaver--layer-clamp (value low high)
  "Clamp VALUE into LOW..HIGH."
  (max low (min high value)))

;;; Layer kinds.

(defvar etaf-screensaver--layer-kinds nil
  "Registered layer kinds as (KIND . PLIST) pairs.
PLIST holds :validate, :create, :step, :draw and optional :resize
functions; see etaf-screensaver-layers.el for the contract.")

(defun etaf-screensaver--define-layer-kind (kind &rest properties)
  "Register a layer KIND with PROPERTIES and return its plist.
Re-registering a kind replaces it in place."
  (unless (symbolp kind)
    (etaf-screensaver--fail "Layer kind must be a symbol: %S" kind))
  (setf etaf-screensaver--layer-kinds
        (cons (cons kind properties)
              (assq-delete-all kind etaf-screensaver--layer-kinds)))
  properties)

(defun etaf-screensaver--layer-kind (kind)
  "Return the registered plist for layer KIND."
  (or (cdr (assq kind etaf-screensaver--layer-kinds))
      (etaf-screensaver--fail "Unknown scene layer kind: %S" kind)))

(defun etaf-screensaver--layer-function (kind key)
  "Return KIND's function for KEY, or nil."
  (plist-get (etaf-screensaver--layer-kind kind) key))

;;; Specs.

(defconst etaf-screensaver--spec-keys
  '(:id :title :summary :tags :frame-rate :background :params :layers)
  "Keys accepted in a scene spec.")

(defun etaf-screensaver--spec-validate (spec)
  "Validate scene spec SPEC and return it.
Signal `etaf-screensaver-error' with the offending key when the spec cannot
be interpreted."
  (unless (proper-list-p spec)
    (etaf-screensaver--fail "Scene spec must be a plist: %S" spec))
  (let ((plist spec))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--spec-keys)
          (etaf-screensaver--fail "Scene spec has unknown key %S" key)))))
  (let ((id (plist-get spec :id))
        (layers (plist-get spec :layers))
        (frame-rate (plist-get spec :frame-rate)))
    (unless (symbolp id)
      (etaf-screensaver--fail "Scene spec needs a symbol :id: %S" id))
    (when (and frame-rate (not (and (numberp frame-rate) (> frame-rate 0))))
      (etaf-screensaver--fail "Scene %s :frame-rate must be a positive number" id))
    (unless (and (proper-list-p layers) layers)
      (etaf-screensaver--fail "Scene %s needs at least one :layer" id))
    (dolist (layer layers)
      (unless (proper-list-p layer)
        (etaf-screensaver--fail "Scene %s layer must be a plist: %S" id layer))
      (let* ((kind (plist-get layer :kind))
             (contract (etaf-screensaver--layer-kind kind))
             (validate (plist-get contract :validate)))
        (when validate (funcall validate layer))))
    spec))

(defun etaf-screensaver--spec-scene (spec)
  "Interpret SPEC into the properties `etaf-screensaver--register' takes."
  (let ((layers (plist-get spec :layers)))
    (list :title (plist-get spec :title)
          :summary (plist-get spec :summary)
          :tags (plist-get spec :tags)
          :frame-rate (plist-get spec :frame-rate)
          :background (plist-get spec :background)
          :params (plist-get spec :params)
          :create
          (lambda (context)
            (let ((etaf-screensaver--dsl-random (plist-get context :random)))
              (list :layers
                    (mapcar (lambda (layer)
                              (cons layer
                                    (when-let* ((create (etaf-screensaver--layer-function
                                                         (plist-get layer :kind) :create)))
                                      (funcall create layer context))))
                            layers))))
          :step
          (lambda (state context)
            (let ((etaf-screensaver--dsl-random (plist-get context :random)))
              (dolist (entry (plist-get state :layers))
                (when-let* ((step (etaf-screensaver--layer-function
                                   (plist-get (car entry) :kind) :step)))
                  (funcall step (car entry) (cdr entry) context)))))
          :render
          (lambda (state context)
            (let ((etaf-screensaver--dsl-random (plist-get context :random))
                  (canvas (etaf-screensaver--canvas-create
                           (plist-get context :columns)
                           (plist-get context :rows))))
              (dolist (entry (plist-get state :layers))
                (when-let* ((draw (etaf-screensaver--layer-function
                                   (plist-get (car entry) :kind) :draw)))
                  (funcall draw (car entry) (cdr entry) context canvas)))
              (etaf-screensaver--canvas-compose canvas)))
          :resize
          (lambda (state context)
            (let ((etaf-screensaver--dsl-random (plist-get context :random)))
              (dolist (entry (plist-get state :layers))
                (let* ((kind (plist-get (car entry) :kind))
                       (resize (etaf-screensaver--layer-function kind :resize))
                       (create (etaf-screensaver--layer-function kind :create)))
                  (setcdr entry (if resize
                                    (funcall resize (car entry) (cdr entry) context)
                                  (when create (funcall create (car entry) context)))))))
            state))))

(defun etaf-screensaver-register-scene (spec)
  "Register the scene described by SPEC and return the scene.
SPEC is a plist with :id, :title, :summary, :tags, :frame-rate, :background,
:params and :layers; a file may wrap the same plist in `(etaf-scene ...)'.
Layers are interpreted by the generic kind registry, so a scene is data and
needs no Lisp of its own.  Registering the same :id again replaces the
previous scene in place."
  (let ((spec (if (eq (car-safe spec) 'etaf-scene) (cdr spec) spec)))
    (etaf-screensaver--spec-validate spec)
    (etaf-screensaver--register (plist-get spec :id)
                                (etaf-screensaver--spec-scene spec))))

(provide 'etaf-screensaver-dsl)
;;; etaf-screensaver-dsl.el ends here
