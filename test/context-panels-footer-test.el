;;; context-panels-footer-test.el --- Fixed native footer acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Real windows, provider callbacks, scrolling and explicit native commands.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'context-panels)
(defvar context-panels-footer-test--calls nil)

(defun context-panels-footer-test--action ()
  "Record the body context of an explicit footer action."
  (interactive)
  (push (list (current-buffer) (selected-window) (point)) context-panels-footer-test--calls))

(defmacro context-panels-footer-test--panel (&rest body)
  "Run BODY with an isolated provider and a long scrollable view."
  (declare (indent 0))
  `(let* ((source (generate-new-buffer " *footer source*"))
	  (panel (generate-new-buffer " *footer body*"))
	  (context-panels-footer-test--calls nil)
	  (context-panels--last-source-buffer nil)
	  (context-panels--desired-bottom-view-id nil)
	  (saved-docks (frame-parameter nil 'context-panels-docked-views))
	  (saved-closed (frame-parameter nil 'context-panels-bottom-closed)))
     (unwind-protect
	 (save-window-excursion
	   (delete-other-windows)
	   (switch-to-buffer source)
	   (insert "An unchanged document.") (goto-char 4)
	   (context-panels-mode 1)
	   (context-panels-register-provider
	    (list :name 'fixture :icon "notes"
		  :collect-bottom-views
		  (lambda (_source)
		    (list (list :id 'table :buffer-name (buffer-name panel) :height 12
				:footer (lambda (_source _view)
					  (list :actions (list (list :key "a" :label "Enqueue" :primary t
								     :command 'context-panels-footer-test--action)
							       (list :key "gr" :label "Refresh" :command 'ignore))
						:metadata "13 tracks · 43:18"))
				:render (lambda (_source _view)
					  (dotimes (i 100) (insert (format "Track %d\n" i)))))))))
	   (context-panels-open-bottom-view 'table source)
	   ,@body)
       (dolist (buffer (list source panel))
	 (when (buffer-live-p buffer) (kill-buffer buffer)))
       (dolist (buffer (buffer-list))
	 (when (string-prefix-p " *Context Footer:" (buffer-name buffer)) (kill-buffer buffer)))
       (set-frame-parameter nil 'context-panels-docked-views saved-docks)
       (set-frame-parameter nil 'context-panels-bottom-closed saved-closed))))

(ert-deftest context-panels-footer-stays-below-scrolling-body-and-closes-with-it ()
  "The footer is native, fixed, passive and part of the protected bottom panel."
  (context-panels-footer-test--panel
   (let* ((body-window (get-buffer-window panel))
	  (footer (context-panels-footer-window panel))
	  (source-window (selected-window))
	  (edges (window-edges footer)))
     (should (window-live-p footer))
     (should (eq (window-main-window) source-window))
     (should (eq (window-atom-root footer) (window-atom-root body-window)))
     (should (window-parameter footer 'no-other-window))
     (should (window-parameter footer 'no-delete-other-windows))
     (with-current-buffer (window-buffer footer)
       (should (string-match-p "13 tracks · 43:18" (buffer-string)))
       (should (string-match-p "q Close" (buffer-string))))
     (with-current-buffer panel
       (should-not (string-match-p "Enqueue" (buffer-string)))
       (goto-char (point-min)) (forward-line 40)
       (set-window-start body-window (point)))
     (let ((position (with-current-buffer panel (point))))
       (context-panels-footer-update panel)
       (should (= position (with-current-buffer panel (point)))))
     (should (equal edges (window-edges footer)))
     (should (eq (selected-window) source-window))
     (should-not context-panels-footer-test--calls)
     (should (= (point) 4))
     (with-current-buffer panel (context-panels-close-bottom-view))
     (should-not (window-live-p footer))
     (should-not (get-buffer-window panel))
     (should (eq (window-main-window) source-window)))))

(ert-deftest context-panels-footer-commands-use-the-body-not-the-footer ()
  "A footer key acts on the existing browsing row, never a footer buffer point."
  (context-panels-footer-test--panel
   (let ((body-window (get-buffer-window panel)) (footer (context-panels-footer-window panel)))
     (with-current-buffer panel (goto-char (point-min)) (forward-line 12))
     (let ((position (with-current-buffer panel (point))))
       (set-window-point body-window position)
       (with-selected-window footer (call-interactively (key-binding (kbd "a"))))
       (should (equal context-panels-footer-test--calls (list (list panel body-window position)))))
     (should (= (point) 4)))))

(ert-deftest context-panels-footer-wraps-optional-metadata-without-dropping-actions ()
  "Long footer metadata gets its own line; redraw never runs an action."
  (context-panels-footer-test--panel
   (let* ((window (get-buffer-window panel))
	  (view (with-current-buffer panel (copy-sequence context-panels-footer-spec))))
     (setq view (plist-put view :footer
			   (lambda (_source _view)
			     (list :actions (list (list :key "a" :label "Enqueue" :command 'ignore)
						  (list :key "gr" :label "Refresh" :command 'ignore))
				   :metadata (concat "13 tracks · " (make-string 65 ?x))))))
     (with-current-buffer panel (setq context-panels-footer-spec view))
     (context-panels-footer-update panel)
     (with-current-buffer (window-buffer (context-panels-footer-window panel))
       (goto-char (point-min)) (search-forward "gr Refresh")
       (let ((actions-line (line-number-at-pos)))
	 (search-forward "13 tracks")
	 (should (> (line-number-at-pos) actions-line))))
     (should (window-live-p window))
     (should-not context-panels-footer-test--calls))))

(ert-deftest context-panels-footer-does-not-decorate-an-ordinary-copy-of-the-buffer ()
  "An adopted buffer can also be shown ordinarily without acquiring panel chrome."
  (context-panels-footer-test--panel
   (let ((ordinary (split-window (selected-window) nil 'right)))
     (set-window-buffer ordinary panel)
     (context-panels-footer-update panel)
     (should-not (window-parameter ordinary 'context-panels-footer-window))
     (should-not (window-parameter ordinary 'mode-line-format)))))

(ert-deftest context-panels-footer-reopened-controls-use-the-new-live-window ()
  "Reusing a footer buffer never retains commands targeting a closed window."
  (context-panels-footer-test--panel
   (with-current-buffer panel (context-panels-close-bottom-view))
   (context-panels-open-bottom-view 'table source)
   (let ((body (get-buffer-window panel)) (footer (context-panels-footer-window panel)))
     (with-selected-window footer (call-interactively (key-binding (kbd "a"))))
     (should (eq (cadar context-panels-footer-test--calls) body)))))

(ert-deftest context-panels-footer-refocusing-does-not-grow-the-panel ()
  "Reopening the current provider preserves the entire panel's requested height."
  (context-panels-footer-test--panel
   (let* ((body (get-buffer-window panel))
	  (height (window-total-height (window-atom-root body))))
     (context-panels-open-bottom-view 'table source)
     (should (= height (window-total-height (window-atom-root (get-buffer-window panel))))))))

(ert-deftest context-panels-footer-closes-owned-group-after-native-atom-metadata-is-lost ()
  "Closing a restored panel removes its footer without resizing it or the document."
  (context-panels-footer-test--panel
   (let* ((body (get-buffer-window panel))
	  (footer (context-panels-footer-window panel))
	  (root (window-parent body))
	  (document-window (selected-window)))
     ;; Observed in the live failure: the native atom flags have been cleared,
     ;; but the content/footer ownership and sibling layout are still intact.
     (dolist (window (list body footer root)) (set-window-parameter window 'window-atom nil))
     (with-current-buffer panel (context-panels-close-bottom-view))
     (should-not (window-live-p footer))
     (should-not (window-live-p body))
     (should (eq (selected-window) document-window))
     (should (= (point) 4)))))

(provide 'context-panels-footer-test)
;;; context-panels-footer-test.el ends here
