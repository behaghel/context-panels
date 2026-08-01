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
                 :side-panel-buffer-name "*context-panels-test-panel*"
                 :collect-side-items (lambda (_source) nil)))
          (let ((panel-buffer (context-panels-open source)))
            (should (buffer-live-p panel-buffer))
            (should (get-buffer-window panel-buffer (selected-frame)))))
      (when (get-buffer "*context-panels-test-panel*")
        (kill-buffer "*context-panels-test-panel*"))
      (when (buffer-live-p source)
        (kill-buffer source)))))

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

(provide 'context-panels-test)
;;; context-panels-test.el ends here
