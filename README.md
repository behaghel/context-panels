# context-panels

Reusable Emacs context-panel primitives for source buffers.

`context-panels.el` is mode-agnostic: providers register side items, source overlays, top markers, and bottom views. Standard rows and source-anchor jumps work from item data; custom renderers and jump handlers remain available. `context-panels-org.el` adds optional Org body formatting, Org source detection, and top-marker placement after leading `#+KEY:` metadata.

## Minimal plain-text provider

```elisp
(add-to-list 'load-path "~/ws/context-panels")
(require 'context-panels)

(defun my-notes-provider ()
  (list :name 'notes
        :icon "📝"
        :collect-side-items
        (lambda (_source)
          (list (list :id 'top :label "Top of buffer"
                      :body "A plain-text note." :anchor-pos (point-min))))))

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

Provider plists use a compact item-rendering protocol. Side-panel providers declare `:name`, `:icon`, and `:collect-side-items`. A collector returns semantic item plists; it does not need to precompute panel placement. Whole-panel body renderers are intentionally unsupported: the framework composes rows so viewport alignment, highlighting, and mode-line counters stay consistent.

Standard rendering and navigation are available in version 0.2.0:
- `:label` (falling back to `:id`) supplies the header; `:body` is plain text.
- Item `:icon` overrides the provider icon. Optional `:icon-face` overrides `context-panels-item-icon-face`.
- `:source-start`, `:target-start`, `:reference-pos`, or `:anchor-pos`, in that order, supplies the default jump target. Missing, inaccessible, or foreign-buffer anchors raise a user error without switching buffers.
- Rows carry `context-panels-item` metadata and row-local terminal `RET`/graphical Return bindings. Existing provider/button keymaps, help text, and the panel's major-mode map are preserved; row bindings do not leak beyond the row.
- Optional `:render-side-item` and `:jump-side-item` callbacks take priority over these defaults. Rich providers can keep their renderers and actions unchanged.

An Org provider can require `context-panels-org` and set `:render-side-item` to `context-panels-org-render-side-item`. It reuses standard headers and interaction while fontifying only the body and indenting wrapped list continuations. It neither changes the panel major mode nor runs user Org mode hooks. `context-panels-org-insert-body` is also reusable from custom renderers; its formatting stays inside the inserted body.

Additional provider keys include `:jump-side-item`, `:collect-top-markers`, `:collect-bottom-views`, `:refresh-source-overlays`, `:cleanup-source-overlays`, `:follow-source-p`, `:side-panel-mode`, `:side-panel-buffer-name`, and `:side-panel-width`.

### Declarative side-item presentation

An optional `:present-side-item` callback receives `(SOURCE ITEM)` and returns
presentation-only fields. Context Panels applies them to a copy of each collected
item and shares that snapshot between rows and counters. Original records and
semantic identity/anchor fields remain unchanged. A custom `:render-side-item`
retains precedence and bypasses this optional presentation callback.

- `:icon` and `:icon-face` supply the row/count icon while preserving native text properties.
- `:label` supplies header text. Explicit nil puts the body immediately after the
  icon, without a header or an internal-ID fallback. Wrapped lines align with the body.
- `:details` supplies optional ordered metadata lines, preserving provider faces.
- `:render-body` receives `(SOURCE ITEM)` and inserts domain-specific body content;
  the default inserts `:body` as plain text. Nested row identities are preserved.
- `:properties` supplies additional native row text properties without replacing
  properties already supplied by nested body content.
- `:help` supplies contextual help text or a `(SOURCE ITEM)` help function.
  Functions run only on explicit help requests, never as native hover callbacks.

The optional Org library provides `context-panels-org-render-item-body` for the
body callback. Providers retain semantic labels, statuses, authors and actions;
the framework does not define a taxonomy or infer comment workflows from notes.

### Rendered-row navigation and item help

`context-panels-next-row` and `context-panels-previous-row` traverse the retained
rendered rows across providers and wrap at the ends. They keep panel focus and do
not move source point, scroll the source or recollect providers. Existing
`context-panels-next-item` / `context-panels-previous-item` retain their distinct
source-navigation behavior.

Native row-local defaults bind `]c`, `[c` and `?` to row movement and
`context-panels-describe-item`; explicit provider/button maps retain precedence.
The help command uses a native help buffer and computes text in the originating
panel context. A provider may declare `:item-help (SOURCE ITEM)` for roots and
nested rows; an item-specific `:help` overrides it. Without a declaration, help
shows the item and primary-reference jump, not another provider's actions.

`context-panels-command-description` describes a command using a verified
currently effective binding, falling back to its public `M-x` name when no
binding applies. Help reads the retained item; it does not select a backend,
collect providers, execute an action or request authorization. Personal modal
bindings remain consumer-owned.

### Readable side items

Side panels wrap long body lines without changing their major-mode keybindings,
including windows narrower than Emacs's automatic partial-width truncation
threshold. The truncation override is buffer-local to the panel; other windows
keep their configured behaviour.
Headers use `context-panels-item-heading-face` in addition to any provider faces,
so provider colours and actions are retained.

Version 0.3.0 adds source-buffer-local presentation controls:
- `context-panels-side-item-spacing`: minimum blank lines between items, default 0.
- `context-panels-side-item-body-indent`: display indentation below the first header line, default 0.

For example, set these buffer-locally to 1 and 2 for separated, indented items.
Existing list continuation prefixes compose with the body indentation. These
controls change display properties, not semantic records, provider-specific
formats, source order, or source text. Source-viewport padding can add further
space when anchors are far apart.

### Synchronized focus

Providers may opt into synchronized side/bottom focus with a `:synced-focus`
plist.  It declares `:item-key`, `:current-key`, `:focus`, and
`:bottom-view-id`:

- `:item-key` receives `(SOURCE-BUFFER ITEM)` and returns the provider's stable
  semantic focus key, or nil when the item does not belong to that focus cohort.
- `:current-key` receives `SOURCE-BUFFER` and returns the provider's current key,
  or nil for a bottom context with no side row.
- `:focus` receives `(SOURCE-BUFFER KEY ITEM)` and applies side-originated focus.
- `:bottom-view-id` names the provider's paired bottom view.

Claims are exclusive: multiple providers claiming one item are a configuration
error.  Selecting a claimed side row synchronizes provider focus and switches an
already-visible bottom slot to the paired view; it never opens a closed bottom
panel.  Providers call `context-panels-notify-synced-focus` after changing focus
from a bottom view.  Notification moves an already-visible side panel without
opening one.  Non-participating rows do not interfere with synchronized focus.
Rendering preserves side point by stable item identity and never originates a
focus transition.

## Bottom views

Providers may expose one or more bottom views with `:collect-bottom-views`.  A bottom view is a plist with:

| Key | Meaning |
|-----|---------|
| `:id` | Provider-local view id. |
| `:label` | Human-readable label used by selection commands. |
| `:buffer-name` | Optional explicit buffer name. Defaults to `*Context View: provider/id*`. |
| `:height` | Optional side-window height. Defaults to `context-panels-bottom-height`. |
| `:mode` | Optional major mode enabled in the view buffer. |
| `:render` | Function `(SOURCE-BUFFER VIEW)` that inserts the view contents. |
| `:select` | Non-nil means opening this view selects its window. |
| `:docked` | Non-nil makes an explicitly displayed view a persistent fallback in its frame. |

Bottom views are opened explicitly; plain `context-panels-open` remains side-panel-only for compatibility.

```elisp
(context-panels-open-bottom-view 'inspect)
(context-panels-next-bottom-view)
(context-panels-select-bottom-view)
(context-panels-focus-bottom-view)
(context-panels-close-bottom-view)
```

Each provider/view gets its own buffer, while one bottom window is visible by default.  Cycling or selecting another view swaps the visible bottom-window buffer and leaves the other view buffers available for reuse.

### Docked fallback

A docked bottom view remains available independently of its source's visibility
or lifetime. When no source-specific bottom view occupies an open bottom slot,
the most recently explicitly displayed, still-live docked buffer is shown.
Source-specific views take precedence when their source returns. Automatic
restoration does not change dock recency or select the bottom window.

Dock history and explicit-close suppression belong to the displaying frame.
Docking does not open a closed panel. Explicitly closing a bottom view suppresses
automatic bottom restoration until a bottom view is explicitly opened again.
Killing a docked buffer removes it from fallback candidates; the next live dock
can take its place while the slot is open. `M-x context-panels-open-docked-view`
reopens a previously displayed dock even after its source has been killed.

Docked renderers accept nil as their source argument during fallback and must
not depend on a surviving source. Views adopted with
`context-panels-adopt-bottom-view-buffer` retain externally managed contents;
fallback never erases or rerenders adopted buffers. Closing, hiding, or replacing
a bottom view does not kill its buffer or stop work owned by that buffer.

A minimal docked provider can be evaluated in a scratch buffer:

```elisp
(switch-to-buffer (get-buffer-create "*Dock example source*"))
(text-mode)
(context-panels-mode 1)
(context-panels-register-provider
 (list :name 'dock-example :icon "♫"
       :collect-bottom-views
       (lambda (_source)
         (list (list :id 'player :label "Player" :docked t :height 6
                     :render (lambda (_source _view) (insert "Persistent player")))
               (list :id 'inspect :label "Inspect"
                     :render (lambda (_source _view) (insert "Source inspector")))))))
(context-panels-open-bottom-view 'player)
```

## Native provider tabs and navigation

The bottom panel has a native Emacs tab line for all available provider views,
not an application-specific buffer header. Active views have theme-derived
emphasis; inactive views remain quiet. Native horizontal scrolling keeps a long
view list usable. The `Views · C-c v` chooser is right-aligned, separate from the
left-aligned provider tabs. Painting the bar reads a retained view snapshot and never
collects providers, creates a buffer, renders a view or executes an action.

`C-Tab` selects the next view, `C-S-Tab` the previous view, and `C-c v` selects by
name using ordinary completion (including Vertico when enabled). These bindings
apply only in managed panel windows, not ordinary copies of adopted buffers or
minibuffers. Existing commands `context-panels-next-bottom-view` and
`context-panels-select-bottom-view` share the same identity-based navigation;
`context-panels-previous-bottom-view` provides the reverse direction.

Provider/view keys, not labels or indexes, identify tabs. Duplicate labels are
disambiguated in completion. Moving through or cancelling the chooser is passive.
Explicit selection preserves view point, scrolling and adopted-buffer contents;
keyboard navigation originating in a panel keeps focus in the replacement panel.
Selecting a view does not start playback, initialize an account or enable capture.
Closed side panels stay closed; existing declared synchronized-focus behavior is
preserved rather than inventing a new side-panel authority.

A view may supply `:buffer` with an already live buffer instead of `:buffer-name`
and `:render`. Such a buffer is adopted, never erased or recreated. The provider
is responsible for offering only valid existing buffers. View snapshots refresh
when a view is displayed or its source provider registry changes.

## Fixed bottom-view footer

Same-session native window-state restoration preserves managed panel roles,
point, scrolling and the selected source/body/footer without re-rendering provider
content. Footer ownership and tab/control caches are rebound to restored windows
only for a validated owned pair; ordinary copies of a panel buffer remain ordinary.
Window state stores a serializable role flag, not live window references or action
closures. Closed views stay closed. This applies to surviving same-session buffers,
not reconstruction of application state; no account, playback or capture
initialization is performed by the chrome restoration.

Every bottom view has a native footer at the bottom edge of its panel, separate
from its scrollable content. Scrolling and sorting the content do not scroll the
footer. The content and footer form one protected window group: switching or
closing the view never leaves an orphan footer or changes an ordinary source
window. Footer drawing preserves body point, scrolling and selected-window focus.

A view or its provider may declare `:footer`, a function `(SOURCE-BUFFER VIEW)`
called in the body buffer. It returns a plist with optional `:actions` and
`:metadata`. The callback reads retained presentation state only; rendering never
executes actions, fetches data or requests authorization. With no declaration, the
footer offers the generic `q Close` action.

Actions are plists with `:key`, `:label`, and interactive `:command`. Optional
`:primary` emphasizes the primary action; `:select` allows an explicit navigation
command to select its destination. Commands run in the body buffer and window,
not in the footer's buffer. Declaring a footer does not rebind the body's keys.

Metadata is optional text, such as a count and duration. It is right-aligned when
space permits and receives its own line when needed. Action keys are accented,
labels are neutral, and primary actions use a theme-derived success face. The
footer has a background-only surface, 16-pixel separation above it and 8-pixel
inner padding in graphical frames. Terminal frames retain native text controls.

`context-panels-footer-update` refreshes the footer of a visible body buffer
without opening a closed view or changing focus. The shared presentation has no
application-specific music, queue, account or transport behavior.

## Key hints

Use `context-panels-propertize-key` to highlight embedded command keys in labels or action text.  It applies `context-panels-key-hint-face` to the first matching key string:

```elisp
(insert (context-panels-propertize-key "B-roll" "B"))
```

### Native active highlighting

When a side panel is visible, `context-panels` highlights the active mapping between source and side panel:

- If point is in the source window, every visible side item whose source range contains point is highlighted.
- If point is in the side panel, the side item at point highlights its target source range without moving source point.
- The selected window wins; if neither source nor side panel is selected, source point is used as a fallback.
- Multiple side items may be highlighted.  Only one source range is highlighted, chosen from the first active item.
- Highlighting never scrolls the source window.
- When source navigation makes the active side item fall outside the side-panel viewport, `context-panels-reveal-active-side-item` can scroll the side panel just enough to reveal it. This is enabled by default and only applies when the selected window is the source. Image rows can make visibility checks optimistic, so items that are visible but near the bottom of the side window may also be revealed.
- Closing the side panel clears native highlights.
- Navigation highlights use the last rendered source item snapshot instead of recollecting providers on every command. Source text edits invalidate that snapshot; explicit panel refreshes and viewport renders rebuild it. Providers should refresh the panel after changing external state such as sidecars.
- A viewport render collects each provider once and shares the result across visible rows and counts. Viewport rebuilding is deferred until `context-panels-viewport-refresh-idle-delay` seconds of idle time (default 0.05), keeping scrolling commands off the synchronous render path.

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

## Development checks

The `Emacs checks` workflow exercises Emacs 30.2 on pull requests and pushes to
`main`. It discovers every `test/*-test.el` suite, rejects empty discovery, runs
ERT, and byte-compiles all `context-panels*.el` libraries with warnings treated
as errors. These checks require only Emacs's built-in libraries, not a personal
configuration or downloaded packages. CI uses temporary home/build directories,
read-only repository permissions, and commit-pinned actions; generated bytecode
is never written into the checkout. The complete batch commands are in
[the workflow](.github/workflows/emacs.yml).

To run all ERT suites from the repository root:

```sh
emacs --batch -Q -L . -l ert \
  --eval '(let ((files (directory-files "test" t "-test\\.el$"))) (unless files (error "No ERT suites found")) (dolist (file files) (load file nil t)))' \
  -f ert-run-tests-batch-and-exit
```
