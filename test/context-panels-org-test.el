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

(provide 'context-panels-org-test)
;;; context-panels-org-test.el ends here
