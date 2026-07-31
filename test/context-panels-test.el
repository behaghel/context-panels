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

(provide 'context-panels-test)
;;; context-panels-test.el ends here
