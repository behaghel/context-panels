# context-panels

Reusable Emacs context-panel primitives for source buffers.

`context-panels.el` is mode-agnostic: providers register side items, source overlays, top markers, bottom views, renderers, and jump handlers. `context-panels-org.el` adds Org-specific defaults such as Org source detection and placing top markers after leading `#+KEY:` metadata.

## Minimal plain-text provider

```elisp
(add-to-list 'load-path "~/ws/context-panels")
(require 'context-panels)

(defun my-notes-provider ()
  (list :name 'notes
        :collect-side-items
        (lambda (_source)
          (list (list :id 'top :label "Top of buffer" :anchor-pos (point-min))))
        :render-side-item
        (lambda (_source item)
          (insert (format "- %s\n" (plist-get item :label))))
        :jump-side-item
        (lambda (source item)
          (pop-to-buffer source)
          (goto-char (plist-get item :anchor-pos)))))

(context-panels-register-provider (my-notes-provider))
(context-panels-mode 1)
(context-panels-open)
```

## Org defaults

```elisp
(require 'context-panels-org)
(context-panels-org-install-defaults)
(context-panels-mode 1)
```

## Provider protocol

Provider plists may use the same protocol keys as the original `org-context-panel` extraction, including `:name`, `:collect-side-items`, `:render-side-panel`, `:render-side-item`, `:jump-side-item`, `:collect-top-markers`, `:collect-bottom-views`, `:refresh-source-overlays`, `:cleanup-source-overlays`, `:follow-source-p`, `:side-panel-mode`, `:side-panel-buffer-name`, and `:side-panel-width`.
