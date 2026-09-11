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
  key encoding. Queue admission now lives beside the queue's capacity policy.
- **Composition:** shared dialog framing and painter insets provide reusable UI
  operations; the path editor owns its rendering and caret placement. Styles
  remain caller-supplied, with the application palette in `ui/theme.zig`.

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

- A Command/action registry could eventually unify keyboard dispatch, footer
  labels, and help. Introduce it with configurable bindings or plugin actions,
  when the command interface has concrete requirements.
- Directory scans and file operations both use workers, but scans supersede
  pending requests and transfer snapshots while operations report partial
  progress. A generic worker framework would currently obscure those different
  ownership and cancellation rules.
- Keep the retained widget tree and Observer/signals work in the existing plan;
  this cleanup supplies small reusable painting primitives without defining the
  future widget or plugin API prematurely.

## Verification

Run `zig build test`, `zig build test-integration`, `zig build fmt-check`,
`ruff check tests`, and `ruff format --check tests`. Unit coverage includes tiny
dialogs, wide glyph clipping, modal cleanup, and editor caret positioning; PTY
checks exercise browsing, file operations, and persistent shell behavior.
