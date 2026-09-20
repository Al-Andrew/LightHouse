# Code cleanup review

Reviewed the application, core, UI, Linux platform layer, terminal adapter,
build script, and Python integration suites before further feature work.

## Design patterns

- **State:** replaced independent help/editor/action/delete flags with an owned
  `Modal` tagged union. Only one modal payload can exist, an action belongs to
  its editor, and closing a modal releases its resources in one place. Confirming
  deletion transfers the prepared job to the running operation.
- **Strategy:** `directory.Provider` already separates directory scans from pane
  state through a callback and context. Keep this interface for new providers.
- **Adapter:** `terminal.Emulator` already isolates Ghostty state, rendering, and
  key and paste event encoding. The adapter captures paste framing mode once per
  paste, owns queue admission beside capacity policy, and exposes semantic page
  scrolling. Application code consumes these operations without inspecting
  Ghostty fields. Layout owns presentation size bounds and accepts toolkit
  geometry; host conversion stays in the event loop alongside synchronized
  emulator/PTY resizing.
- **Composition:** shared dialog framing and painter insets provide reusable UI
  operations; the path editor owns its rendering and caret placement. Styles
  remain caller-supplied, with the application palette in `ui/theme.zig`.
- **File-job lifecycle:** an opaque `Job` owns preparation, launch failure,
  cancellation, worker collection, and result lifetime. Only polling publishes
  completion, once; status reads are observational. The opaque controller owns
  confirmation, collection, both-pane refresh, result dismissal, and shutdown
  cleanup. Widgets borrow read-only payload views; App only schedules polling.
  Cancellation requests do not overwrite an operation's actual outcome.
- **Pane ownership:** an opaque `Pane` owns cursor movement, marking, viewport
  maintenance, listing-option changes, and source selection. Painting consumes
  a read-only view with parent rows already mapped. Layout supplies the visible
  row count; navigation and scan publication keep the cursor visible even when
  painting is skipped. Requested options survive cancellation or failure while
  displayed options describe the last published listing. Borrowed views and
  source iterators are consumed before the next pane mutation; file jobs still
  copy their requests into owned storage.

## Repetition and library helpers

- Four dialogs now use `ui/dialog.zig` for centering, clipping, filling, borders,
  and hiding the underlying cursor. Dialogs and file panes share `Painter.inset`.
- Path-field text layout and horizontal scrolling moved from `app.zig` into
  `PathInput.paint`. Both UI helpers are exposed through the library root.
- Repeated palette values moved into named theme entries.
- Bracketed-paste markers and ASCII control-key encoding are shared input helpers.
- PTY setup, screen decoding, waiting, navigation, and pasted submission live in
  `tests/support.py`; test suites no longer import one another.
- Integration build steps use one registration loop, and library test imports
  are collected in a single block.

## Formatting and numbers

- Zig sources use `zig fmt`; the build exposes `fmt` and `fmt-check` steps.
- Python sources use Ruff formatting and sorted imports.
- Named layout thresholds, dialog widths, metadata column sizes, Escape/poll
  timing, read batches, queue/scrollback capacities, recursion depth, copy buffer
  size, editor length, terminal geometry bounds, and shutdown timing.
- Filesystem buffers use `std.Io.Dir.max_path_bytes`. Cursor shapes use a typed
  DECSCUSR enum. The upper date bound identifies its UTC date.
- Kept literal protocol mappings with explanatory comments and ordinary geometry
  arithmetic where the meaning is already apparent. Test fixture sizes remain
  local to their scenarios.

## Deferred abstractions

- Static built-in command descriptions now unify binding lookup, help, and the
  ten-slot function-key bar. The controller owns availability and invocation;
  widgets retain scoped input routing. See [UI.md](UI.md) for the interface.
  Configurable bindings, persistence, and runtime/plugin registration remain
  deferred; the static built-ins do not require a callback registry.
- Directory scans and file operations both use workers, but scans supersede
  pending requests and transfer snapshots while operations report partial
  progress. A generic worker framework would currently obscure those different
  ownership and cancellation rules.
- The retained widget foundation is now a separate `lighthouse-ui` build module.
  It owns tree lifetime, focus/modal routing, layout, invalidation, and clipped
  painting; file panes, terminal bindings, dialogs, and theme live in the app.
  See [UI.md](UI.md) for its interface and lifetime rules. Observer/signals and
  the plugin ABI remain in the plan.

## Verification

Run `zig build test`, `zig build test-integration`, `zig build fmt-check`,
`ruff check tests`, and `ruff format --check tests`. Unit coverage includes tiny
dialogs, wide glyph clipping, modal cleanup, and editor caret positioning; PTY
checks exercise browsing, file operations, and persistent shell behavior.
File-job tests use the caller's lifecycle interface. Launch failure uses
`std.Io.failing`; cancellation tests gate real filesystem calls through a test
I/O adapter, so ordering does not depend on large files or directory trees.
Pane tests use its caller-facing interface and cover requested versus displayed
options during canceled, failed, and superseded scans; viewport maintenance
without painting; and source selection after sorting, hiding, and refresh.
