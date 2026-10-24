# context-panels Agent Notes

## Emacs window lifecycle best practices
- Keep panel lifecycle tied to source-buffer visibility, not selected-window focus.
- A side/bottom panel should stay open while its `context-panels-source-buffer` is visible in any ordinary, non-auxiliary, non-minibuffer window.
- Do not hide panels just because selection moves to the minibuffer, side panel, bottom panel, or another visible window.
- Use `window-configuration-change-hook` for observation/scheduling only. Avoid creating, deleting, resizing, or selecting windows directly inside that hook.
- Debounce reconciliation with an idle timer; restore/select the previously selected window after reconciliation.
- For minibuffer-aware logic, remember that the selected window may be the minibuffer. Use visibility/window-list checks or `minibuffer-selected-window` when the command context matters.
- For future efficient layout restoration, prefer `window-state-get` / `window-state-put` over ad-hoc window reconstruction; native window state preserves side-window parameters such as side/slot.
- Side windows should keep protective parameters like `no-delete-other-windows` where appropriate so ordinary window commands do not collapse panel layout unexpectedly.

## Provider/icon invariants
- Provider `:icon` is required for mode-line counting.
- Item `:icon` is the row/counting semantic override.
- If a framework-level provider overwrites `:provider`, preserve semantic ownership separately before wrapping items (for example `:comment-provider`) so row icons and mode-line counters cannot diverge.
