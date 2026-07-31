;;; context-panels.el --- Context panel primitives -*- lexical-binding: t; -*-

;; Author: Hubert Behaghel
;; Maintainer: Hubert Behaghel
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/behaghel/context-panels

;;; Commentary:
;; Reusable Context panel primitives.
;;
;; Generic source overlay, marker, side-panel, and bottom-view mechanics.
;; Providers own item semantics and rendering.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup context-panels nil
  "Reusable context panel mechanics."
  :group 'convenience)

(defcustom context-panels-buffer-name "*Context Panel*"
  "Buffer name used for generic context side panels."
  :type 'string
  :group 'context-panels)

(defcustom context-panels-width 38
  "Width of generic context side panels."
  :type 'natnum
  :group 'context-panels)

(defcustom context-panels-bottom-buffer-name "*Context View*"
  "Fallback buffer name used for generic context bottom views."
  :type 'string
  :group 'context-panels)

(defcustom context-panels-bottom-height 12
  "Height of generic context bottom views."
  :type 'natnum
  :group 'context-panels)

(defcustom context-panels-ignored-source-file-suffixes nil
  "File suffixes that should not become context-panel source buffers."
  :type '(repeat string)
  :group 'context-panels)

(defcustom context-panels-source-buffer-predicate #'context-panels-default-source-buffer-p
  "Predicate used to decide whether BUFFER can drive context panels."
  :type 'function
  :group 'context-panels)

(defcustom context-panels-marker-position-function #'context-panels-marker-default-position
  "Function returning the default marker position in the current buffer."
  :type 'function
  :group 'context-panels)

(defvar context-panels-ignored-source-file-functions nil
  "Predicate hooks for files that should not become context-panel sources.
Each function receives an absolute file name and should return non-nil when the
file is an auxiliary sidecar or generated artifact rather than a source file.")

(defface context-panels-marker-face
  '((t :inherit link))
  "Default face for context top markers."
  :group 'context-panels)

(defvar-local context-panels-providers nil
  "Provider descriptors registered for the current source buffer.")

(defvar-local context-panels-top-marker-overlays nil
  "Top marker overlays rendered for registered providers.")

(defvar-local context-panels-source-buffer nil
  "Source buffer associated with the current context panel buffer.")

(defvar-local context-panels-side-panel-buffer nil
  "Side panel buffer associated with the current source buffer.")

(defvar-local context-panels-bottom-panel-buffer nil
  "Bottom view buffer associated with the current source buffer.")

(defvar-local context-panels-view-id nil
  "Provider view id rendered by the current context-panel buffer.")

(defvar context-panels--following nil
  "Non-nil while `context-panels' is following selected windows.")

(defvar context-panels--desired-side-panel-p nil
  "Non-nil when the workspace should keep a side context panel available.")

(defvar context-panels--desired-bottom-view-id nil
  "Bottom context view id the workspace should keep available.")

(defvar context-panels--last-source-buffer nil
  "Most recent ordinary eligible source buffer for context panels.")

(defvar context-panels--temporarily-hidden-p nil
  "Non-nil when panels were hidden because no eligible source was visible.")

(defvar context-panels--reconciling nil
  "Non-nil while reconciling context-panel windows.")

(defvar context-panels--reconcile-timer nil
  "Idle timer used to debounce context-panel window reconciliation.")

(defvar context-panels--repairing-window nil
  "Non-nil while restoring a protected context-panel window.")

(defvar context-panels-current-source-buffer nil
  "Source buffer dynamically bound while running side-panel lifecycle hooks.")

(defvar context-panels-current-source-window nil
  "Source window dynamically bound while running side-panel lifecycle hooks.")

(defvar context-panels-current-panel-buffer nil
  "Panel buffer dynamically bound while running side-panel lifecycle hooks.")

(defvar context-panels-current-panel-window nil
  "Panel window dynamically bound while running side-panel lifecycle hooks.")

(defvar context-panels-after-side-panel-open-hook nil
  "Hook run after opening or refreshing a side context panel.")

(defvar context-panels-before-side-panel-close-hook nil
  "Hook run before closing a side context panel.")

(defvar context-panels-auxiliary-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'context-panels-close-current-window)
    map)
  "Shared keymap for dismissible Context-panel auxiliary views.")

(define-derived-mode context-panels-buffer-mode special-mode "Context"
  "Major mode for generic context side panel buffers.")

(defun context-panels-close-current-window ()
  "Close the current context-panel auxiliary window."
  (interactive)
  (cond
   ((and context-panels-view-id
	 (eq (current-buffer)
	     (and (buffer-live-p context-panels-source-buffer)
		  (buffer-local-value 'context-panels-bottom-panel-buffer
				      context-panels-source-buffer))))
    (context-panels-close-bottom-view))
   ((and (not context-panels-view-id)
	 (buffer-live-p context-panels-source-buffer))
    (context-panels-close))
   (t
    (quit-window t))))

(defun context-panels--refresh-after-save ()
  "Refresh context-panel source overlays after saving the current buffer."
  (when context-panels-mode
    (context-panels-refresh-source-overlays)))

(defun context-panels--provider-name (provider)
  "Return PROVIDER's name, or signal an error when missing."
  (let ((name (plist-get provider :name)))
    (unless name
      (error "Context panel provider is missing :name"))
    name))

(defun context-panels-register-provider (provider)
  "Register PROVIDER for the current buffer and return it.
PROVIDER is a plist descriptor.  Registering another provider with the same
`:name' replaces the previous descriptor while preserving registration order."
  (let ((name (context-panels--provider-name provider)))
    (setq context-panels-providers
	  (append (cl-remove name context-panels-providers
			     :key (lambda (entry) (plist-get entry :name))
			     :test #'eq)
		  (list provider)))
    provider))

(defun context-panels-unregister-provider (name)
  "Unregister provider NAME from the current buffer."
  (setq context-panels-providers
	(cl-remove name context-panels-providers
		   :key (lambda (entry) (plist-get entry :name))
		   :test #'eq)))

(defun context-panels-registered-provider (name)
  "Return registered provider NAME for the current buffer, or nil."
  (cl-find name context-panels-providers
	   :key (lambda (entry) (plist-get entry :name))
	   :test #'eq))

(defun context-panels-registered-providers ()
  "Return registered context-panel providers for the current buffer."
  (copy-sequence context-panels-providers))

(defun context-panels--item-with-provider (item provider)
  "Return ITEM copied with PROVIDER ownership metadata."
  (let ((copy (copy-sequence item)))
    (plist-put copy :provider (plist-get provider :name))))

(defun context-panels-collect-side-items (&optional source-buffer)
  "Collect side item descriptors for SOURCE-BUFFER.
When SOURCE-BUFFER is nil, use the current buffer.  Each returned descriptor is
copied and annotated with its provider name in `:provider'."
  (let ((buffer (or source-buffer (current-buffer)))
	items)
    (with-current-buffer buffer
      (dolist (provider context-panels-providers)
	(when-let* ((function (plist-get provider :collect-side-items)))
	  (dolist (item (funcall function buffer))
	    (push (context-panels--item-with-provider item provider) items)))))
    (nreverse items)))

(defun context-panels-item-anchor-position (item)
  "Return source buffer anchor position for ITEM, or nil."
  (or (plist-get item :source-start)
      (plist-get item :target-start)
      (plist-get item :reference-pos)
      (plist-get item :anchor-pos)))

(defun context-panels-position-hidden-p (position)
  "Return non-nil when POSITION is hidden by text invisibility."
  (and position (invisible-p position)))

(defun context-panels-position-row (position window)
  "Return visible row for POSITION in WINDOW, or nil.
The primary path uses redisplay coordinates so visual wrapping and partial
scrolling follow the live window.  A logical-line fallback keeps the helper
usable in batch tests and non-redisplayed windows."
  (when (and (window-live-p window)
	     position
	     (not (context-panels-position-hidden-p position))
	     (<= (window-start window) position)
	     (< position (window-end window t)))
    (or (when-let* ((posn (posn-at-point position window))
		    (row (cdr (posn-col-row posn))))
	  (max 1 row))
	(with-current-buffer (window-buffer window)
	  (save-excursion
	    (goto-char (window-start window))
	    (1+ (count-screen-lines (point) position)))))))

(defun context-panels-item-with-viewport-row (item row)
  "Return ITEM copied with viewport ROW metadata."
  (let ((copy (copy-sequence item)))
    (setq copy (plist-put copy :logical-anchor-line
			  (or (plist-get item :logical-anchor-line)
			      (plist-get item :anchor-line))))
    (plist-put copy :anchor-line row)))

(defun context-panels-items-for-window (window &optional source-buffer)
  "Return provider side items visible in WINDOW.
When SOURCE-BUFFER is nil, use WINDOW's buffer.  Returned items are copied and
annotated with `:anchor-line' viewport rows."
  (let ((buffer (or source-buffer (window-buffer window))))
    (with-current-buffer buffer
      (delq nil
	    (mapcar
	     (lambda (item)
	       (let ((position (context-panels-item-anchor-position item)))
		 (if position
		     (when-let* ((row (context-panels-position-row
				       position window)))
		       (context-panels-item-with-viewport-row item row))
		   item)))
	     (context-panels-collect-side-items buffer))))))

(defun context-panels--source-buffer ()
  "Return the source buffer for context-panel commands."
  (cond
   ((buffer-live-p context-panels-source-buffer)
    context-panels-source-buffer)
   ((derived-mode-p 'context-panels-buffer-mode)
    (user-error "No source buffer associated with this context panel"))
   ((context-panels--eligible-source-buffer-p (current-buffer))
    (current-buffer))
   (t
    (user-error "Context panel needs a source buffer"))))

(defun context-panels-current-source-buffer ()
  "Return the source buffer associated with the current context."
  (context-panels--source-buffer))

(defun context-panels-item-key (item)
  "Return a stable context-panel identity key for ITEM."
  (or (plist-get item :id)
      (plist-get item :definition-pos)
      (plist-get item :jump-pos)
      (plist-get item :anchor-pos)
      (context-panels-item-anchor-position item)))

(defun context-panels-item-at-position (position)
  "Return context-panel item at POSITION, or nil."
  (get-text-property position 'context-panels-item))

(defun context-panels-item-at-point ()
  "Return context-panel item at point or just before point."
  (or (context-panels-item-at-position (point))
      (context-panels-item-at-position (max (point-min) (1- (point))))))

(defun context-panels-exact-item-at-position (position)
  "Return context-panel item starting at POSITION, or nil."
  (let ((item (context-panels-item-at-position position)))
    (when (and item
	       (or (= position (point-min))
		   (not (equal item (context-panels-item-at-position
				     (1- position))))))
      item)))

(defun context-panels-item-starts ()
  "Return positions where context-panel rows start in the current buffer."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
	(when (context-panels-exact-item-at-position (point))
	  (push (point) positions))
	(let ((next (next-single-property-change
		     (point) 'context-panels-item nil (point-max))))
	  (goto-char (if (and next (> next (point))) next (1+ (point)))))))
    (nreverse positions)))

(defun context-panels-goto-item-key (key)
  "Move point to the context-panel item identified by KEY.
Return the destination position, or nil when KEY is not visible."
  (let ((found nil))
    (goto-char (point-min))
    (while (and (not found) (< (point) (point-max)))
      (let ((item (context-panels-item-at-position (point))))
	(when (and item (equal key (context-panels-item-key item)))
	  (setq found (point)))
	(goto-char (or (next-single-property-change
			(point) 'context-panels-item nil (point-max))
		       (point-max)))))
    (when found
      (goto-char found))))

(defun context-panels-item-provider (item &optional source-buffer)
  "Return provider descriptor for ITEM in SOURCE-BUFFER."
  (let ((source (or source-buffer (context-panels--source-buffer))))
    (with-current-buffer source
      (context-panels-registered-provider (plist-get item :provider)))))

(defun context-panels-jump-to-item (item &optional source-buffer)
  "Jump to context-panel ITEM using its provider.
When SOURCE-BUFFER is nil, infer it from the current context."
  (let* ((source (or source-buffer (context-panels--source-buffer)))
	 (provider (or (context-panels-item-provider item source)
		       (user-error "No provider for context-panel item")))
	 (jump (or (plist-get provider :jump-side-item)
		   (user-error "Provider %s does not support row jumps"
			       (plist-get provider :name)))))
    (funcall jump source item)))

;;;###autoload
(defun context-panels-jump-at-point ()
  "Jump from the current context-panel row using its provider."
  (interactive)
  (let ((item (or (context-panels-item-at-point)
		  (user-error "No context-panel item at point"))))
    (context-panels-jump-to-item item)))

(defun context-panels--source-navigation-items (source-buffer)
  "Return navigable context-panel items for SOURCE-BUFFER."
  (with-current-buffer source-buffer
    (let ((providers (context-panels-registered-providers)))
      (context-panels--sort-items
       (cl-remove-if-not
	(lambda (item)
	  (let ((position (context-panels-item-anchor-position item)))
	    (and position
		 (not (context-panels-position-hidden-p position)))))
	(context-panels-collect-side-items source-buffer))
       providers))))

(defun context-panels--sync-visible-side-panel (source-buffer item)
  "Refresh SOURCE-BUFFER's visible side panel and focus ITEM when possible."
  (when-let* ((panel-buffer (buffer-local-value
			     'context-panels-side-panel-buffer source-buffer))
	      (panel-window (and (buffer-live-p panel-buffer)
				 (get-buffer-window panel-buffer t))))
    (with-current-buffer panel-buffer
      (context-panels-render-side-panel
       source-buffer (get-buffer-window source-buffer t))
      (when-let* ((key (context-panels-item-key item)))
	(context-panels-goto-item-key key)))
    (set-window-buffer panel-window panel-buffer)))

(defun context-panels--goto-source-navigation-item (item source-buffer)
  "Jump to source navigation ITEM in SOURCE-BUFFER and refresh panel state."
  (context-panels-jump-to-item item source-buffer)
  (context-panels--sync-visible-side-panel source-buffer item)
  item)

(defun context-panels--source-navigation-step (step)
  "Move to the next context-panel source item by STEP."
  (let* ((source (context-panels--source-buffer))
	 (position (with-current-buffer source (point)))
	 (items (context-panels--source-navigation-items source))
	 (ordered (if (> step 0) items (reverse items)))
	 (next (or (cl-find-if
		    (lambda (item)
		      (let ((anchor (context-panels-item-anchor-position item)))
			(if (> step 0)
			    (> anchor position)
			  (< anchor position))))
		    ordered)
		   (car ordered))))
    (unless next
      (user-error "No context-panel items in this buffer"))
    (context-panels--goto-source-navigation-item next source)))

;;;###autoload
(defun context-panels-next-item ()
  "Jump to the next context-panel item in the source buffer."
  (interactive)
  (context-panels--source-navigation-step 1))

;;;###autoload
(defun context-panels-previous-item ()
  "Jump to the previous context-panel item in the source buffer."
  (interactive)
  (context-panels--source-navigation-step -1))

(defun context-panels--provider-items (provider items)
  "Return ITEMS owned by PROVIDER."
  (cl-remove-if-not
   (lambda (item)
     (eq (plist-get item :provider) (plist-get provider :name)))
   items))

(defun context-panels--provider-priority (provider)
  "Return numeric display priority for PROVIDER."
  (or (plist-get provider :priority) 100))

(defun context-panels--item-provider (item providers)
  "Return provider descriptor for ITEM from PROVIDERS."
  (cl-find (plist-get item :provider) providers
	   :key (lambda (provider) (plist-get provider :name))
	   :test #'eq))

(defun context-panels--item-display-line (item)
  "Return display line key for ITEM."
  (or (plist-get item :display-line)
      (plist-get item :anchor-line)
      most-positive-fixnum))

(defun context-panels--item-source-position (item)
  "Return source position sort key for ITEM."
  (or (context-panels-item-anchor-position item)
      most-positive-fixnum))

(defun context-panels--sort-items (items providers)
  "Return ITEMS sorted by viewport/source position and provider priority."
  (sort (copy-sequence items)
	(lambda (left right)
	  (let* ((left-provider (context-panels--item-provider left providers))
		 (right-provider (context-panels--item-provider right providers))
		 (left-key (list (context-panels--item-display-line left)
				 (context-panels--item-source-position left)
				 (context-panels--provider-priority left-provider)))
		 (right-key (list (context-panels--item-display-line right)
				  (context-panels--item-source-position right)
				  (context-panels--provider-priority right-provider))))
	    (cl-loop for left-part in left-key
		     for right-part in right-key
		     thereis (< left-part right-part)
		     until (/= left-part right-part))))))

(defun context-panels--default-render-side-panel (source-buffer items)
  "Render fallback side panel contents for SOURCE-BUFFER and ITEMS."
  (insert (format "Context for: %s\n\n" (buffer-name source-buffer)))
  (if items
      (dolist (item items)
	(insert (format "- %s\n" (or (plist-get item :label)
				     (plist-get item :id)
				     (plist-get item :provider)
				     "item"))))
    (insert "No visible context items.\n")))

(defun context-panels--side-panel-property (source-buffer property)
  "Return provider-selected side panel PROPERTY for SOURCE-BUFFER, or nil."
  (with-current-buffer source-buffer
    (cl-loop for provider in context-panels-providers
	     for value = (plist-get provider property)
	     when value return value)))

(defun context-panels--side-panel-mode (source-buffer)
  "Return provider-selected side panel mode for SOURCE-BUFFER, or nil."
  (context-panels--side-panel-property source-buffer :side-panel-mode))

(defun context-panels--side-panel-value (source-buffer property fallback)
  "Return provider-selected side panel PROPERTY or FALLBACK for SOURCE-BUFFER."
  (let ((value (context-panels--side-panel-property source-buffer property)))
    (cond
     ((functionp value) (funcall value source-buffer))
     (value)
     (t fallback))))

(defun context-panels--side-panel-buffer-name (source-buffer)
  "Return provider-selected side panel buffer name for SOURCE-BUFFER."
  (context-panels--side-panel-value
   source-buffer :side-panel-buffer-name context-panels-buffer-name))

(defun context-panels--side-panel-width (source-buffer)
  "Return provider-selected side panel width for SOURCE-BUFFER."
  (context-panels--side-panel-value
   source-buffer :side-panel-width context-panels-width))

(defun context-panels--run-side-panel-hook
    (hook source-buffer panel-buffer &optional source-window panel-window)
  "Run side-panel lifecycle HOOK with panel context dynamically bound."
  (let ((context-panels-current-source-buffer source-buffer)
	(context-panels-current-source-window source-window)
	(context-panels-current-panel-buffer panel-buffer)
	(context-panels-current-panel-window panel-window))
    (run-hooks hook)))

(defun context-panels--pad-to-viewport-row (row)
  "Insert blank lines until point is at viewport ROW."
  (when (and (integerp row) (> row 1))
    (while (< (line-number-at-pos) row)
      (insert "\n"))))

(defun context-panels-protect-window (window panel-buffer source-buffer)
  "Protect WINDOW as a context panel for PANEL-BUFFER and SOURCE-BUFFER.
Protected context-panel windows are skipped by normal window navigation,
resist `delete-other-windows', and are repaired if a document buffer replaces
their panel buffer."
  (when (window-live-p window)
    (set-window-parameter window 'context-panels-protected t)
    (set-window-parameter window 'context-panels-panel-buffer panel-buffer)
    (set-window-parameter window 'context-panels-source-buffer source-buffer)
    (set-window-parameter window 'no-other-window t)
    (set-window-parameter window 'no-delete-other-windows t)
    (set-window-dedicated-p window t)))

(defun context-panels--protected-window-p (window)
  "Return non-nil when WINDOW is a protected context-panel window."
  (and (window-live-p window)
       (window-parameter window 'context-panels-protected)))

(defun context-panels--repair-protected-window (window)
  "Restore protected context-panel WINDOW if its buffer was replaced."
  (when (and (not context-panels--repairing-window)
	     (context-panels--protected-window-p window))
    (let* ((expected (window-parameter window 'context-panels-panel-buffer))
	   (source (window-parameter window 'context-panels-source-buffer))
	   (actual (window-buffer window)))
      (when (and (buffer-live-p expected)
		 (not (eq actual expected)))
	(let ((context-panels--repairing-window t)
	      (source-window (and (buffer-live-p source)
				  (get-buffer-window source t))))
	  (set-window-dedicated-p window nil)
	  (set-window-buffer window expected)
	  (context-panels-protect-window window expected source)
	  (when (and (buffer-live-p actual)
		     (window-live-p source-window)
		     (not (eq source-window window)))
	    (set-window-buffer source-window actual)))))))

(defun context-panels--window-buffer-changed (&rest _args)
  "Repair protected context-panel windows after buffer changes."
  (walk-windows #'context-panels--repair-protected-window nil t))

(add-hook 'window-buffer-change-functions
	  #'context-panels--window-buffer-changed)

(defun context-panels--render-composed-side-panel (source-buffer items providers)
  "Render merged provider ITEMS for SOURCE-BUFFER using PROVIDERS."
  (dolist (item (context-panels--sort-items items providers))
    (when-let* ((provider (context-panels--item-provider item providers))
		(function (plist-get provider :render-side-item)))
      (when (plist-get item :logical-anchor-line)
	(context-panels--pad-to-viewport-row
	 (plist-get item :anchor-line)))
      (let ((start (point)))
	(funcall function source-buffer item)
	(add-text-properties start (point)
			     `(context-panels-item ,item))))))

(defun context-panels--render-provider-side-panels (source-buffer items providers)
  "Render SOURCE-BUFFER using provider whole-panel renderers."
  (dolist (provider providers)
    (let ((provider-items (context-panels--provider-items provider items)))
      (when-let* ((function (plist-get provider :render-side-panel)))
	(funcall function source-buffer provider-items)))))

(defun context-panels-render-side-panel (source-buffer &optional source-window)
  "Render side panel contents for SOURCE-BUFFER.
When SOURCE-WINDOW is non-nil, provider items are projected onto that window's
visible viewport rows."
  (let* ((items (if source-window
		    (context-panels-items-for-window source-window source-buffer)
		  (context-panels-collect-side-items source-buffer)))
	 (providers (with-current-buffer source-buffer
		      (context-panels-registered-providers)))
	 (composable (and providers
			  (cl-every (lambda (provider)
				      (plist-get provider :render-side-item))
				    providers)
			  (or (> (length providers) 1)
			      (not (plist-get (car providers) :render-side-panel))))))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (if composable
	  (context-panels--render-composed-side-panel source-buffer items providers)
	(context-panels--render-provider-side-panels source-buffer items providers))
      (when (= (buffer-size) 0)
	(context-panels--default-render-side-panel source-buffer items))
      (goto-char (point-min)))))

;;;###autoload
(defun context-panels-open (&optional source-buffer)
  "Open or refresh a generic side context panel for SOURCE-BUFFER."
  (interactive)
  (let* ((source (or source-buffer (context-panels--source-buffer)))
	 (source-window (get-buffer-window source))
	 (buffer-name (context-panels--side-panel-buffer-name source))
	 (width (context-panels--side-panel-width source))
	 (panel-buffer (get-buffer-create buffer-name)))
    (with-current-buffer panel-buffer
      (let ((mode (context-panels--side-panel-mode source)))
	(cond
	 ((and mode (not (derived-mode-p mode)))
	  (funcall mode))
	 ((and (not mode) (not (derived-mode-p 'context-panels-buffer-mode)))
	  (context-panels-buffer-mode))))
      (setq context-panels-source-buffer source)
      (context-panels-render-side-panel source source-window))
    (with-current-buffer source
      (setq context-panels-side-panel-buffer panel-buffer))
    (let ((panel-window (display-buffer-in-side-window
			 panel-buffer
			 `((side . right)
			   (slot . 1)
			   (window-width . ,width)
			   (window-parameters
			    . ((no-other-window . t)
			       (no-delete-other-windows . t)))))))
      (context-panels-protect-window panel-window panel-buffer source)
      (setq context-panels--desired-side-panel-p t)
      (setq context-panels--last-source-buffer source)
      (setq context-panels--temporarily-hidden-p nil)
      (context-panels--run-side-panel-hook
       'context-panels-after-side-panel-open-hook
       source panel-buffer source-window panel-window))
    panel-buffer))

;;;###autoload
(defun context-panels-refresh ()
  "Refresh the generic side context panel."
  (interactive)
  (let* ((source (context-panels--source-buffer))
	 (source-window (get-buffer-window source))
	 (buffer-name (context-panels--side-panel-buffer-name source)))
    (with-current-buffer (get-buffer-create buffer-name)
      (let ((mode (context-panels--side-panel-mode source)))
	(cond
	 ((and mode (not (derived-mode-p mode)))
	  (funcall mode))
	 ((and (not mode) (not (derived-mode-p 'context-panels-buffer-mode)))
	  (context-panels-buffer-mode))))
      (setq context-panels-source-buffer source)
      (context-panels-render-side-panel source source-window))))

(defun context-panels--close-side-panel-buffer (panel-buffer &optional preserve-desire)
  "Close side PANEL-BUFFER and clear its source association.
When PRESERVE-DESIRE is non-nil, keep workspace desired-panel state."
  (unless preserve-desire
    (setq context-panels--desired-side-panel-p nil))
  (when (buffer-live-p panel-buffer)
    (let ((source (buffer-local-value 'context-panels-source-buffer
				      panel-buffer))
	  (panel-window (get-buffer-window panel-buffer)))
      (context-panels--run-side-panel-hook
       'context-panels-before-side-panel-close-hook
       source panel-buffer
       (and (buffer-live-p source) (get-buffer-window source t))
       panel-window)
      (when (window-live-p panel-window)
	(delete-window panel-window))
      (bury-buffer panel-buffer)
      (when (buffer-live-p source)
	(with-current-buffer source
	  (setq context-panels-side-panel-buffer nil))))))

;;;###autoload
(defun context-panels-close ()
  "Close the generic side context panel for the current source."
  (interactive)
  (let* ((source (context-panels--source-buffer))
	 (buffer-name (context-panels--side-panel-buffer-name source))
	 (panel-buffer (or (and (buffer-live-p context-panels-side-panel-buffer)
				context-panels-side-panel-buffer)
			   (get-buffer buffer-name))))
    (context-panels--close-side-panel-buffer panel-buffer)))

(defun context-panels--bottom-view-descriptors (source-buffer)
  "Return bottom view descriptors registered for SOURCE-BUFFER."
  (with-current-buffer source-buffer
    (cl-loop for provider in context-panels-providers
	     for function = (plist-get provider :collect-bottom-views)
	     when function append
	     (mapcar (lambda (view)
		       (let ((copy (copy-sequence view)))
			 (plist-put copy :provider (plist-get provider :name))))
		     (funcall function source-buffer)))))

(defun context-panels-bottom-view (view-id &optional source-buffer)
  "Return bottom view descriptor VIEW-ID for SOURCE-BUFFER, or nil."
  (let ((source (or source-buffer (context-panels--source-buffer))))
    (cl-find view-id (context-panels--bottom-view-descriptors source)
	     :key (lambda (view) (plist-get view :id))
	     :test #'eq)))

(defun context-panels--bottom-view-mode (view)
  "Enable VIEW's buffer mode, or the generic context-panel buffer mode."
  (let ((mode (plist-get view :mode)))
    (cond
     ((and mode (not (derived-mode-p mode)))
      (funcall mode))
     ((and (not mode) (not (derived-mode-p 'context-panels-buffer-mode)))
      (context-panels-buffer-mode)))))

(defun context-panels-render-bottom-view (source-buffer view)
  "Render bottom VIEW for SOURCE-BUFFER in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (when-let* ((function (plist-get view :render)))
      (funcall function source-buffer view))
    (when (= (buffer-size) 0)
      (insert (format "Context view: %s\n" (plist-get view :id))))
    (goto-char (point-min))))

(defun context-panels--auxiliary-window-p (window)
  "Return non-nil when WINDOW is a context-panel auxiliary window."
  (or (window-parameter window 'context-panels-protected)
      (with-current-buffer (window-buffer window)
	(and (boundp 'context-panels-source-buffer)
	     (buffer-live-p context-panels-source-buffer)))))

(defun context-panels-ignored-source-file-p (file)
  "Return non-nil when FILE should not become a context-panel source."
  (and (stringp file)
       (let ((expanded (expand-file-name file)))
	 (or (seq-some
	      (lambda (suffix)
		(string-suffix-p suffix (file-name-nondirectory expanded)))
	      context-panels-ignored-source-file-suffixes)
	     (run-hook-with-args-until-success
	      'context-panels-ignored-source-file-functions expanded)))))

(defun context-panels-default-source-buffer-p (buffer)
  "Return non-nil when BUFFER is a default eligible context source."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
	 (not (minibufferp buffer)))))

(defun context-panels--selected-ignored-source-buffer-p ()
  "Return non-nil when selected window shows an ignored source buffer."
  (let ((buffer (window-buffer (selected-window))))
    (and (buffer-live-p buffer)
	 (not (context-panels--auxiliary-window-p (selected-window)))
	 (with-current-buffer buffer
	   (and buffer-file-name
		(context-panels-ignored-source-file-p buffer-file-name))))))

(defun context-panels--eligible-source-buffer-p (buffer)
  "Return non-nil when BUFFER is an eligible source buffer."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
	 (and (not (context-panels--panel-buffer-p buffer))
	      (funcall context-panels-source-buffer-predicate buffer)
	      (not (and buffer-file-name
			(context-panels-ignored-source-file-p buffer-file-name)))))))

(defun context-panels--ordinary-source-window-p (window)
  "Return non-nil when WINDOW shows an ordinary eligible source buffer."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (context-panels--auxiliary-window-p window))
       (context-panels--eligible-source-buffer-p (window-buffer window))))

(defun context-panels--visible-source-window (source-buffer)
  "Return ordinary visible window for SOURCE-BUFFER, or nil."
  (cl-find-if (lambda (window)
		(and (eq (window-buffer window) source-buffer)
		     (context-panels--ordinary-source-window-p window)))
	      (window-list nil 'no-minibuf)))

(defun context-panels--selected-source-buffer ()
  "Return selected ordinary eligible source buffer, or nil."
  (when (context-panels--ordinary-source-window-p (selected-window))
    (window-buffer (selected-window))))

(defun context-panels--visible-source-buffer ()
  "Return selected or fallback visible eligible source buffer.
When the selected window previews an ignored sidecar, keep the last live source
instead of treating the sidecar as a new source or hiding existing panels."
  (or (context-panels--selected-source-buffer)
      (and (context-panels--selected-ignored-source-buffer-p)
	   (buffer-live-p context-panels--last-source-buffer)
	   context-panels--last-source-buffer)
      (and (buffer-live-p context-panels--last-source-buffer)
	   (context-panels--visible-source-window
	    context-panels--last-source-buffer)
	   context-panels--last-source-buffer)
      (when-let* ((window (cl-find-if
			   #'context-panels--ordinary-source-window-p
			   (window-list nil 'no-minibuf))))
	(window-buffer window))))

(defun context-panels--visible-side-panel-window ()
  "Return a visible context side-panel window, or nil."
  (cl-find-if
   (lambda (window)
     (with-current-buffer (window-buffer window)
       (and (buffer-live-p context-panels-source-buffer)
	    (not context-panels-view-id))))
   (window-list nil 'no-minibuf)))

(defun context-panels--visible-bottom-panel-window ()
  "Return a visible context bottom-panel window, or nil."
  (cl-find-if
   (lambda (window)
     (with-current-buffer (window-buffer window)
       (and (buffer-live-p context-panels-source-buffer)
	    context-panels-view-id)))
   (window-list nil 'no-minibuf)))

(defun context-panels--cleanup-auxiliary (source-buffer)
  "Ask SOURCE-BUFFER providers to clean transient auxiliary views."
  (when (buffer-live-p source-buffer)
    (with-current-buffer source-buffer
      (dolist (provider context-panels-providers)
	(when-let* ((function (plist-get provider :cleanup-auxiliary)))
	  (funcall function source-buffer))))))

(defun context-panels--hide-visible-panels ()
  "Hide visible context panels while preserving desired layout state."
  (setq context-panels--temporarily-hidden-p t)
  (when-let* ((window (context-panels--visible-side-panel-window)))
    (context-panels--close-side-panel-buffer (window-buffer window) t))
  (when-let* ((window (context-panels--visible-bottom-panel-window)))
    (context-panels--close-bottom-view-buffer (window-buffer window) t))
  (when (buffer-live-p context-panels--last-source-buffer)
    (context-panels--cleanup-auxiliary context-panels--last-source-buffer)))

(defun context-panels--close-stale-panels (source-buffer)
  "Close visible context panels not associated with SOURCE-BUFFER."
  (dolist (window (window-list nil 'no-minibuf))
    (with-current-buffer (window-buffer window)
      (when (and (buffer-live-p context-panels-source-buffer)
		 (not (eq context-panels-source-buffer source-buffer)))
	(if context-panels-view-id
	    (context-panels--close-bottom-view-buffer (current-buffer) t)
	  (context-panels--close-side-panel-buffer (current-buffer) t))))))

(defun context-panels--panel-window-for-source-p (window source-buffer)
  "Return non-nil when WINDOW already shows a panel for SOURCE-BUFFER."
  (and (window-live-p window)
       (with-current-buffer (window-buffer window)
	 (eq context-panels-source-buffer source-buffer))))

(defun context-panels--restore-desired-panels (source-buffer)
  "Restore desired context panels for SOURCE-BUFFER.
Do not rerender already-correct visible panels; chat buffers may have an
editable prompt point that reconciliation must not disturb."
  (when (and context-panels--desired-side-panel-p
	     (not (context-panels--panel-window-for-source-p
		   (context-panels--visible-side-panel-window) source-buffer)))
    (context-panels-open source-buffer))
  (when (and context-panels--desired-bottom-view-id
	     (not (context-panels--panel-window-for-source-p
		   (context-panels--visible-bottom-panel-window) source-buffer))
	     (context-panels-bottom-view
	      context-panels--desired-bottom-view-id source-buffer))
    (context-panels-open-bottom-view
     context-panels--desired-bottom-view-id source-buffer))
  (context-panels--close-stale-panels source-buffer))

(defun context-panels-reconcile-windows ()
  "Reconcile visible context panels with the current visible source."
  (unless context-panels--reconciling
    (let ((context-panels--reconciling t)
	  (selected (selected-window)))
      (unwind-protect
	  (if-let* ((source (context-panels--visible-source-buffer)))
	      (progn
		(setq context-panels--last-source-buffer source)
		(when (and context-panels--desired-side-panel-p
			   (not context-panels--temporarily-hidden-p)
			   (not (context-panels--visible-side-panel-window)))
		  (context-panels--close-side-panel-buffer
		   (buffer-local-value 'context-panels-side-panel-buffer source)))
		(when (and context-panels--desired-bottom-view-id
			   (not context-panels--temporarily-hidden-p)
			   (not (context-panels--visible-bottom-panel-window)))
		  (context-panels--close-bottom-view-buffer
		   (buffer-local-value 'context-panels-bottom-panel-buffer source)))
		(context-panels--restore-desired-panels source)
		(setq context-panels--temporarily-hidden-p nil))
	    (when (or (context-panels--visible-side-panel-window)
		      (context-panels--visible-bottom-panel-window))
	      (context-panels--hide-visible-panels)))
	(when (window-live-p selected)
	  (select-window selected))))))

(defun context-panels--schedule-reconcile (&rest _args)
  "Schedule debounced context-panel window reconciliation."
  (unless (timerp context-panels--reconcile-timer)
    (setq context-panels--reconcile-timer
	  (run-with-idle-timer
	   0 nil
	   (lambda ()
	     (setq context-panels--reconcile-timer nil)
	     (context-panels-reconcile-windows))))))

(add-hook 'window-configuration-change-hook
	  #'context-panels--schedule-reconcile)

(defun context-panels--side-panel-window ()
  "Return a visible `context-panels' side-panel window, or nil."
  (cl-find-if
   (lambda (window)
     (with-current-buffer (window-buffer window)
       (and (buffer-live-p context-panels-source-buffer)
	    (not context-panels-view-id))))
   (window-list nil 'no-minibuf)))

(defun context-panels--panel-buffer-p (buffer)
  "Return non-nil when BUFFER is an `context-panels' panel buffer."
  (with-current-buffer buffer
    (and (buffer-live-p context-panels-source-buffer)
	 t)))

(defun context-panels--provider-follow-source-p (provider source-buffer)
  "Return non-nil when PROVIDER should follow SOURCE-BUFFER."
  (if-let* ((predicate (plist-get provider :follow-source-p)))
      (funcall predicate source-buffer)
    t))

(defun context-panels--followable-source-p (buffer)
  "Return non-nil when BUFFER should drive a visible context side panel."
  (with-current-buffer buffer
    (and (context-panels--eligible-source-buffer-p buffer)
	 context-panels-mode
	 (cl-some (lambda (provider)
		    (context-panels--provider-follow-source-p provider buffer))
		  context-panels-providers))))

(defun context-panels--follow-selected-buffer ()
  "Schedule context-panel reconciliation after command-driven focus changes."
  (when (and (not context-panels--following)
	     (not (active-minibuffer-window)))
    (let ((context-panels--following t))
      (unwind-protect
	  (progn
	    (when-let* ((source (context-panels--selected-source-buffer)))
	      (setq context-panels--last-source-buffer source))
	    (when (or context-panels--desired-side-panel-p
		      context-panels--desired-bottom-view-id
		      (context-panels--visible-side-panel-window)
		      (context-panels--visible-bottom-panel-window))
	      (context-panels--schedule-reconcile)))
	(setq context-panels--following nil)))))

(add-hook 'post-command-hook #'context-panels--follow-selected-buffer)

;;;###autoload
(defun context-panels-open-bottom-view (view-id &optional source-buffer)
  "Open bottom context view VIEW-ID for SOURCE-BUFFER."
  (interactive)
  (let* ((source (or source-buffer (context-panels--source-buffer)))
	 (view (or (context-panels-bottom-view view-id source)
		   (user-error "No context bottom view: %s" view-id)))
	 (buffer-name (or (plist-get view :buffer-name)
			  context-panels-bottom-buffer-name))
	 (height (or (plist-get view :height)
		     context-panels-bottom-height))
	 (panel-buffer (get-buffer-create buffer-name)))
    (with-current-buffer panel-buffer
      (context-panels--bottom-view-mode view)
      (setq context-panels-source-buffer source)
      (setq context-panels-view-id view-id)
      (context-panels-render-bottom-view source view))
    (with-current-buffer source
      (setq context-panels-bottom-panel-buffer panel-buffer))
    (context-panels-protect-window
     (display-buffer-in-side-window
      panel-buffer
      `((side . bottom)
	(slot . 1)
	(window-height . ,height)
	(window-parameters
	 . ((no-other-window . t)
	    (no-delete-other-windows . t)))))
     panel-buffer source)
    (setq context-panels--desired-bottom-view-id view-id)
    (setq context-panels--last-source-buffer source)
    (setq context-panels--temporarily-hidden-p nil)
    panel-buffer))

;;;###autoload
(defun context-panels-refresh-bottom-view ()
  "Refresh the current generic bottom context view."
  (interactive)
  (let* ((source (context-panels--source-buffer))
	 (view-id (or context-panels-view-id
		      (user-error "No context bottom view associated with buffer"))))
    (context-panels-open-bottom-view view-id source)))

;;;###autoload
(defun context-panels--close-bottom-view-buffer (panel-buffer &optional preserve-desire)
  "Close bottom PANEL-BUFFER.
When PRESERVE-DESIRE is non-nil, keep workspace desired-bottom state."
  (unless preserve-desire
    (setq context-panels--desired-bottom-view-id nil))
  (when (buffer-live-p panel-buffer)
    (let ((source (buffer-local-value 'context-panels-source-buffer
				      panel-buffer)))
      (when-let* ((window (get-buffer-window panel-buffer)))
	(delete-window window))
      (bury-buffer panel-buffer)
      (when (buffer-live-p source)
	(with-current-buffer source
	  (setq context-panels-bottom-panel-buffer nil))))))

(defun context-panels-close-bottom-view ()
  "Close the generic bottom context view for the current source."
  (interactive)
  (let* ((source (context-panels--source-buffer))
	 (panel-buffer (or (and (buffer-live-p context-panels-bottom-panel-buffer)
				context-panels-bottom-panel-buffer)
			   (get-buffer context-panels-bottom-buffer-name))))
    (context-panels--close-bottom-view-buffer panel-buffer)))

(defun context-panels-cleanup-source-overlays ()
  "Clean up source overlays for registered providers in the current buffer."
  (dolist (provider context-panels-providers)
    (when-let* ((function (plist-get provider :cleanup-source-overlays)))
      (funcall function)))
  (context-panels-delete-top-markers))

(defun context-panels-refresh-source-overlays ()
  "Refresh source overlays for registered providers in the current buffer."
  (dolist (provider context-panels-providers)
    (when-let* ((function (plist-get provider :refresh-source-overlays)))
      (funcall function)))
  (context-panels-refresh-top-markers))

;;;###autoload
(define-minor-mode context-panels-mode
  "Enable reusable Context-panel mechanics for the current buffer.
This mode is intentionally non-invasive: it refreshes provider-owned source
markers and overlays, but it does not open side or bottom panel windows."
  :lighter " Ctx"
  (if context-panels-mode
      (progn
	(add-hook 'after-save-hook #'context-panels--refresh-after-save nil t)
	(context-panels-refresh-source-overlays))
    (remove-hook 'after-save-hook #'context-panels--refresh-after-save t)
    (context-panels-cleanup-source-overlays)))

(defun context-panels-marker-default-position ()
  "Return the default position for context-panel markers."
  (point-min))

(defun context-panels-default-marker-position ()
  "Return the configured default position for context-panel markers."
  (funcall context-panels-marker-position-function))

(defun context-panels-valid-region-p (start end)
  "Return non-nil when START and END are valid overlay bounds."
  (and start end (<= (point-min) start) (<= start end) (<= end (point-max))))

(defun context-panels-delete-overlay (overlay)
  "Delete OVERLAY when it is live."
  (when (overlayp overlay)
    (delete-overlay overlay)))

(defun context-panels-delete-overlays (overlays)
  "Delete each overlay in OVERLAYS."
  (mapc #'context-panels-delete-overlay overlays))

(defun context-panels-delete-top-markers (&optional provider-name)
  "Delete context-panel top marker overlays in the current buffer.
When PROVIDER-NAME is non-nil, delete only markers owned by that provider."
  (let (kept-overlays)
    (dolist (overlay context-panels-top-marker-overlays)
      (if (and provider-name
	       (not (eq (overlay-get overlay 'context-panels-provider)
			provider-name)))
	  (push overlay kept-overlays)
	(when-let* ((marker (and (overlayp overlay)
				 (overlay-get overlay 'context-panels-marker)))
		    (overlay-variable (plist-get marker :overlay-variable)))
	  (set overlay-variable nil))
	(context-panels-delete-overlay overlay)))
    (setq context-panels-top-marker-overlays (nreverse kept-overlays))))

(cl-defun context-panels-make-range-overlay
    (start end &key face properties evaporate)
  "Create a source range overlay from START to END.
FACE is applied as the overlay face when non-nil.  PROPERTIES is a plist of
additional overlay properties.  When EVAPORATE is non-nil, set the overlay's
`evaporate' property.  Return nil when START and END are not valid in the
current buffer."
  (when (context-panels-valid-region-p start end)
    (let ((overlay (make-overlay start end nil t nil)))
      (when face
	(overlay-put overlay 'face face))
      (when evaporate
	(overlay-put overlay 'evaporate t))
      (while properties
	(overlay-put overlay (pop properties) (pop properties)))
      overlay)))

(cl-defun context-panels-make-top-marker
    (&key label keymap help-echo position face mouse-face priority properties)
  "Create a top marker overlay and return it.
LABEL is rendered in the marker's `after-string'.  KEYMAP is applied to the
visible marker text and to the overlay itself.  HELP-ECHO, POSITION, FACE,
MOUSE-FACE, PRIORITY, and PROPERTIES customize the marker.  POSITION defaults to
`context-panels-default-marker-position'."
  (let* ((marker-position (or position (context-panels-default-marker-position)))
	 (overlay (make-overlay marker-position marker-position nil t nil))
	 (marker-face (or face 'context-panels-marker-face))
	 (marker-mouse-face (or mouse-face 'highlight)))
    (when priority
      (overlay-put overlay 'priority priority))
    (when keymap
      (overlay-put overlay 'keymap keymap))
    (while properties
      (overlay-put overlay (pop properties) (pop properties)))
    (overlay-put overlay 'after-string
		 (concat (propertize label
				     'face marker-face
				     'mouse-face marker-mouse-face
				     'help-echo help-echo
				     'keymap keymap)
			 "\n"))
    overlay))

(defun context-panels--marker-at-point ()
  "Return context-panel top marker descriptor at point, or nil."
  (or (cl-loop for overlay in (overlays-at (point))
	       for marker = (overlay-get overlay 'context-panels-marker)
	       when marker return marker)
      (cl-loop for overlay in context-panels-top-marker-overlays
	       when (and (overlayp overlay)
			 (= (overlay-start overlay) (point)))
	       return (overlay-get overlay 'context-panels-marker))))

(defun context-panels-open-marker-view ()
  "Open the bottom view associated with the top marker at point."
  (interactive)
  (let* ((marker (context-panels--marker-at-point))
	 (view-id (plist-get marker :view-id)))
    (unless view-id
      (user-error "No context view associated with marker"))
    (context-panels-open-bottom-view view-id)))

(defun context-panels--top-marker-keymap (marker provider)
  "Return the keymap for MARKER from PROVIDER."
  (let ((keymap (plist-get marker :keymap))
	(action (plist-get marker :action))
	(view-id (plist-get marker :view-id)))
    (cond
     (keymap keymap)
     (action
      (let ((map (make-sparse-keymap)))
	(define-key map (kbd "RET") action)
	(define-key map [mouse-1] action)
	map))
     (view-id
      (let ((map (make-sparse-keymap)))
	(define-key map (kbd "RET") #'context-panels-open-marker-view)
	(define-key map [mouse-1] #'context-panels-open-marker-view)
	map))
     ((plist-get provider :open-top-marker)
      (let ((map (make-sparse-keymap))
	    (function (plist-get provider :open-top-marker)))
	(define-key map (kbd "RET") function)
	(define-key map [mouse-1] function)
	map)))))

(defun context-panels--render-top-marker (marker provider)
  "Render MARKER descriptor for PROVIDER and return its overlay."
  (let* ((overlay-variable (plist-get marker :overlay-variable))
	 (overlay (context-panels-make-top-marker
		   :label (plist-get marker :label)
		   :keymap (context-panels--top-marker-keymap marker provider)
		   :help-echo (plist-get marker :help)
		   :position (plist-get marker :position)
		   :face (plist-get marker :face)
		   :mouse-face (plist-get marker :mouse-face)
		   :priority (plist-get marker :priority)
		   :properties (append (list 'context-panels-provider
					     (plist-get provider :name)
					     'context-panels-marker marker)
				       (plist-get marker :properties)))))
    (when overlay-variable
      (set overlay-variable overlay))
    overlay))

(defun context-panels-refresh-top-markers ()
  "Refresh top markers from registered provider descriptors."
  (context-panels-delete-top-markers)
  (dolist (provider context-panels-providers)
    (when-let* ((function (plist-get provider :collect-top-markers)))
      (dolist (marker (funcall function (current-buffer)))
	(push (context-panels--render-top-marker marker provider)
	      context-panels-top-marker-overlays))))
  (setq context-panels-top-marker-overlays
	(nreverse context-panels-top-marker-overlays)))

(defun context-panels-marker-position (overlay &optional fallback-predicate)
  "Return top marker OVERLAY position, or fallback default position.
When OVERLAY is live, return its start position.  Otherwise, if
FALLBACK-PREDICATE returns non-nil, return `context-panels-default-marker-position'."
  (cond
   ((overlayp overlay)
    (overlay-start overlay))
   ((and fallback-predicate (funcall fallback-predicate))
    (context-panels-default-marker-position))))

(defun context-panels-marker-at-point-p (overlay &optional fallback-predicate)
  "Return non-nil when point is at marker OVERLAY or fallback position."
  (equal (point) (context-panels-marker-position overlay fallback-predicate)))

(provide 'context-panels)
;;; context-panels.el ends here
