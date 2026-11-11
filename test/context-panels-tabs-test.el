;;; context-panels-tabs-test.el --- Native provider navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider keys, live adopted buffers, passive painting and real window focus.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'context-panels)

(defmacro context-panels-tabs-test--views (&rest body)
  "Run BODY with two providers and three views, including an existing buffer."
  (declare (indent 0))
  `(let* ((source (generate-new-buffer " *tabs source*"))
	  (a (generate-new-buffer " *tabs rendered*"))
	  (b (generate-new-buffer " *tabs existing*"))
	  (other-name " *tabs unopened*")
	  (collects 0) (renders 0)
	  (context-panels--last-source-buffer nil)
	  (context-panels--desired-bottom-view-id nil)
	  (saved-docks (frame-parameter nil 'context-panels-docked-views))
	  (saved-closed (frame-parameter nil 'context-panels-bottom-closed)))
     (unwind-protect
	 (save-window-excursion
	   (delete-other-windows)
	   (set-frame-parameter nil 'context-panels-docked-views nil)
	   (set-frame-parameter nil 'context-panels-bottom-closed nil)
	   (with-current-buffer b
	     (text-mode)
	     (dotimes (i 100) (insert (format "Retained row %d\n" i)))
	     (goto-char (point-min)))
	   (switch-to-buffer source)
	   (insert "An unchanged document.") (goto-char 4)
	   (context-panels-mode 1)
	   (context-panels-register-provider
	    (list :name 'alpha :icon "A" :collect-bottom-views
		  (lambda (_source)
		    (cl-incf collects)
		    (list (list :id 'inspect :label "Inspect" :buffer-name (buffer-name a)
				:render (lambda (_source _view)
					  (cl-incf renders)
					  (dotimes (i 100) (insert (format "Rendered row %d\n" i)))))))))
	   (context-panels-register-provider
	    (list :name 'beta :icon "B" :collect-bottom-views
		  (lambda (_source)
		    (cl-incf collects)
		    (list (list :id 'inspect :label "Inspect" :buffer b)
			  (list :id 'other :label "Other" :buffer-name other-name
				:render (lambda (_source _view) (cl-incf renders) (insert "Other")))))))
	   (context-panels-open-bottom-view '(alpha . inspect) source t)
	   ,@body)
       (dolist (buffer (list source a b (get-buffer other-name)))
	 (when (buffer-live-p buffer) (kill-buffer buffer)))
       (dolist (buffer (buffer-list))
	 (when (string-prefix-p " *Context Footer:" (buffer-name buffer)) (kill-buffer buffer)))
       (set-frame-parameter nil 'context-panels-docked-views saved-docks)
       (set-frame-parameter nil 'context-panels-bottom-closed saved-closed))))

(ert-deftest context-panels-tabs-paint-cached-provider-keys-without-initialization ()
  "Native tab painting lists all providers without collecting or opening a view."
  (context-panels-tabs-test--views
   (let ((before collects) (rendered renders) (window (selected-window)))
     (dotimes (_ 3)
       (let ((bar (mapconcat (lambda (part) (if (stringp part) part ""))
			     (context-panels-tabs-format) "")))
	 (should (string-match-p "Inspect" bar))
	 (should (string-match-p "Other" bar))))
     (should (= collects before))
     (should (= renders rendered))
     (should-not (get-buffer other-name))
     (should (eq window (selected-window)))
     (should (window-parameter window 'tab-line-format)))))

(ert-deftest context-panels-tabs-cycle-preserves-content-point-scroll-and-focus ()
  "Cycling uses distinct provider keys, preserves a retained view and returns focus."
  (context-panels-tabs-test--views
   (let ((original (with-current-buffer b (buffer-string))))
     (goto-char (point-min)) (forward-line 20)
     (set-window-start (selected-window) (point))
     (let ((position (point)) (start (window-start)))
       (call-interactively #'context-panels-next-bottom-view)
       (should (eq (current-buffer) b))
       (should-not (buffer-local-value 'context-panels-mode a))
       (should (eq (window-buffer (selected-window)) b))
       (should (derived-mode-p 'text-mode))
       (should (equal original (buffer-string)))
       (call-interactively #'context-panels-previous-bottom-view)
       (should (eq (current-buffer) a))
       (should (= (point) position))
       (should (= (window-start) start))))))

(ert-deftest context-panels-tabs-named-selection-disambiguates-and-cancel-is-passive ()
  "Completion never conflates equal labels or renders a preview on cancellation."
  (context-panels-tabs-test--views
   (let ((before renders) (window (selected-window)))
     (cl-letf (((symbol-function 'completing-read)
		(lambda (_prompt table &rest _)
		  (let ((choices (all-completions "" table)))
		    (should (member "Inspect · alpha" choices))
		    (should (member "Inspect · beta" choices)))
		  (signal 'quit nil))))
       (should (eq (condition-case nil (context-panels-select-bottom-view) (quit 'cancelled)) 'cancelled)))
     (should (= before renders))
     (should (eq window (selected-window))))
   (cl-letf (((symbol-function 'completing-read)
	      (lambda (_prompt table &rest _) (car (all-completions "Inspect · beta" table)))))
     (context-panels-select-bottom-view))
   (should (eq (current-buffer) b))))

(ert-deftest context-panels-tabs-navigation-does-not-hijack-an-ordinary-buffer-copy ()
  "Panel-only navigation filters leave ordinary copies and their bindings alone."
  (context-panels-tabs-test--views
   (with-current-buffer a
     (let ((map (make-sparse-keymap)))
       (define-key map (kbd "C-<tab>") #'ignore)
       (use-local-map map)))
   (should (eq (key-binding (kbd "C-<tab>")) #'context-panels-next-bottom-view))
   (let ((ordinary (get-buffer-window source)))
     (set-window-buffer ordinary a)
     (with-selected-window ordinary
       (should-not (window-parameter ordinary 'tab-line-format))
       (should (eq (key-binding (kbd "C-<tab>")) #'ignore))))))

(ert-deftest context-panels-tabs-switching-keeps-an-ordinary-copy-of-an-adopted-view ()
  "Adopting and switching a provider does not delete another ordinary window."
  (context-panels-tabs-test--views
   (let ((ordinary (split-window (get-buffer-window source) nil 'right)))
     (set-window-buffer ordinary b)
     (call-interactively #'context-panels-next-bottom-view)
     (should (eq (current-buffer) b))
     (call-interactively #'context-panels-previous-bottom-view)
     (should (window-live-p ordinary))
     (should (eq (window-buffer ordinary) b))
     (should-not (window-parameter ordinary 'tab-line-format)))))

(ert-deftest context-panels-tabs-provider-refresh-preserves-tab-order ()
  "Replacing a provider descriptor does not move its views around the bar."
  (context-panels-tabs-test--views
   (with-current-buffer source
     (let ((before (mapcar (lambda (view) (plist-get view :name)) context-panels-providers)))
       (context-panels-register-provider (car context-panels-providers))
       (should (equal before (mapcar (lambda (view) (plist-get view :name)) context-panels-providers)))))))

(ert-deftest context-panels-tabs-chooser-is-right-aligned-with-native-click-properties ()
  "The chooser follows native right alignment and retains its tab callback."
  (context-panels-tabs-test--views
   (let* ((parts (context-panels-tabs-format))
	  (alignment (cl-member-if
		      (lambda (part) (and (stringp part)
					  (get-text-property 0 'context-panels-chooser-alignment part)))
		      parts))
	  (chooser (cadr alignment)))
     (should alignment)
     (should (plist-get (cdr (get-text-property 0 'display (car alignment))) :align-to))
     (should (string-match-p "Views" chooser))
     (let* ((position (text-property-not-all 0 (length chooser) 'tab nil chooser))
	    (tab (get-text-property position 'tab chooser)))
       (should (alist-get 'chooser tab))
       (should (functionp (alist-get 'select tab)))))))

(provide 'context-panels-tabs-test)
;;; context-panels-tabs-test.el ends here
