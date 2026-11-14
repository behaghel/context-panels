;;; context-panels-org-test.el --- Tests for Org context panel helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for Org-specific context panel helpers.

;;; Code:

(require 'ert)
(require 'context-panels-org)

(ert-deftest context-panels-org-metadata-position-skips-keywords ()
  "Org marker helper places markers after leading metadata."
  (with-temp-buffer
    (org-mode)
    (insert "#+TITLE: Example\n#+AUTHOR: Alice\n\nBody\n")
    (should (= (context-panels-org-metadata-end-position)
	       (save-excursion
		 (goto-char (point-min))
		 (forward-line 2)
		 (point))))))

(ert-deftest context-panels-org-install-defaults-uses-org-predicate ()
  "Org defaults restrict source detection to Org buffers."
  (with-temp-buffer
    (text-mode)
    (context-panels-org-install-defaults)
    (should-not (context-panels--eligible-source-buffer-p (current-buffer)))
    (org-mode)
    (should (context-panels--eligible-source-buffer-p (current-buffer)))))

(ert-deftest context-panels-org-standard-row-fontifies-and-wraps-without-hooks ()
  "Org rows share standard headers while body formatting stays optional."
  (let (hook-ran)
    (with-temp-buffer
      (special-mode)
      (let ((inhibit-read-only t)
	    (org-mode-hook (list (lambda () (setq hook-ran t)))))
	(context-panels-org-render-side-item
	 nil '(:id "note" :icon "✣"
		   :body "- A *bold* note\n1. Another note\n[[https://example.invalid][A link]]")))
      (should (eq major-mode 'special-mode))
      (should-not hook-ran)
      (goto-char (point-min))
      (should (looking-at-p "✣ note"))
      (search-forward "bold")
      (should (memq 'bold (ensure-list (get-text-property (1- (point)) 'face))))
      (should (equal (get-text-property (1- (point)) 'wrap-prefix) "  "))
      (search-forward "Another")
      (should (equal (get-text-property (point) 'wrap-prefix) "  "))
      (search-forward "A link")
      (dolist (key '("RET" "<return>"))
	(should (eq (key-binding (kbd key)) #'context-panels-jump-at-point))))))

(ert-deftest context-panels-org-body-formatting-does-not-touch-following-content ()
  "Formatting an inserted body leaves existing following rows unchanged."
  (with-temp-buffer
    (insert "- Existing row\n")
    (goto-char (point-min))
    (context-panels-org-insert-body "- New body\n")
    (search-forward "Existing")
    (should-not (get-text-property (point) 'wrap-prefix))))

(provide 'context-panels-org-test)
;;; context-panels-org-test.el ends here
