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

### Native active highlighting

When a side panel is visible, `context-panels` highlights the active mapping between source and side panel:

- If point is in the source window, every visible side item whose source range contains point is highlighted.
- If point is in the side panel, the side item at point highlights its target source range without moving source point.
- The selected window wins; if neither source nor side panel is selected, source point is used as a fallback.
- Multiple side items may be highlighted.  Only one source range is highlighted, chosen from the first active item.
- Highlighting never scrolls the source window.
- When source navigation makes the active side item fall outside the side-panel viewport, `context-panels-reveal-active-side-item` can scroll the side panel just enough to reveal it. This is enabled by default and only applies when the selected window is the source. Image rows can make visibility checks optimistic, so items that are visible but near the bottom of the side window may also be revealed.
- Closing the side panel clears native highlights.

Side items can describe their source target with `:source-start` and `:source-end`.  If only `:anchor-pos` or `:source-start` is present, the source highlight expands to that logical line.

Providers can customize active ranges and faces:

| Key | Scope | Meaning |
|-----|-------|---------|
| `:active-source-range` | provider | Function `(SOURCE-BUFFER ITEM) -> (START . END)` overriding generic item range metadata. |
| `:active-face` | provider | Common active face for both source range and side row. Preferred default for mental mapping. |
| `:active-source-face` | provider | Source-only active face override. |
| `:active-side-face` | provider | Side-only active face override. |
| `:face` | item | Common active face for this item. |
| `:source-face` | item | Source-only active face for this item. |
| `:side-face` | item | Side-only active face for this item. |

Face resolution prefers item-specific values, then provider-specific values, then `context-panels-active-face`. The common `:active-face` / `:face` path is the norm so users can visually map source highlights to side-panel rows.
