;;; context-panels-test.el --- Tests for context-panels -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for generic context panel mechanics.

;;; Code:

(require 'ert)
(require 'context-panels)

(ert-deftest context-panels-source-buffer-default-allows-text-buffer ()
  "Generic source detection is not Org-specific."
  (with-temp-buffer
    (text-mode)
    (context-panels-mode 1)
    (should (context-panels--eligible-source-buffer-p (current-buffer)))))

(ert-deftest context-panels-top-marker-defaults-to-point-min ()
  "Generic top markers default to `point-min'."
  (with-temp-buffer
    (insert "header\nbody\n")
    (let ((overlay (context-panels-make-top-marker :label "marker")))
      (unwind-protect
	  (should (= (overlay-start overlay) (point-min)))
	(delete-overlay overlay)))))

(ert-deftest context-panels-open-displays-visible-side-window ()
  "Opening a context panel leaves the panel buffer visible."
  (let ((source (get-buffer-create "*context-panels-test-source*")))
    (unwind-protect
	(progn
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :side-panel-buffer-name "*context-panels-test-panel*"
		 :collect-side-items (lambda (_source) nil)))
	  (let ((panel-buffer (context-panels-open source)))
	    (should (buffer-live-p panel-buffer))
	    (should (get-buffer-window panel-buffer (selected-frame)))))
      (when (get-buffer "*context-panels-test-panel*")
	(kill-buffer "*context-panels-test-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source)))))

(ert-deftest context-panels-collect-side-items-hides-folded-anchors ()
  "Collected side items exclude anchors hidden by source folding."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (let ((hidden-anchor (progn (goto-char (point-min))
				(forward-line 1)
				(point)))
	  (visible-anchor (progn (forward-line 1) (point))))
      (add-to-invisibility-spec '(context-panels-test-fold . t))
      (let ((overlay (make-overlay hidden-anchor visible-anchor)))
	(unwind-protect
	    (progn
	      (overlay-put overlay 'invisible 'context-panels-test-fold)
	      (context-panels-mode 1)
	      (context-panels-register-provider
	       (list :name 'test
		     :icon "🧪"
		     :collect-side-items
		     (lambda (_source)
		       (list (list :id 'hidden :label "hidden"
				   :anchor-pos hidden-anchor)
			     (list :id 'visible :label "visible"
				   :anchor-pos visible-anchor)))))
	      (should (equal (mapcar (lambda (item) (plist-get item :id))
				     (context-panels-collect-side-items))
			     '(visible))))
	  (delete-overlay overlay)
	  (remove-from-invisibility-spec '(context-panels-test-fold . t)))))))

(ert-deftest context-panels-open-aligns-items-to-source-viewport-rows ()
  "Composable side-panel items are padded to their source viewport rows."
  (let ((source (get-buffer-create "*context-panels-test-align-source*")))
    (unwind-protect
	(progn
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\nfour\n")
	  (goto-char (point-min))
	  (forward-line 2)
	  (let ((anchor (point)))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-align-panel*"
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'three :label "three" :anchor-pos anchor)))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let ((panel-buffer (context-panels-open source)))
	      (with-current-buffer panel-buffer
		(should (string-prefix-p "\n\nthree\n" (buffer-string)))))))
      (when (get-buffer "*context-panels-test-align-panel*")
	(kill-buffer "*context-panels-test-align-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source)))))

(ert-deftest context-panels-open-prefers-composable-rendering-for-alignment ()
  "Providers with item renderers align rows even when a whole renderer exists."
  (let ((source (get-buffer-create "*context-panels-test-prefer-composed-source*")))
    (unwind-protect
	(progn
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\nfour\n")
	  (goto-char (point-min))
	  (forward-line 2)
	  (let ((anchor (point)))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-prefer-composed-panel*"
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'three :label "three" :anchor-pos anchor)))
		   :render-side-panel
		   (lambda (_source _items)
		     (insert "whole\n"))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let ((panel-buffer (context-panels-open source)))
	      (with-current-buffer panel-buffer
		(should (string-prefix-p "\n\nthree\n" (buffer-string)))
		(should-not (string-match-p "whole" (buffer-string)))))))
      (when (get-buffer "*context-panels-test-prefer-composed-panel*")
	(kill-buffer "*context-panels-test-prefer-composed-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source)))))

(ert-deftest context-panels-open-ignores-inactive-noncomposable-providers ()
  "Inactive providers do not force fallback rendering for aligned items."
  (let ((source (get-buffer-create "*context-panels-test-inactive-source*")))
    (unwind-protect
	(progn
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\nfour\n")
	  (goto-char (point-min))
	  (forward-line 2)
	  (let ((anchor (point)))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'inactive
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-inactive-panel*"
		   :collect-side-items (lambda (_source) nil)))
	    (context-panels-register-provider
	     (list :name 'active
		   :icon "🧪"
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'three :label "three" :anchor-pos anchor)))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let ((panel-buffer (context-panels-open source)))
	      (with-current-buffer panel-buffer
		(should (string-prefix-p "\n\nthree\n" (buffer-string)))
		(should-not (string-match-p "Context for:" (buffer-string)))))))
      (when (get-buffer "*context-panels-test-inactive-panel*")
	(kill-buffer "*context-panels-test-inactive-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source)))))

(ert-deftest context-panels-side-panel-refreshes-when-source-window-scrolls ()
  "Visible side-panel rows follow the source window viewport."
  (let ((source (get-buffer-create "*context-panels-test-scroll-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (dotimes (idx 30)
	    (insert (format "line-%02d\n" (1+ idx))))
	  (goto-char (point-min))
	  (forward-line 11)
	  (let ((anchor (point)))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-scroll-panel*"
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'line-12
				 :label "line-12"
				 :anchor-pos anchor)))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let* ((source-window (selected-window))
		   (panel-buffer (context-panels-open source)))
	      (goto-char (point-min))
	      (forward-line 9)
	      (set-window-start source-window (point) t)
	      (context-panels--refresh-side-panel-for-source-window source-window)
	      (with-current-buffer panel-buffer
		(should (string-prefix-p "\n\nline-12\n" (buffer-string)))))))
      (when (get-buffer "*context-panels-test-scroll-panel*")
	(kill-buffer "*context-panels-test-scroll-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))


(ert-deftest context-panels-highlights-side-items-from-source-point ()
  "Source point activates matching visible side items and source range."
  (let ((source (get-buffer-create "*context-panels-test-active-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\n")
	  (let ((start (progn (goto-char (point-min)) (forward-line 1) (point)))
		(end (progn (end-of-line) (point))))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-active-panel*"
		   :active-face 'match
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'two-a :label "two-a" :source-start start :source-end end)
			   (list :id 'two-b :label "two-b" :source-start start :source-end end)))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let ((panel-buffer (context-panels-open source)))
	      (goto-char start)
	      (context-panels-update-active-highlights source)
	      (should (= 1 (length context-panels-active-source-overlays)))
	      (should (eq 'match (overlay-get (car context-panels-active-source-overlays) 'face)))
	      (with-current-buffer panel-buffer
		(should (= 2 (length context-panels-active-side-overlays)))
		(should (cl-every (lambda (overlay)
				    (eq 'match (overlay-get overlay 'face)))
				  context-panels-active-side-overlays))))))
      (when (get-buffer "*context-panels-test-active-panel*")
	(kill-buffer "*context-panels-test-active-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-reveals-active-side-item-from-source-point ()
  "Source-driven highlighting may scroll side panel to reveal active item."
  (let ((source (get-buffer-create "*context-panels-test-reveal-source*"))
	revealed)
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\n")
	  (let ((start (progn (goto-char (point-min)) (forward-line 1) (point)))
		(end (progn (end-of-line) (point))))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-reveal-panel*"
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'two :label "two" :source-start start :source-end end)))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let ((panel-buffer (context-panels-open source)))
	      (goto-char start)
	      (cl-letf (((symbol-function 'pos-visible-in-window-p)
			 (lambda (&rest _args) nil))
			((symbol-function 'scroll-up-command)
			 (lambda (&optional _arg)
			   (setq revealed t))))
		(context-panels-update-active-highlights source))
	      (should revealed))))
      (when (get-buffer "*context-panels-test-reveal-panel*")
	(kill-buffer "*context-panels-test-reveal-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-item-active-source-range-nil-disables-source-highlight ()
  "Items can opt out of source highlighting while keeping side-panel activity."
  (with-temp-buffer
    (insert "one\ntwo\n")
    (let ((anchor (point-min)))
      (context-panels-mode 1)
      (context-panels-register-provider
       (list :name 'test
	     :icon "🧪"
	     :collect-side-items
	     (lambda (_source)
	       (list (list :id 'one :label "one" :anchor-pos anchor
			   :active-source-range nil)))
	     :render-side-item
	     (lambda (_source item)
	       (insert (plist-get item :label) "\n"))))
      (let* ((provider (context-panels-registered-provider 'test))
	     (item (car (context-panels-collect-side-items)))
	     (range (context-panels--active-source-range
		     (current-buffer) item provider)))
	(should-not range)))))

(ert-deftest context-panels-highlights-source-from-side-point ()
  "Side-panel point activates the targeted source range without jumping."
  (let ((source (get-buffer-create "*context-panels-test-side-active-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\n")
	  (let ((start (progn (goto-char (point-min)) (forward-line 1) (point)))
		(end (progn (end-of-line) (point))))
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name "*context-panels-test-side-active-panel*"
		   :active-source-face 'isearch
		   :active-side-face 'region
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'two :label "two" :source-start start :source-end end)))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))))
	    (let ((panel-buffer (context-panels-open source)))
	      (goto-char (point-min))
	      (select-window (get-buffer-window panel-buffer t))
	      (goto-char (point-min))
	      (goto-char (or (next-single-property-change
			      (point) 'context-panels-item nil (point-max))
			     (point)))
	      (context-panels-update-active-highlights source)
	      (with-current-buffer source
		(should (= (point-min) (point)))
		(should (= 1 (length context-panels-active-source-overlays)))
		(should (eq 'isearch (overlay-get (car context-panels-active-source-overlays) 'face))))
	      (with-current-buffer panel-buffer
		(should (= 1 (length context-panels-active-side-overlays)))
		(should (eq 'region (overlay-get (car context-panels-active-side-overlays) 'face)))))))
      (when (get-buffer "*context-panels-test-side-active-panel*")
	(kill-buffer "*context-panels-test-side-active-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-open-default-does-not-open-bottom-view ()
  "Default `context-panels-open' remains side-panel-only."
  (let ((source (get-buffer-create "*context-panels-test-bottom-default-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :side-panel-buffer-name "*context-panels-test-bottom-default-side*"
		 :collect-side-items (lambda (_source) nil)
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'inspect
			       :label "Inspect"
			       :render (lambda (_source _view)
					 (insert "bottom")))))))
	  (context-panels-open source)
	  (should (get-buffer-window "*context-panels-test-bottom-default-side*" t))
	  (should-not (context-panels--visible-bottom-panel-window)))
      (dolist (name '("*context-panels-test-bottom-default-side*"
		      "*Context View: test/inspect*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-open-bottom-view-uses-per-view-buffer ()
  "Bottom views get provider/view-specific buffers when no buffer name is given."
  (let ((source (get-buffer-create "*context-panels-test-bottom-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'inspect
			       :label "Inspect"
			       :render (lambda (_source _view)
					 (insert "inspector")))))))
	  (let ((panel-buffer (context-panels-open-bottom-view 'inspect source)))
	    (should (equal (buffer-name panel-buffer) "*Context View: test/inspect*"))
	    (should (get-buffer-window panel-buffer t))
	    (with-current-buffer panel-buffer
	      (should (eq context-panels-source-buffer source))
	      (should (eq context-panels-view-id 'inspect))
	      (should (equal (string-trim (buffer-string)) "inspector")))))
      (when (get-buffer "*Context View: test/inspect*")
	(kill-buffer "*Context View: test/inspect*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-bottom-view-height-uses-provider-maximum ()
  "Bottom window height uses max requested height across active views."
  (let ((source (get-buffer-create "*context-panels-test-bottom-height-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'short :label "Short" :height 4
			       :render (lambda (_source _view) (insert "short")))
			 (list :id 'tall :label "Tall" :height 13
			       :render (lambda (_source _view) (insert "tall")))))))
	  (let* ((panel-buffer (context-panels-open-bottom-view 'short source))
		 (window (get-buffer-window panel-buffer t)))
	    (should (= 13 (window-total-height window)))))
      (dolist (name '("*Context View: test/short*" "*Context View: test/tall*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-adopt-bottom-view-buffer-replaces-bottom-view ()
  "Adopting a live buffer makes it the source's protected bottom view."
  (let ((source (get-buffer-create "*context-panels-test-adopt-source*"))
	(live (get-buffer-create "*context-panels-test-adopt-live*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (with-current-buffer live
	    (erase-buffer)
	    (insert "live\n"))
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'editor :label "Editor"
			       :render (lambda (_source _view)
					 (insert "editor")))
			 (list :id 'live :label "Live"
			       :render (lambda (_source _view)
					 (insert "placeholder")))))))
	  (let ((editor (context-panels-open-bottom-view 'editor source)))
	    (should (get-buffer-window editor t))
	    (context-panels-adopt-bottom-view-buffer live 'live source)
	    (should-not (get-buffer-window editor t))
	    (should (eq (window-buffer (context-panels--visible-bottom-panel-window))
			live))
	    (with-current-buffer live
	      (should (eq context-panels-source-buffer source))
	      (should (eq context-panels-view-id 'live)))
	    (with-current-buffer source
	      (should (eq context-panels-bottom-panel-buffer live))
	      (should (equal context-panels-bottom-view-desired-id
			     '(test . live))))))
      (dolist (name '("*Context View: test/editor*"
		      "*context-panels-test-adopt-live*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-next-bottom-view-cycles-visible-view ()
  "Cycling switches the visible bottom window to the next bottom view."
  (let ((source (get-buffer-create "*context-panels-test-bottom-cycle-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'one :label "One"
			       :render (lambda (_source _view) (insert "one")))
			 (list :id 'two :label "Two"
			       :render (lambda (_source _view) (insert "two")))))))
	  (let ((first (context-panels-open-bottom-view 'one source)))
	    (should (get-buffer-window first t))
	    (let ((second (context-panels-next-bottom-view source)))
	      (should (equal (buffer-name second) "*Context View: test/two*"))
	      (should (get-buffer-window second t))
	      (should-not (get-buffer-window first t))
	      (with-current-buffer second
		(should (equal (string-trim (buffer-string)) "two"))))))
      (dolist (name '("*Context View: test/one*" "*Context View: test/two*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-select-bottom-view-uses-completing-read ()
  "Selecting a bottom view opens the chosen provider/view buffer."
  (let ((source (get-buffer-create "*context-panels-test-bottom-select-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'one :label "One"
			       :render (lambda (_source _view) (insert "one")))
			 (list :id 'two :label "Two"
			       :render (lambda (_source _view) (insert "two")))
			 (list :id 'three :label "Three"
			       :render (lambda (_source _view) (insert "three")))))))
	  (cl-letf (((symbol-function 'completing-read)
		     (lambda (_prompt collection &rest _args)
		       (should (member "Three" collection))
		       "Three")))
	    (let ((panel-buffer (context-panels-select-bottom-view source)))
	      (should (equal (buffer-name panel-buffer) "*Context View: test/three*"))
	      (with-current-buffer panel-buffer
		(should (equal (string-trim (buffer-string)) "three"))))))
      (dolist (name '("*Context View: test/one*"
		      "*Context View: test/two*"
		      "*Context View: test/three*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-bottom-view-ids-are-provider-local ()
  "Provider/view keys distinguish bottom views that share the same local id."
  (let ((source (get-buffer-create "*context-panels-test-bottom-local-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'alpha
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'inspect :label "Alpha"
			       :render (lambda (_source _view)
					 (insert "alpha")))))))
	  (context-panels-register-provider
	   (list :name 'beta
		 :icon "🧪"
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'inspect :label "Beta"
			       :render (lambda (_source _view)
					 (insert "beta")))))))
	  (cl-letf (((symbol-function 'completing-read)
		     (lambda (_prompt collection &rest _args)
		       (should (member "Beta" collection))
		       "Beta")))
	    (let ((panel-buffer (context-panels-select-bottom-view source)))
	      (should (equal (buffer-name panel-buffer) "*Context View: beta/inspect*"))
	      (with-current-buffer panel-buffer
		(should (equal (string-trim (buffer-string)) "beta"))))))
      (dolist (name '("*Context View: alpha/inspect*"
		      "*Context View: beta/inspect*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-hide-and-restore-side-and-bottom-together ()
  "Leaving a source hides both panels; reentering restores both."
  (let ((source (get-buffer-create "*context-panels-test-sync-source*") )
	(other (get-buffer-create "*context-panels-test-sync-other*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :side-panel-buffer-name "*context-panels-test-sync-side*"
		 :collect-side-items
		 (lambda (_source)
		   (list (list :id 'row :label "row")))
		 :render-side-item
		 (lambda (_source item)
		   (insert (plist-get item :label) "\n"))
		 :collect-bottom-views
		 (lambda (_source)
		   (list (list :id 'inspect :label "Inspect"
			       :render (lambda (_source _view)
					 (insert "bottom")))))))
	  (context-panels-open source)
	  (context-panels-open-bottom-view 'inspect source)
	  (should (context-panels--visible-side-panel-window))
	  (should (context-panels--visible-bottom-panel-window))
	  (switch-to-buffer other)
	  (context-panels-reconcile-windows)
	  (should-not (context-panels--visible-side-panel-window))
	  (should-not (context-panels--visible-bottom-panel-window))
	  (switch-to-buffer source)
	  (context-panels-reconcile-windows)
	  (should (context-panels--panel-window-for-source-p
		   (context-panels--visible-side-panel-window) source))
	  (should (context-panels--panel-window-for-source-p
		   (context-panels--visible-bottom-panel-window) source)))
      (dolist (name '("*context-panels-test-sync-side*"
		      "*Context View: test/inspect*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source)
	(kill-buffer source))
      (when (buffer-live-p other)
	(kill-buffer other))
      (setq context-panels--last-source-buffer nil)
      (setq context-panels--temporarily-hidden-p nil)
      (setq context-panels--desired-side-panel-p nil)
      (setq context-panels--desired-bottom-view-id nil)
      (delete-other-windows))))

(ert-deftest context-panels-resyncs-to-reentered-source-with-panels ()
  "Switching between sources restores panels only for sources that wanted them."
  (let ((source-a (get-buffer-create "*context-panels-test-source-a*"))
	(source-b (get-buffer-create "*context-panels-test-source-b*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (dolist (source (list source-a source-b))
	    (switch-to-buffer source)
	    (erase-buffer)
	    (insert (buffer-name source) "\n")
	    (context-panels-mode 1)
	    (context-panels-register-provider
	     (list :name 'test
		   :icon "🧪"
		   :side-panel-buffer-name
		   (format "*context-panels-test-side-%s*" (buffer-name source))
		   :collect-side-items
		   (lambda (_source)
		     (list (list :id 'row :label "row")))
		   :render-side-item
		   (lambda (_source item)
		     (insert (plist-get item :label) "\n"))
		   :collect-bottom-views
		   (lambda (_source)
		     (list (list :id 'inspect :label "Inspect"
				 :render (lambda (source _view)
					   (insert (buffer-name source)))))))))
	  (switch-to-buffer source-a)
	  (context-panels-open source-a)
	  (context-panels-open-bottom-view 'inspect source-a)
	  (switch-to-buffer source-b)
	  (context-panels-open source-b)
	  (context-panels-open-bottom-view 'inspect source-b)
	  (context-panels-reconcile-windows)
	  (should (context-panels--panel-window-for-source-p
		   (context-panels--visible-side-panel-window) source-b))
	  (should (context-panels--panel-window-for-source-p
		   (context-panels--visible-bottom-panel-window) source-b))
	  (switch-to-buffer source-a)
	  (context-panels-reconcile-windows)
	  (should (context-panels--panel-window-for-source-p
		   (context-panels--visible-side-panel-window) source-a))
	  (should (context-panels--panel-window-for-source-p
		   (context-panels--visible-bottom-panel-window) source-a)))
      (dolist (name '("*context-panels-test-side-*context-panels-test-source-a**"
		      "*context-panels-test-side-*context-panels-test-source-b**"
		      "*Context View: test/inspect*"))
	(when (get-buffer name)
	  (kill-buffer name)))
      (when (buffer-live-p source-a)
	(kill-buffer source-a))
      (when (buffer-live-p source-b)
	(kill-buffer source-b))
      (setq context-panels--last-source-buffer nil)
      (setq context-panels--temporarily-hidden-p nil)
      (setq context-panels--desired-side-panel-p nil)
      (setq context-panels--desired-bottom-view-id nil)
      (delete-other-windows))))

(ert-deftest context-panels-propertize-key-adds-key-hint-face ()
  "Key-label helper highlights the featured key in a label."
  (let* ((label (context-panels-propertize-key "B-roll" "B"))
	 (face (get-text-property 0 'face label)))
    (should (equal (substring-no-properties label) "B-roll"))
    (should (eq face 'context-panels-key-hint-face))))

(ert-deftest context-panels-open-falls-back-when-side-window-display-fails ()
  "Opening a context panel falls back instead of returning an invisible buffer."
  (let ((source (get-buffer-create "*context-panels-test-fallback-source*")))
    (unwind-protect
	(progn
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :side-panel-buffer-name "*context-panels-test-fallback-panel*"
		 :collect-side-items (lambda (_source) nil)))
	  (cl-letf (((symbol-function 'display-buffer-in-side-window)
		     (lambda (&rest _args) nil)))
	    (let ((panel-buffer (context-panels-open source)))
	      (should (buffer-live-p panel-buffer))
	      (should (get-buffer-window panel-buffer (selected-frame))))))
      (when (get-buffer "*context-panels-test-fallback-panel*")
	(kill-buffer "*context-panels-test-fallback-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source)))))

(ert-deftest context-panels-register-provider-requires-icon ()
  "Provider registration fails fast when :icon is missing."
  (with-temp-buffer
    (context-panels-mode 1)
    (should-error
     (context-panels-register-provider
      (list :name 'missing-icon
	    :collect-side-items (lambda (_source) nil)))
     :type 'error)))

(ert-deftest context-panels-mode-line-counts-use-visible-viewport-total ()
  "Mode-line counts group visible, viewport, and total items by effective icon."
  (let ((source (get-buffer-create "*context-panels-test-count-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "one\ntwo\nthree\nfour\n")
	  (let ((visible-anchor (progn (goto-char (point-min))
				       (forward-line 1)
				       (point)))
		(hidden-anchor (progn (forward-line 1) (point))))
	    (add-to-invisibility-spec '(context-panels-test-fold . t))
	    (let ((overlay (make-overlay hidden-anchor (line-end-position))))
	      (unwind-protect
		  (progn
		    (overlay-put overlay 'invisible 'context-panels-test-fold)
		    (context-panels-mode 1)
		    (context-panels-register-provider
		     (list :name 'test
			   :icon "🤖"
			   :side-panel-buffer-name "*context-panels-test-count-panel*"
			   :collect-side-items
			   (lambda (_source)
			     (list (list :id 'visible :label "visible"
					 :icon "☁️" :anchor-pos visible-anchor)
				   (list :id 'hidden :label "hidden"
					 :anchor-pos hidden-anchor)))
			   :render-side-item
			   (lambda (_source item)
			     (insert (plist-get item :label) "\n"))))
		    (let ((panel-buffer (context-panels-open source)))
		      (with-current-buffer panel-buffer
			(should (equal (substring-no-properties
					context-panels-mode-line-counts)
				       "☁️1/☁️1 🤖1/☁️1 🤖1")))))
		(delete-overlay overlay)
		(remove-from-invisibility-spec '(context-panels-test-fold . t))))))
      (when (get-buffer "*context-panels-test-count-panel*")
	(kill-buffer "*context-panels-test-count-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(ert-deftest context-panels-mode-line-counts-render-empty-segments ()
  "Empty mode-line count segments render as ∅."
  (let ((source (get-buffer-create "*context-panels-test-empty-count-source*")))
    (unwind-protect
	(progn
	  (delete-other-windows)
	  (switch-to-buffer source)
	  (erase-buffer)
	  (insert "source\n")
	  (context-panels-mode 1)
	  (context-panels-register-provider
	   (list :name 'test
		 :icon "🧪"
		 :side-panel-buffer-name "*context-panels-test-empty-count-panel*"
		 :collect-side-items (lambda (_source) nil)))
	  (let ((panel-buffer (context-panels-open source)))
	    (with-current-buffer panel-buffer
	      (should (equal (substring-no-properties context-panels-mode-line-counts)
			     "∅/∅/∅")))))
      (when (get-buffer "*context-panels-test-empty-count-panel*")
	(kill-buffer "*context-panels-test-empty-count-panel*"))
      (when (buffer-live-p source)
	(kill-buffer source))
      (delete-other-windows))))

(provide 'context-panels-test)
;;; context-panels-test.el ends here
