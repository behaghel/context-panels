;;; context-panels-footer.el --- Native fixed bottom-view controls -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider-owned actions and optional metadata in a native atomic footer window.
;; Rendering never invokes commands and never owns provider application state.

;;; Code:
(require 'cl-lib)
(require 'button)
(require 'subr-x)

(defvar context-panels-source-buffer)
(defvar context-panels-view-id)
(defvar context-panels-view-navigation-mode-map)
(defvar-local context-panels-footer-spec nil "Current bottom view descriptor.")
(defvar-local context-panels-footer--body-buffer nil "Retained body identity for same-session window restoration.")
(defvar-local context-panels-footer--signature nil "Last native footer presentation.")
(defvar context-panels-footer--resize-timer nil "Deferred footer reflow after native window changes.")
(declare-function context-panels-close-bottom-view "context-panels" ())
(declare-function context-panels-protect-window "context-panels" (window panel-buffer source-buffer))

(defface context-panels-footer-label '((t (:inherit (shadow fixed-pitch) :height 0.9 :underline nil)))
  "Neutral footer action labels." :group 'context-panels)
(defface context-panels-footer-key '((t (:inherit (link fixed-pitch) :height 0.9 :underline nil)))
  "Accented footer key tokens." :group 'context-panels)
(defface context-panels-footer-primary '((t (:inherit (success fixed-pitch) :height 0.9 :underline nil)))
  "Primary footer action." :group 'context-panels)
(defface context-panels-footer-metadata '((t (:inherit (shadow fixed-pitch) :height 0.9 :underline nil)))
  "Secondary provider metadata." :group 'context-panels)

(define-derived-mode context-panels-footer-mode special-mode "Context Footer"
  "Read-only, selectable native controls belonging to a panel body."
  (setq-local mode-line-format nil header-line-format nil tab-line-format nil
	      display-line-numbers nil cursor-type nil truncate-lines t line-spacing 0))

(defun context-panels-footer-window (buffer)
  "Return the current frame's live footer window for visible body BUFFER."
  (cl-loop for body in (get-buffer-window-list buffer nil nil)
	   for footer = (window-parameter body 'context-panels-footer-window)
	   when (window-live-p footer) return footer))

(defun context-panels-footer--invoke (body action)
  "Run explicit ACTION in BODY's real browsing context."
  (unless (window-live-p body) (user-error "This panel is no longer visible"))
  (let ((restore (selected-window)))
    (when (eq (window-parameter restore 'context-panels-footer-body) body) (setq restore body))
    (select-window body 'norecord)
    (unwind-protect
	(call-interactively (plist-get action :command))
      (unless (plist-get action :select)
	(when (window-live-p restore) (select-window restore 'norecord))))))

(defun context-panels-footer--space (pixels role)
  "Insert graphical vertical PIXELS with semantic ROLE, without a font-height row."
  (insert (propertize " " 'display `(space :width (1) :height (,pixels) :ascent 100)
		      'context-panels-footer-role role)
	  (propertize "\n" 'line-height t)))

(defun context-panels-footer--render (body actions metadata)
  "Render ACTIONS and optional METADATA for BODY in the current footer buffer."
  (let* ((footer (window-parameter body 'context-panels-footer-window))
	 (graphic (display-graphic-p (window-frame body)))
	 (columns (max 8 (- (window-body-width footer) 2)))
	 (map (make-sparse-keymap)) (used 0) wrapped line-start
	 (padding (if graphic (propertize " " 'display '(space :width (8))) " ")))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (when graphic (context-panels-footer--space 16 'gap))
      (let ((start (point)))
	(when graphic (context-panels-footer--space 8 'padding))
	(insert padding)
	(setq line-start (point))
	(dolist (action actions)
	  (let* ((key (plist-get action :key))
		 (label (concat key " " (plist-get action :label)))
		 (command (lambda () (interactive) (context-panels-footer--invoke body action))))
	    (when (> (+ used (string-width label) 3) columns)
	      (insert "\n" padding) (setq used 0 wrapped t line-start (point)))
	    (when (> used 0) (insert "   ") (cl-incf used 3))
	    (let ((button-start (point)))
	      (insert-text-button label 'follow-link t
				  'face (if (plist-get action :primary)
					    'context-panels-footer-primary 'context-panels-footer-label)
				  'action (lambda (_button) (funcall command)))
	      (add-face-text-property button-start (+ button-start (length key)) 'context-panels-footer-key))
	    (define-key map (kbd key) command)
	    (cl-incf used (string-width label))))
	(when (and (stringp metadata) (not (string-empty-p metadata)))
	  (let ((text (propertize metadata 'face 'context-panels-footer-metadata
				  'context-panels-footer-role 'metadata)))
	    (if graphic
		(let* ((pixels (string-pixel-width text))
		       (x (max 8 (- (window-body-width footer t) 8 pixels))))
		  (when (or wrapped (> (+ 24 (string-pixel-width (buffer-substring line-start (point)))) x))
		    (insert "\n" padding))
		  (insert (propertize " " 'display `(space :align-to (,x))) text))
	      (when (or wrapped (> (+ used (string-width metadata) 3) columns))
		(insert "\n" padding) (setq used 0))
	      (insert (make-string (max 0 (- columns used (string-width metadata))) ?\s) text))))
	(insert "\n")
	(when graphic (context-panels-footer--space 8 'padding))
	(let ((surface (make-overlay start (point))))
	  (overlay-put surface 'evaporate t)
	  (overlay-put surface 'face
		       (list :background (or (face-background 'mode-line-inactive (window-frame body) t)
					     (face-background 'default (window-frame body) t)) :extend t))))
      (goto-char (point-min)))
    ;; Only this control buffer overrides editing maps.  Ordinary body maps,
    ;; Evil states and minibuffer typing remain untouched; copying text works.
    (set-keymap-parent map
		       (if (boundp 'context-panels-view-navigation-mode-map)
			   (make-composed-keymap context-panels-view-navigation-mode-map special-mode-map)
			 special-mode-map))
    (use-local-map map)
    (setq-local overriding-local-map map)))

(defun context-panels-footer--owned-pair-p (body footer)
  "Return non-nil when BODY and FOOTER are the only children of one group."
  (let ((root (window-parent body)))
    (and root (window-live-p footer)
	 (eq root (window-parent footer))
	 (eq (window-child root) body)
	 (eq (window-next-sibling body) footer)
	 (not (window-next-sibling footer)))))

(defun context-panels-footer-restore-window (body)
  "Rebind BODY to its retained footer after native window-state restoration.
Only an exact owned sibling pair may recover missing window links.  Never
adopt ordinary buffer copies, create windows or run provider actions."
  (when (and (window-live-p body) (window-parameter body 'context-panels-protected))
    (let* ((buffer (window-buffer body))
	   (current (window-parameter body 'context-panels-footer-window))
	   (footer (if (and (window-live-p current)
			    (window-parameter current 'context-panels-protected)
			    (eq (window-parameter current 'context-panels-footer-body) body)
			    (with-current-buffer (window-buffer current)
			      (and (derived-mode-p 'context-panels-footer-mode)
				   (or (null context-panels-footer--body-buffer)
				       (eq context-panels-footer--body-buffer buffer)))))
		       current
		     (let ((candidates
			    (cl-remove-if-not
			     (lambda (window)
			       (and (window-parameter window 'context-panels-protected)
				    (with-current-buffer (window-buffer window)
				      (and (derived-mode-p 'context-panels-footer-mode)
					   (eq context-panels-footer--body-buffer buffer)))))
			     (window-list (window-frame body) 'no-minibuf))))
		       (when candidates
			 (let ((candidate (car candidates)))
			   (unless (and (= (length candidates) 1)
					(context-panels-footer--owned-pair-p body candidate))
			     (user-error "Panel footer layout changed; leaving unrelated windows intact"))
			   candidate))))))
      (when footer
	(with-current-buffer (window-buffer footer) (setq context-panels-footer--body-buffer buffer))
	(set-window-parameter body 'context-panels-footer-window footer)
	(set-window-parameter footer 'context-panels-footer-body body)
	(context-panels-protect-window footer (window-buffer footer)
				       (buffer-local-value 'context-panels-source-buffer buffer))
	(set-window-parameter body 'mode-line-format 'none)
	(set-window-parameter footer 'mode-line-format 'none)
	(set-window-parameter footer 'header-line-format 'none)
	(set-window-parameter footer 'tab-line-format 'none)
	footer))))

(defun context-panels-footer-delete-view (body)
  "Delete BODY and its owned footer together, even without native atom flags.
Never delete a surrounding group containing an unrelated window."
  (let ((footer (context-panels-footer-restore-window body)))
    (if (not (window-live-p footer))
	(delete-window body)
      (let ((root (window-parent body)))
	(unless (and (eq (window-parameter footer 'context-panels-footer-body) body)
		     (context-panels-footer--owned-pair-p body footer))
	  (user-error "Panel footer layout changed; leaving unrelated windows intact"))
	(delete-window root)))))

(defun context-panels-footer--body-killed ()
  "Close owned atomic groups before Emacs replaces a killed body's buffer."
  (dolist (body (get-buffer-window-list (current-buffer) nil t))
    (when-let* ((footer (context-panels-footer-restore-window body)))
      (let ((buffer (window-buffer footer)))
	(context-panels-footer-delete-view body)
	(when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun context-panels-footer--ensure (body)
  "Create BODY's native footer without resizing the overall panel group."
  (or (context-panels-footer-restore-window body)
      (let* ((frame (window-frame body))
	     (buffer (get-buffer-create (format " *Context Footer:%s:%s*" (buffer-name (window-buffer body)) frame)))
	     (side (window-parameter body 'window-side))
	     (slot (window-parameter body 'window-slot))
	     (footer (display-buffer-in-atom-window
		      buffer `((window . ,body) (side . below) (window-height . 2)))))
	(unless footer (error "Cannot create native panel footer"))
	(with-current-buffer (window-buffer body)
	  (add-hook 'kill-buffer-hook #'context-panels-footer--body-killed nil t))
	(with-current-buffer buffer
	  (unless (derived-mode-p 'context-panels-footer-mode) (context-panels-footer-mode))
	  (setq context-panels-footer--body-buffer (window-buffer body)))
	;; The public atomic-window API splits the side leaf.  Preserve the
	;; side classification on its new root and footer as well, so Emacs's
	;; main window remains the source, not an unclassified footer leaf.
	(dolist (window (list footer (window-parent body)))
	  (set-window-parameter window 'window-side side)
	  (set-window-parameter window 'window-slot slot)
	  (set-window-parameter window 'no-delete-other-windows t))
	(context-panels-protect-window footer buffer (window-parameter body 'context-panels-source-buffer))
	(set-window-parameter footer 'context-panels-footer-body body)
	(set-window-parameter body 'context-panels-footer-window footer)
	(set-window-parameter body 'mode-line-format 'none)
	(set-window-parameter footer 'mode-line-format 'none)
	(set-window-parameter footer 'header-line-format 'none)
	(set-window-parameter footer 'tab-line-format 'none)
	(set-window-dedicated-p footer t)
	footer)))

(defun context-panels-footer-update (&optional buffer)
  "Refresh visible body BUFFER's native footers without opening or selecting it."
  (let ((buffer (or buffer (current-buffer))))
    (when (and (buffer-live-p buffer) (buffer-local-value 'context-panels-view-id buffer))
      (dolist (body (cl-remove-if-not
		     (lambda (window) (window-parameter window 'context-panels-protected))
		     (get-buffer-window-list buffer nil t)))
	(let* ((view (buffer-local-value 'context-panels-footer-spec buffer))
	       (data (with-current-buffer buffer
		       (save-excursion
			 (when-let* ((function (plist-get view :footer)))
			   (funcall function context-panels-source-buffer view)))))
	       (actions (plist-get data :actions))
	       (metadata (plist-get data :metadata)))
	  (unless (cl-find "q" actions :test #'equal :key (lambda (action) (plist-get action :key)))
	    (setq actions (append actions '((:key "q" :label "Close" :command context-panels-close-bottom-view :select t)))))
	  (let* ((footer (context-panels-footer--ensure body))
		 (signature (list body actions metadata (window-body-width footer)
				  (frame-char-height (window-frame body))
				  (face-background 'mode-line-inactive (window-frame body) t)
				  (face-background 'default (window-frame body) t))))
	    (with-current-buffer (window-buffer footer)
	      (unless (equal signature context-panels-footer--signature)
		(setq context-panels-footer--signature signature)
		(context-panels-footer--render body actions metadata)
		(let* ((minimum (* 2 (frame-char-height (window-frame body))))
		       (height (max minimum (cdr (window-text-pixel-size footer (point-min) (point-max)))))
		       (delta (- height (window-body-height footer t))))
		  (window-preserve-size footer nil nil)
		  (unless (zerop delta)
		    (let ((window-resize-pixelwise t))
		      (window-resize footer delta nil nil t))))
		(window-preserve-size footer nil t)
		(set-window-start footer (point-min) t)))))))))

(defun context-panels-footer--refresh-visible ()
  "Reflow visible panel footers after the window layout has settled."
  (setq context-panels-footer--resize-timer nil)
  (let (buffers)
    (walk-windows
     (lambda (window)
       (when (and (window-parameter window 'context-panels-protected)
		  (buffer-local-value 'context-panels-view-id (window-buffer window)))
	 (cl-pushnew (window-buffer window) buffers))) nil t)
    (dolist (buffer buffers) (context-panels-footer-update buffer))))

(defun context-panels-footer--resized (_frame)
  "Schedule native footer reflow; never change windows inside a layout hook."
  (when (timerp context-panels-footer--resize-timer) (cancel-timer context-panels-footer--resize-timer))
  (setq context-panels-footer--resize-timer
	(run-with-idle-timer 0.05 nil #'context-panels-footer--refresh-visible)))

(add-hook 'window-size-change-functions #'context-panels-footer--resized)
(add-hook 'enable-theme-functions #'context-panels-footer--resized)

(provide 'context-panels-footer)
;;; context-panels-footer.el ends here
