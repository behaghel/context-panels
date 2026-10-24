# Spec: Context panel mode-line counters

## Problem
Context-panel side buffers must reserve their buffer text for vertically aligned provider rows only. Header text, source identity, and count metadata in the body breaks native row alignment and adds visual noise. Users still need compact awareness of how many context entries are rendered, in viewport, and available in the full source.

## Scope
Implement generic side-panel mode-line counters in `context-panels` and update in-repo providers/tests to satisfy the provider icon contract.

Out of scope:
- Provider-specific filter labels or state fragments.
- Source buffer identity in the mode-line.
- Header-line UI.
- Counting top markers or bottom views.
- Enforcing that rendered row text starts with the item/provider icon.

## Model
Each registered provider must declare a top-level `:icon` string. `context-panels-register-provider` must fail fast when `:icon` is missing or not a non-empty string.

Each side item may declare `:icon`; item icon overrides provider icon for counting/rendering semantics. The effective icon is:

1. item `:icon`, when present and non-empty;
2. provider `:icon`.

Rows are still provider-rendered. The icon contract is a convention for row rendering, not runtime-enforced against output text.

## Counts
The side-panel mode-line shows three count segments:

`visible/viewport/total`

Each segment groups counts by effective icon, hides zero-count groups, and uses `∅` when the segment is empty.

Example:

`☁️2 🤖1/☁️3 ✍️1 🤖1/☁️12 ✍️4 🤖3`

Definitions:

- `visible`: rendered side-panel rows after provider filters, viewport projection, and generic hidden/folded-anchor suppression.
- `viewport`: provider-collected items whose source position is within the current source viewport before filters/hiding. Hidden or folded anchors still count if their position is in the viewport range.
- `total`: raw provider-collected side items for the full source before generic hidden/folded-anchor suppression.

Only side-panel items are counted. Top markers and bottom views are not included.

Counters update as part of side-panel rendering only. They do not update independently on scroll/window changes outside the existing render lifecycle.

Counters are identical regardless of whether the selected window is the source or the side panel.

## Panel lifecycle
Side and bottom panels are owned by a source buffer, not by the currently selected window. Once panels are open, they must remain open for as long as their source buffer remains visible in any ordinary non-auxiliary window on the frame.

Selecting the minibuffer, a side panel, a bottom panel, an ignored sidecar, or another buffer in a different visible ordinary window must not hide or recreate the panels while the original source is still visible. Hiding happens only when the panel-owned source buffer is removed from the visible window layout, for example when its source window switches to another buffer or is deleted.

When the source becomes visible again and has remembered desired panel state, the side and bottom panels may be restored. Reconciliation should be debounced and should avoid unnecessary rerendering of already-correct visible panels, especially editable bottom views.

## Formatting
- No label prefix (`Ctx:` is omitted).
- No source buffer identity.
- Compact slash separators: `/`.
- Provider groups inside a segment are separated by one normal space.
- Empty segment: `∅`.
- Segment faces apply to the whole segment, including icons and digits:
  - visible: emphasized mode-line face;
  - viewport: normal mode-line face;
  - total: shadow/subdued mode-line face.

## Acceptance Criteria
1. Side-panel body contains only provider-rendered rows; no generic count/header/source text is inserted by `context-panels`.
2. Registering a provider without non-empty string `:icon` signals an error.
3. Items with `:icon` are counted under that icon; otherwise their provider `:icon` is used.
4. Mode-line renders `visible/viewport/total` with compact separators and per-segment faces.
5. Zero-count provider groups are omitted per segment.
6. Empty segments render as `∅`.
7. `visible` excludes hidden/folded anchors that are not rendered.
8. `viewport` includes hidden/folded anchors if their source position is in the viewport range.
9. `total` includes all raw provider-collected side items for the source.
10. Counters update during side-panel render and remain stable across source/panel focus changes.
11. Tests cover single-provider, multi-provider, item-icon override, empty segment, missing provider icon, hidden/folded viewport-vs-visible semantics, and total raw-count semantics.
12. Panels remain visible when their source remains visible, even if another window or the minibuffer is selected.
13. Panels hide only after their owning source disappears from the visible ordinary-window layout.
14. Restoring panels for a re-visible source preserves per-source desired side and bottom view state.

## Implementation Notes
Likely `context-panels` changes:
- Add provider validation in `context-panels-register-provider`.
- Add helpers for effective item icon and grouped count formatting.
- Track side-panel count state as buffer-local data during `context-panels-render-side-panel`.
- Set side-panel `mode-line-format` or a buffer-local mode-line segment during side-panel setup/render.
- Add a raw collection path for `total` that does not call `context-panels-item-hidden-p`.
- Add a viewport collection/count path that checks source positions against `window-start`/`window-end` without excluding invisible anchors.

Provider updates:
- `org-comments` provider declares a default `:icon`.
- Comment items expose their row/effective icon (`☁️`, `✍️`, `🤖`) via `:icon` so mode-line grouping matches row-leading icons.
- `org-marginalia` and tests declare provider icons.

Lifecycle notes:
- Track the panel-owned source from visible panel buffers first (`context-panels-source-buffer`), then verify that source is still visible with ordinary-window checks.
- Only fall back to the selected source when there is no still-visible panel-owned source.
- Keep `window-configuration-change-hook` work debounced and observational; schedule reconciliation rather than mutating layout directly from the hook.
- `post-command-hook` should not hide panels merely because point moved to the minibuffer or an auxiliary panel.
