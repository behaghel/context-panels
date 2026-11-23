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
(defvar-local context-panels-footer--pane-buffer nil "Explicitly owned auxiliary buffer for this body, if any.")
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

(defun context-panels-footer--align-actions (rows metadata padding footer columns graphic)
  "Align shortcut ROWS right, with METADATA leading the first row.
PADDING, FOOTER, COLUMNS and GRAPHIC describe the current footer layout."
  (let ((first (car (last rows))))
    (save-excursion
      ;; Visit bottom to top so inserting a gap does not invalidate earlier rows.
      (dolist (start rows)
        (goto-char start)
        (let* ((actions (buffer-substring start (line-end-position)))
               (leading (and (= start first) metadata))
               (gap (if graphic
                        (- (window-body-width footer t) 8 (string-pixel-width actions))
                      (- columns (string-width actions)))))
          (when leading
            (insert leading)
            (when (if graphic (> (+ 32 (string-pixel-width leading)) gap)
                    (> (+ 3 (string-width leading)) gap))
              (insert "\n" padding)
              (setq leading nil)))
          (if graphic
              (insert (propertize " " 'display `(space :align-to (,(max 8 gap)))))
            (insert (make-string (max 0 (- gap (if leading (string-width leading) 0))) ?\s))))))))

(defun context-panels-footer--render (body actions metadata &optional metadata-leading)
  "Render ACTIONS and METADATA for BODY, optionally with METADATA-LEADING."
  (let* ((footer (window-parameter body 'context-panels-footer-window))
	 (graphic (display-graphic-p (window-frame body)))
	 (columns (max 8 (- (window-body-width footer) 2)))
	 (map (make-sparse-keymap)) (used 0) wrapped line-start rows
	 (padding (if graphic (propertize " " 'display '(space :width (8))) " ")))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (when graphic (context-panels-footer--space 16 'gap))
      (let ((start (point)))
	(when graphic (context-panels-footer--space 8 'padding))
	(insert padding)
	(setq line-start (point))
        (push line-start rows)
	(dolist (action actions)
	  (let* ((key (plist-get action :key))
		 (label (concat key " " (plist-get action :label)))
		 (command (lambda () (interactive) (context-panels-footer--invoke body action))))
	    (when (> (+ used (string-width label) 3) columns)
	      (insert "\n" padding) (setq used 0 wrapped t line-start (point))
              (push line-start rows))
	    (when (> used 0) (insert "   ") (cl-incf used 3))
	    (let ((button-start (point)))
	      (insert-text-button label 'follow-link t
				  'face (if (plist-get action :primary)
					    'context-panels-footer-primary 'context-panels-footer-label)
				  'action (lambda (_button) (funcall command)))
	      (add-face-text-property button-start (+ button-start (length key)) 'context-panels-footer-key))
	    (define-key map (kbd key) command)
	    (cl-incf used (string-width label))))
	(let ((text (and (stringp metadata) (not (string-empty-p metadata))
                         (propertize metadata 'face 'context-panels-footer-metadata
                                    'context-panels-footer-role 'metadata))))
          (cond
           (metadata-leading (context-panels-footer--align-actions rows text padding footer columns graphic))
           (text
	    (if graphic
		(let* ((pixels (string-pixel-width text))
		       (x (max 8 (- (window-body-width footer t) 8 pixels))))
		  (when (or wrapped (> (+ 24 (string-pixel-width (buffer-substring line-start (point)))) x))
		    (insert "\n" padding))
		  (insert (propertize " " 'display `(space :align-to (,x))) text))
	      (when (or wrapped (> (+ used (string-width metadata) 3) columns))
		(insert "\n" padding) (setq used 0))
	      (insert (make-string (max 0 (- columns used (string-width metadata))) ?\s) text)))))
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

(defvar-local context-panels-footer--lateral-buffer nil
  "Retained identity of the independently scrollable pane beside the body.")

(declare-function context-panels-tabs-update "context-panels-tabs" (window))
(declare-function context-panels-view-navigation-mode "context-panels-tabs" (&optional arg))

(defvar-local context-panels-footer--tabs-buffer nil
  "Retained identity of the full-width tab row.")

(defun context-panels-footer--owned-leaf-p (window buffer)
  "Whether WINDOW is a protected leaf displaying BUFFER."
  (and (window-live-p window) (window-parameter window 'context-panels-protected)
       (eq (window-buffer window) buffer)))

(defun context-panels-footer--body-column (body root)
  "Return BODY or its declared input stack within ROOT."
  (let ((parent (window-parent body)) (input (window-next-sibling body)))
    (if (and parent (not (eq parent root)) (eq body (window-top-child parent))
             (context-panels-footer--owned-leaf-p
              input (buffer-local-value 'context-panels-footer--pane-buffer (window-buffer body)))
             (not (window-next-sibling input))) parent body)))

(defun context-panels-footer--body-row (body root)
  "Return BODY or its exactly owned composition inside ROOT."
  (let* ((column (context-panels-footer--body-column body root))
         (row (window-parent column))
         (peer (window-next-sibling column)))
    (cond
     ((eq row root) column)
     ((and row (eq (window-parent row) root) (eq (window-left-child row) column)
           (context-panels-footer--owned-leaf-p
            peer (buffer-local-value 'context-panels-footer--lateral-buffer (window-buffer body)))
           (not (window-next-sibling peer))) row))))

(defun context-panels-footer--tab-host (body)
  "Return BODY's validated full-width tab host, if any."
  (when-let* ((buffer (buffer-local-value 'context-panels-footer--tabs-buffer (window-buffer body)))
              ((buffer-live-p buffer))
              (footer (context-panels-footer-restore-window body))
              (root (window-parent footer))
              (row (context-panels-footer--body-row body root))
              (top (window-child root)))
    (when (and (eq (window-next-sibling top) row)
               (context-panels-footer--owned-leaf-p
                top buffer))
      (set-window-parameter top 'context-panels-footer-body body)
      top)))

(defun context-panels-footer--owned-view-root (body footer)
  "Return the exact owned BODY/FOOTER group and its declared panes.
Any unregistered or additional window makes the surrounding group unowned."
  (when (and (window-live-p body) (window-live-p footer))
    (let* ((root (window-parent footer))
           (row (and root (context-panels-footer--body-row body root)))
	   (next (and row (window-next-sibling row)))
	   (pane-buffer (buffer-local-value 'context-panels-footer--pane-buffer
					    (window-buffer body))))
      (when (and row
                 (or (eq (window-child root) row)
                     (let ((top (window-child root)))
                       (and (eq (window-next-sibling top) row)
                            (context-panels-footer--owned-leaf-p top
                             (buffer-local-value 'context-panels-footer--tabs-buffer (window-buffer body))))))
		 (not (window-next-sibling footer))
		 (or (eq next footer)
		     (and (window-live-p next)
			  (eq (window-next-sibling next) footer)
			  (window-parameter next 'context-panels-protected)
			  (eq (window-buffer next) pane-buffer))))
	root))))

(defun context-panels-footer--rearrange (root function)
  "Apply FUNCTION inside ROOT, restoring Emacs's direct-child side flags."
  (let ((side (window-parameter root 'window-side))
        (slot (window-parameter root 'window-slot))
        (ignore-window-parameters t))
    (unwind-protect
        (progn
          (walk-window-subtree (lambda (part) (set-window-parameter part 'window-side nil)) root t)
          (funcall function))
      (walk-window-subtree
       (lambda (part)
         (set-window-parameter part 'window-side
                               (and (or (eq part root) (eq (window-parent part) root)) side))
         (set-window-parameter part 'window-slot slot)
         (set-window-parameter part 'window-atom t)
         (set-window-parameter part 'no-delete-other-windows t)) root t))))

(defun context-panels-footer-display-pane (body buffer height)
  "Display owned BUFFER below BODY, above its footer, initially HEIGHT lines.
Reuse the existing pane when present.  Closing the view closes its windows,
not BUFFER; the provider retains its text.  Unrelated windows are never adopted."
  (unless (buffer-live-p buffer) (user-error "Owned pane buffer is not live"))
  (let* ((footer (context-panels-footer-restore-window body))
	 (root (and footer (context-panels-footer--owned-view-root body footer)))
	 (source (and (window-live-p body)
		      (buffer-local-value 'context-panels-source-buffer (window-buffer body))))
         (row (and root (context-panels-footer--body-row body root)))
         (next (and row (window-next-sibling body)))
         (pane (and (context-panels-footer--owned-leaf-p
                     next (buffer-local-value 'context-panels-footer--pane-buffer (window-buffer body))) next)))
    (unless root (user-error "Cannot add a pane to an unowned panel layout"))
    (when (memq buffer (list (window-buffer body) (window-buffer footer)))
      (user-error "An owned pane must have its own buffer"))
    (unless (window-live-p pane)
      (let ((dedicated (window-dedicated-p body)))
        (context-panels-footer--rearrange
         root (lambda ()
                (unwind-protect
                    (progn
                      (set-window-dedicated-p body nil)
                      (let ((window-combination-limit nil))
                        (setq pane (split-window body (- height) 'below))))
                  (set-window-dedicated-p body dedicated)))))
      (unless (window-live-p pane) (error "Unable to display the owned panel pane")))
    (unless (eq (window-buffer pane) buffer)
      (set-window-parameter pane 'context-panels-panel-buffer buffer)
      (set-window-dedicated-p pane nil)
      (set-window-buffer pane buffer))
    (with-current-buffer (window-buffer body) (setq context-panels-footer--pane-buffer buffer))
    (with-current-buffer buffer (setq-local context-panels-source-buffer source))
    (context-panels-protect-window pane buffer source)
    (window-preserve-size pane nil t)
    pane))

(defun context-panels-footer-display-lateral-pane (body buffer width)
  "Display owned BUFFER to the right of BODY, WIDTH columns wide.
The input ends at the same edge as BODY; tabs and footer span both columns.
Return nil when WIDTH would leave too little room.
Never adopt unrelated windows."
  (unless (buffer-live-p buffer) (user-error "Owned lateral buffer is not live"))
  (unless (and (integerp width) (>= width 2)) (user-error "Invalid lateral pane width"))
  (let* ((footer (context-panels-footer-restore-window body))
         (root (and footer (context-panels-footer--owned-view-root body footer)))
         (row (and root (context-panels-footer--body-row body root)))
         (column (and row (context-panels-footer--body-column body root)))
         (rail (and column (not (eq row column)) (window-next-sibling column)))
         (next (window-next-sibling body))
         (input (and (context-panels-footer--owned-leaf-p
                      next (buffer-local-value 'context-panels-footer--pane-buffer (window-buffer body))) next)))
    (unless root (user-error "Cannot add a lateral pane to an unowned panel layout"))
    (when (memq buffer (mapcar #'window-buffer (delq nil (list body input footer))))
      (user-error "An owned lateral pane must have its own buffer"))
    (when (and (not rail) (>= (- (window-total-width body) width) window-min-width)
               (> (window-total-height body) 3))
      (let* ((dedicated (window-dedicated-p body))
             (replace-input (and input (eq column body)))
             (input-buffer (and replace-input (window-buffer input)))
             (input-height (and replace-input (window-total-height input)))
             (input-selected (eq input (selected-window)))
             top)
        (context-panels-footer--rearrange
         root (lambda ()
                (unwind-protect
                    (progn
                      (when replace-input (delete-window input))
                      (set-window-dedicated-p body nil)
                      (let ((window-combination-limit nil))
                        (setq rail (split-window column (- width) 'right))
                        (setq top (split-window (window-parent rail) -2 'above))))
                  (set-window-dedicated-p body dedicated))))
        (let* ((host (with-current-buffer (window-buffer body)
                       (unless (buffer-live-p context-panels-footer--tabs-buffer)
                         (setq context-panels-footer--tabs-buffer (generate-new-buffer " *Context Panel Tabs*"))
                         (with-current-buffer context-panels-footer--tabs-buffer
                           (setq buffer-read-only t)
                           (context-panels-view-navigation-mode 1)))
                       (setq context-panels-footer--lateral-buffer buffer)
                       context-panels-footer--tabs-buffer))
               (source (buffer-local-value 'context-panels-source-buffer (window-buffer body))))
          (set-window-dedicated-p top nil)
          (set-window-buffer top host)
          (dolist (key '(mode-line-format header-line-format)) (set-window-parameter top key 'none))
          (context-panels-protect-window top host source)
          (set-window-dedicated-p rail nil)
          (set-window-buffer rail buffer)
          (context-panels-protect-window rail buffer source)
          (window-preserve-size top nil t)
          (when input-buffer
            (let ((new-input (context-panels-footer-display-pane body input-buffer input-height)))
              (when input-selected (select-window new-input))))
          (context-panels-tabs-update body))))
    (when (window-live-p rail)
      (unless (eq buffer (window-buffer rail))
        (set-window-dedicated-p rail nil)
        (set-window-buffer rail buffer))
      (let ((source (buffer-local-value 'context-panels-source-buffer (window-buffer body))))
        (with-current-buffer (window-buffer body) (setq context-panels-footer--lateral-buffer buffer))
        (with-current-buffer buffer (setq-local context-panels-source-buffer source))
        (context-panels-protect-window rail buffer source))
      (window-preserve-size rail t t)
      rail)))

(defun context-panels-footer-hide-lateral-pane (body)
  "Remove BODY's owned lateral pane without deleting its buffer or view."
  (when-let* ((footer (context-panels-footer-restore-window body))
              (root (context-panels-footer--owned-view-root body footer))
              (row (context-panels-footer--body-row body root)))
    (let* ((column (context-panels-footer--body-column body root))
           (rail (and (not (eq row column)) (window-next-sibling column)))
           (top (context-panels-footer--tab-host body)))
      (when (window-live-p rail)
        (context-panels-footer--rearrange
         root (lambda ()
                (when (window-live-p top) (delete-window top))
                (delete-window rail)))
        (context-panels-tabs-update body)))))

(defun context-panels-footer-restore-window (body)
  "Rebind BODY to its retained footer after native window-state restoration.
Only an exact owned group may recover missing window links.  Never
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
					(context-panels-footer--owned-view-root body candidate))
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
  "Delete BODY, its declared pane and footer, even without native atom flags.
Never delete a surrounding group containing an unrelated window."
  (let ((footer (context-panels-footer-restore-window body)))
    (if (not (window-live-p footer))
	(delete-window body)
      (let ((root (context-panels-footer--owned-view-root body footer)))
	(unless (and root (eq (window-parameter footer 'context-panels-footer-body) body))
	  (user-error "Panel footer layout changed; leaving unrelated windows intact"))
	(delete-window root)))))

(defun context-panels-footer--body-killed ()
  "Close owned atomic groups before Emacs replaces a killed body's buffer."
  (dolist (body (get-buffer-window-list (current-buffer) nil t))
    (when-let* ((footer (context-panels-footer-restore-window body)))
      (let ((buffer (window-buffer footer)))
	(context-panels-footer-delete-view body)
	(when (buffer-live-p buffer) (kill-buffer buffer)))))
  (when (buffer-live-p context-panels-footer--tabs-buffer)
    (kill-buffer context-panels-footer--tabs-buffer)))

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
	       (metadata (plist-get data :metadata))
               (metadata-leading (plist-get data :metadata-leading)))
	  (unless (cl-find "q" actions :test #'equal :key (lambda (action) (plist-get action :key)))
	    (setq actions (append actions '((:key "q" :label "Close" :command context-panels-close-bottom-view :select t)))))
	  (let* ((footer (context-panels-footer--ensure body))
		 (signature (list body actions metadata metadata-leading (window-body-width footer)
				  (frame-char-height (window-frame body))
				  (face-background 'mode-line-inactive (window-frame body) t)
				  (face-background 'default (window-frame body) t))))
	    (with-current-buffer (window-buffer footer)
	      (unless (equal signature context-panels-footer--signature)
		(setq context-panels-footer--signature signature)
		(context-panels-footer--render body actions metadata metadata-leading)
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
