;;; context-panels-org.el --- Org helpers for context-panels -*- lexical-binding: t; -*-

;; Author: Hubert Behaghel
;; Maintainer: Hubert Behaghel
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6") (context-panels "0.1.0"))
;; Keywords: outlines, tools, convenience
;; URL: https://github.com/behaghel/context-panels

;;; Commentary:
;; Optional Org-specific defaults and helpers for `context-panels'.

;;; Code:

(require 'context-panels)
(require 'org)

(defgroup context-panels-org nil
  "Org integration helpers for context panels."
  :group 'context-panels)

(defcustom context-panels-org-ignored-source-file-suffixes
  '(".comments.org" ".copilot.org" ".suggestions.org"
    ".comments.org_archive" ".copilot.org_archive" ".suggestions.org_archive")
  "Org auxiliary file suffixes that should not become context-panel sources."
  :type '(repeat string)
  :group 'context-panels-org)

(defun context-panels-org-metadata-end-position ()
  "Return position after leading Org metadata keywords."
  (save-excursion
    (goto-char (point-min))
    (while (looking-at-p "^[\t ]*#\\+[^\n:]+:.*$")
      (forward-line 1))
    (point)))

(defun context-panels-org-source-buffer-p (buffer)
  "Return non-nil when BUFFER is an Org context-panel source buffer."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
	 (derived-mode-p 'org-mode))))

(defun context-panels-org-install-defaults ()
  "Install Org defaults for context-panel source detection."
  (setq-local context-panels-source-buffer-predicate
	      #'context-panels-org-source-buffer-p)
  (setq-local context-panels-ignored-source-file-suffixes
	      context-panels-org-ignored-source-file-suffixes)
  (setq-local context-panels-marker-position-function
	      #'context-panels-org-metadata-end-position))

(cl-defun context-panels-org-make-top-marker (&rest args
					     &key position &allow-other-keys)
  "Create an Org-aware top marker from ARGS.
When POSITION is nil, place the marker after leading Org metadata keywords."
  (apply #'context-panels-make-top-marker
	 (append (unless position
		   (list :position (context-panels-org-metadata-end-position)))
		 args)))

(defun context-panels-org-marker-position (overlay &optional fallback-predicate)
  "Return Org marker OVERLAY position, or metadata fallback position."
  (cond
   ((overlayp overlay)
    (overlay-start overlay))
   ((and fallback-predicate (funcall fallback-predicate))
    (context-panels-org-metadata-end-position))))

(defun context-panels-org-marker-at-point-p (overlay &optional fallback-predicate)
  "Return non-nil when point is at Org marker OVERLAY or fallback position."
  (and (derived-mode-p 'org-mode)
       (equal (point) (context-panels-org-marker-position overlay fallback-predicate))))

(provide 'context-panels-org)
;;; context-panels-org.el ends here
