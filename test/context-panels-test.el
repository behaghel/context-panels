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
