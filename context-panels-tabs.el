;;; context-panels-tabs.el --- Native provider view tabs -*- lexical-binding: t; -*-

;;; Commentary:
;; Native tab-line rendering reads a retained registry snapshot.  Only explicit
;; selection resolves a fresh provider key and opens a view.  No preview engine.

;;; Code:
(require 'cl-lib)
(require 'tab-line)
(require 'subr-x)
(defvar context-panels-source-buffer)
(defvar context-panels-view-key)
(defvar context-panels-view-id)
(defvar context-panels--desired-bottom-view-id)
(declare-function context-panels--source-buffer "context-panels" ())
(declare-function context-panels--bottom-view-descriptors "context-panels" (source))
(declare-function context-panels--bottom-view-label "context-panels" (view))
(declare-function context-panels--bottom-view-buffer-name "context-panels" (view))
(declare-function context-panels--visible-bottom-panel-window "context-panels" ())
(declare-function context-panels--docked-views "context-panels" (&optional frame))
(declare-function context-panels-open-bottom-view "context-panels" (id &optional source select))
(declare-function context-panels-open-docked-view "context-panels" (buffer &optional select))
(declare-function context-panels-next-bottom-view "context-panels" (&optional source))
(declare-function context-panels-previous-bottom-view "context-panels" (&optional source))
(declare-function context-panels-select-bottom-view "context-panels" (&optional source))

(defface context-panels-tab-current '((t (:inherit (success hl-line fixed-pitch) :height 0.95 :weight semibold :box nil :underline nil :extend nil)))
  "Selected provider view, independent of keyboard focus." :group 'context-panels)
(defface context-panels-tab-inactive '((t (:inherit (shadow fixed-pitch) :height 0.95 :box nil :underline nil)))
  "Quiet unselected provider view." :group 'context-panels)
(defface context-panels-tab-chooser '((t (:inherit (link fixed-pitch) :height 0.85 :box nil :underline nil)))
  "Native named-view chooser affordance." :group 'context-panels)

(defun context-panels-tabs--body ()
  "Return the selected managed body, including selection in its footer."
  (let* ((window (selected-window))
	 (body (or (window-parameter window 'context-panels-footer-body) window)))
    (when (and (window-live-p body) (window-parameter body 'context-panels-protected)
	       (buffer-local-value 'context-panels-view-id (window-buffer body))) body)))

(defun context-panels-tabs--key-filter (command)
  "Enable COMMAND only while a managed panel window owns keyboard focus."
  (when (context-panels-tabs--body) command))

(defvar context-panels-view-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (entry '(("C-<tab>" . context-panels-next-bottom-view)
		     ("C-S-<tab>" . context-panels-previous-bottom-view)
		     ("C-c v" . context-panels-select-bottom-view)))
      (define-key map (kbd (car entry))
		  `(menu-item "" ,(cdr entry) :filter context-panels-tabs--key-filter)))
    map)
  "Panel-scoped navigation; bindings remain customizable without global changes.")

(define-minor-mode context-panels-view-navigation-mode
  "Enable filtered provider-view navigation in this panel buffer."
  :lighter nil :keymap context-panels-view-navigation-mode-map)

(defun context-panels-tabs--source (&optional source)
  "Resolve SOURCE or the selected panel's source without initializing a provider."
  (or source
      (if-let* ((body (context-panels-tabs--body)))
	  (let ((owner (buffer-local-value 'context-panels-source-buffer (window-buffer body))))
	    (when (buffer-live-p owner) owner))
	(context-panels--source-buffer))))

(defun context-panels-tabs--key (view)
  "Return VIEW's canonical provider/view key, not its display label."
  (or (plist-get view :context-panels-view-key)
      (cons (plist-get view :provider) (plist-get view :id))))

(defun context-panels-tabs--views (source &optional frame)
  "Collect SOURCE views and FRAME's live docks, defaulting to this frame."
  (let ((views (when (buffer-live-p source) (context-panels--bottom-view-descriptors source))))
    (dolist (entry (context-panels--docked-views frame))
      (let ((view (copy-sequence (plist-get entry :view))))
	(unless (cl-find (context-panels-tabs--key view) views :test #'equal :key #'context-panels-tabs--key)
	  (setq views (append views (list (plist-put
					   (plist-put view :navigation-dock (plist-get entry :buffer))
					   :buffer (plist-get entry :buffer))))))))
    views))

(defun context-panels-tabs--label (view views)
  "Disambiguate VIEW's label in VIEWS without using it as identity."
  (let ((label (replace-regexp-in-string "[[:cntrl:]]+" " " (context-panels--bottom-view-label view))))
    (if (> (cl-count label views :test #'equal :key #'context-panels--bottom-view-label) 1)
	(format "%s · %s" label (plist-get view :provider)) label)))

(defun context-panels-tabs--remember (window)
  "Retain WINDOW's view point and scrolling in its frame, never provider state."
  (when (window-live-p window)
    (let ((frame (window-frame window)) (buffer (window-buffer window)))
      (set-frame-parameter
       frame 'context-panels-view-positions
       (cons (cons buffer (cons (window-point window) (window-start window)))
	     (assq-delete-all buffer (frame-parameter frame 'context-panels-view-positions)))))))

(defun context-panels-tabs-select (key &optional source)
  "Explicitly select fresh provider/view KEY for SOURCE without previewing it."
  (let* ((body (context-panels-tabs--body))
	 (source (context-panels-tabs--source source))
	 (views (context-panels-tabs--views source))
	 (view (cl-find key views :test #'equal :key #'context-panels-tabs--key))
	 (existing (and view (or (plist-get view :buffer)
				 (get-buffer (context-panels--bottom-view-buffer-name view)))))
	 (position (and (buffer-live-p existing)
			(or (cdr (assq existing (frame-parameter nil 'context-panels-view-positions)))
			    (with-current-buffer existing (cons (point) nil))))))
    (unless view (user-error "This provider view is no longer available"))
    (context-panels-tabs--remember (or body (context-panels--visible-bottom-panel-window)))
    (let* ((buffer (if-let* ((dock (plist-get view :navigation-dock)))
		       (context-panels-open-docked-view dock (and body t))
		     (context-panels-open-bottom-view key source (and body t))))
	   (window (let ((visible (context-panels--visible-bottom-panel-window)))
		     (when (and visible (eq (window-buffer visible) buffer)) visible))))
      (when (and position window)
	(with-current-buffer buffer
	  (let ((point (max (point-min) (min (point-max) (car position)))))
	    (goto-char point) (set-window-point window point)
	    (when (cdr position)
	      (set-window-start window (max (point-min) (min (point-max) (cdr position))) t)))))
      buffer)))

(defun context-panels-tabs-cycle (offset &optional source)
  "Move OFFSET views within SOURCE's available provider views."
  (let* ((source (context-panels-tabs--source source))
	 (views (context-panels-tabs--views source))
	 (body (or (context-panels-tabs--body) (context-panels--visible-bottom-panel-window)))
	 (key (if body (buffer-local-value 'context-panels-view-key (window-buffer body))
		context-panels--desired-bottom-view-id))
	 (index (or (cl-position key views :test #'equal :key #'context-panels-tabs--key)
		    (if (> offset 0) -1 0))))
    (unless views (user-error "No context bottom views"))
    (context-panels-tabs-select (context-panels-tabs--key (nth (mod (+ index offset) (length views)) views)) source)))

(defun context-panels-tabs-choose (&optional source)
  "Choose a SOURCE view through passive native completion, including Vertico."
  (let* ((source (context-panels-tabs--source source))
	 (views (context-panels-tabs--views source))
	 (choices (mapcar (lambda (view) (cons (context-panels-tabs--label view views)
					       (context-panels-tabs--key view))) views)))
    (unless choices (user-error "No context bottom views"))
    (let* ((table (lambda (string predicate action)
		    (if (eq action 'metadata)
			'(metadata (category . context-panels-view) (display-sort-function . identity))
		      (complete-with-action action choices string predicate))))
	   (choice (completing-read "Panel view: " table nil t)))
      (when-let* ((key (cdr (assoc choice choices)))) (context-panels-tabs-select key source)))))

(defun context-panels-tabs--face (tab _tabs _face _buffer-p selected-p)
  "Return the shared native TAB face for SELECTED-P without global styling."
  (cond ((assq 'chooser tab) 'context-panels-tab-chooser)
	(selected-p 'context-panels-tab-current) (t 'context-panels-tab-inactive)))

(defun context-panels-tabs-format ()
  "Format cached provider tabs using Emacs's native tab-line overflow behavior."
  (when-let* ((tabs (window-parameter nil 'context-panels-tabs)))
    (let ((tab-line-tabs-function (lambda () tabs))
	  (tab-line-new-button-show nil) (tab-line-close-button-show nil)
	  (tab-line-tab-face-functions '(context-panels-tabs--face))
	  (tab-line-cache-key-function
	   (lambda (items) (append (tab-line-cache-key-default items) (list (window-body-width nil t))))))
      (cl-loop for tail on (tab-line-format)
	       for part = (car tail)
	       for position = (and (stringp part)
				   (text-property-not-all 0 (length part) 'tab nil part))
	       for tab = (and position (get-text-property position 'tab part))
	       if (alist-get 'chooser tab)
	       append (let ((label (copy-sequence (apply #'concat (cl-remove-if-not #'stringp tail)))))
			;; Match the native tab line's base face when measuring.
			(add-face-text-property 0 (length label) 'tab-line t label)
			(list (propertize " " 'context-panels-chooser-alignment t
					  'display `(space :align-to (- right-fringe (,(string-pixel-width label)))))
			      part))
	       else collect part))))

(defun context-panels-tabs-update (window)
  "Retain all provider tabs for managed body WINDOW without painting a view."
  (when (and (window-live-p window) (window-parameter window 'context-panels-protected))
    (with-current-buffer (window-buffer window)
      (when context-panels-view-id
	(context-panels-view-navigation-mode 1)
	(let* ((source (when (buffer-live-p context-panels-source-buffer) context-panels-source-buffer))
	       (views (context-panels-tabs--views source (window-frame window)))
	       (current context-panels-view-key)
	       (tabs (mapcar
		      (lambda (view)
			(let ((key (context-panels-tabs--key view)))
			  (list (cons 'name (concat " " (context-panels-tabs--label view views) " "))
				(cons 'selected (equal key current))
				(cons 'context-panels-view-key key)
				(cons 'select (lambda () (context-panels-tabs-select key source)))))) views)))
	  (setq tabs (append tabs (list (list '(name . " Views · C-c v ") '(chooser . t)
					      (cons 'select (lambda () (context-panels-tabs-choose source)))))))
	  (set-window-parameter window 'context-panels-tabs tabs)
	  (set-window-parameter window 'tab-line-cache nil)
	  (set-window-parameter window 'tab-line-format '((:eval (context-panels-tabs-format)))))))))

(defun context-panels-tabs-registry-changed (source)
  "Refresh cached tabs in visible views belonging to SOURCE after registry edits."
  (walk-windows (lambda (window)
		  (when (eq source (buffer-local-value 'context-panels-source-buffer (window-buffer window)))
		    (context-panels-tabs-update window))) nil t))

(provide 'context-panels-tabs)
;;; context-panels-tabs.el ends here
