# LightHouse

A Zig TUI file manager in development: dual panes, a handmade UI toolkit, an
integrated libghostty terminal, and native shared-library plugins.

The current build provides **keyboard-driven dual-pane browsing**, copy, move/rename,
folder creation, deletion, and a persistent terminal. Its retained UI foundation is
an independent build module, with file-manager widgets composed in the app.
Further file actions, additional widgets, signals/slots, and native plugin loading
remain in [the plan](docs/PLAN.md).

## Run

Requires **Zig 0.16.0**, Linux, and an interactive UTF-8 terminal with xterm-style
control sequences and truecolor support. Dependencies are fetched by Zig on the
first build. No existing TUI or GUI framework is used.

```sh
zig build run
```

The embedded shell defaults to `$SHELL`, falling back to `/bin/sh`. It inherits
the launch directory and remains alive across focus changes and resizing.

```sh
zig build run -- --shell /bin/bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/lighthouse
```

`./zig-out/bin/lighthouse --help` works without an interactive terminal.

Application and library logs are kept off the live terminal, where they would
scroll or overwrite the UI. To capture diagnostics, redirect stderr:

```sh
zig build run 2>lighthouse.log
```

The embedded shell's stderr still appears in its terminal pane. Fatal application
errors are printed after the outer terminal is restored. Debug builds include
Ghostty's debug messages in the redirected log.

## Controls

The application starts with the left pane focused. Focus is indicated by its
border; the shell shows its cursor when focused. Each pane's path is its border
title, and the terminal sits directly below the panes. The bottom function-key
bar uses ten evenly spaced Far-style slots: F1 Help, F5 Copy, F6 RenMov,
F7 Mkdir, F8 Delete, and F10 Quit are active;
unassigned keys have blank labels. All application actions dim while
the shell is focused, where function keys pass through to the child.

| Key | Action |
| --- | --- |
| Ctrl+G | Switch focus between the visible shell and last active Pane; leave zoom |
| Ctrl+J | Hide/show the shell; start a fresh session if absent |
| Up / Down / PageUp / PageDown / Home / End | Move the file cursor |
| Enter / Right | Enter a directory or directory symlink |
| Backspace / Left | Go to the parent and focus the directory just left |
| Tab | Switch file pane |
| Space / Insert | Toggle a mark / toggle a mark and advance |
| Shift+Up / Shift+Down | Toggle the current mark and move |
| Shift+Home / Shift+End | Toggle marks through the first/last row |
| Ctrl+L | Edit the active pane's path; typing replaces the initial selection |
| / | Enter an absolute path, starting with `/` |
| Ctrl+R | Refresh the active pane and redraw |
| Escape | Cancel a pending directory read or dismiss its error |
| . | Toggle hidden entries in the active pane |
| s / r | Cycle name, size, modified-time sorting / reverse sort direction |
| F1 | Show keyboard help |
| F5 / F6 | Copy / move or rename marked entries, or the cursor entry |
| F7 | Create a directory in the active pane |
| F8 | Confirm permanent deletion of marked entries or the cursor entry |
| t | Focus the shell |
| + / - | Grow / shrink the bottom terminal |
| z | Expand and focus the shell |
| Shift+PageUp / Shift+PageDown | Scroll terminal history |
| q / F10 | Quit and end the embedded session |

Except for Ctrl+G and Ctrl+J, the pane bindings above apply while a file pane is focused.
Path entry accepts absolute paths, paths relative to the current pane, and
`~/` paths. Enter opens the location; Escape cancels; Ctrl+U clears the field.
Left/Right/Home/End and Backspace/Delete edit the path. Opening the path field
cancels earlier navigation so relative paths keep the same base while editing.
Pasting into this field never sends commands to the shell.

Each pane starts in the launch directory and keeps its own location, cursor,
marks, scroll position, hidden-file setting, and sorting. Directories sort first.
Name sorting ignores ASCII case with an exact-byte tie break. Dates, when the
pane is wide enough to show them, use UTC; sorting uses the full modification
timestamp. `/` marks a directory, `@` a symlink, and `*` a marked entry.

Directory scans and sorting run concurrently with the UI. New requests supersede
older scans. A failed read preserves the last good location and listing and shows
the error in that pane. Refresh and sorting preserve visible marks and the cursor
by name; navigation to a different directory resets marks. Hiding an entry clears
its mark. Refresh is explicit; filesystem watching is not implemented yet.
Canceled or failed scans retain the requested sorting and hidden-file settings
for the next scan. The displayed listing keeps its previous settings until a
scan succeeds; cycling sort again advances from the requested setting.

Hold Shift while using Up/Down to toggle the current item's mark before moving:
unmarked items become marked, and marked items become unmarked. Shift+Home/End
toggles every item between the cursor and the first/last row, including both
endpoints. The parent row is always skipped. Space/Insert also toggles individual
marks. Unmodified navigation leaves marks in place, and each pane keeps its own
marks. Shift+PageUp/PageDown retains its terminal-history scrolling behavior.

F5/F6 open a destination field prefilled with the other pane's directory. Marked
entries take precedence over the cursor; the parent entry is never a source.
An existing destination directory receives the source names. For one source, a
new destination path gives it a new name. Multiple sources require an existing
directory. Relative paths use the active source pane; absolute and `~/` paths
also work. F7 creates a single folder; its parent must already exist. Enter
starts the action, Escape cancels the dialog, and Ctrl+U clears the field.

F8 shows a confirmation for the marked entries, or the cursor entry when none
are marked. Enter confirms permanent deletion; Escape or `n` cancels. Folders
are deleted recursively, including hidden children. Symlinks themselves are
removed without following their targets, including directory and broken links.
Deletion does not use a trash folder and cannot be undone. The job reports both
completed top-level items and the number of entries removed. Canceling or failing
partway through a folder leaves any remaining entries in place; earlier removals
are permanent. The parent entry can never be a deletion source.

File jobs run outside the UI thread and show completed top-level items and bytes
copied. Escape requests cancellation. File jobs block terminal interaction until
the result is dismissed; the shell keeps running and its output is drained.
Enter/Escape dismisses the result, and both panes refresh after every
job, including failures and cancellation. Only one file job runs at a time.
Quitting cancels and joins the worker before shutdown.

Copies include hidden children, preserve symlinks as links (including broken
links), and support regular files and directories. A copied regular file is
published atomically after its data is complete. Existing destinations are
always refused, including dangling symlinks; directories are not merged. A job
stops at its first error and reports the path and completed item count. Completed
items remain; an interrupted directory copy may leave a partial directory, but
an unfinished regular file is not published. A changing regular file is rejected
if its size or timestamps change during copying.

Moves/renames currently use an atomic rename on the same filesystem. Moves
between filesystems fail with the source retained. Overwrite/skip prompts,
cross-filesystem moves and recursive parent creation are later work.
Copies do not preserve ownership, ACLs, extended attributes, sparse allocation,
or hard-link relationships. Recursive copying and deletion are limited to 128 levels.

Filenames retain their original bytes for navigation. Non-displayable bytes are
shown as escapes (for example, a newline appears as `\x0A`), while Unicode
characters are rendered and clipped at grapheme boundaries. Long path headers
show their trailing components.

Browsing does not change the shell's working directory, and a shell `cd` does
not change either pane. Opening regular files in an editor/viewer and explicit
pane-to-shell directory synchronization are later work.

While the shell is focused, keys such as Tab, Ctrl+C, Ctrl+D, q, and function keys
are sent to the child application. **Ctrl+G switches focus** and **Ctrl+J hides/shows the terminal**. Bracketed paste is routed as paste, including any shortcut bytes in its
payload. Typing in the terminal returns its viewport to the current output.

Shell exit closes only its session. Ctrl+J, t, or z can start a new shell using
the original shell choice and the active Pane’s local directory. A missing or
inaccessible local directory is reported; non-local Panes use the launch directory.
Hiding preserves the running program and chosen split size, and gives its space
to the Panes. Ctrl+G does nothing while the terminal is hidden or absent.
Conventional terminals cannot distinguish Ctrl+J from an Enter key sending LF;
CR Return and pasted LF keep their usual behavior.

Small terminal windows temporarily display only the visible terminal and the function-key bar.
Pane controls still work after Ctrl+G. Enlarging the window restores both panes.

## Implementation

- `src/platform/linux.zig`: raw terminal mode, signal cleanup, PTY creation,
  resizing, and shell shutdown/reaping.
- `src/ui/screen.zig`: owned cell frames, clipped painters, wide-cell handling,
  and differential ANSI rendering.
- `src/ui/input.zig`: incremental UTF-8, conventional xterm key sequences, and
  bracketed-paste framing.
- `src/terminal/emulator.zig`: Ghostty stream/state, colors and graphemes, protocol
  replies, scrollback, and mode-aware key encoding.
- `src/core/directory.zig`: provider-neutral snapshots and local directory scans.
- `src/core/pane.zig`: opaque ownership of navigation, cursor/marks, viewport,
  listing options, source selection, and concurrent scans; read-only views for painting.
- `src/core/operations.zig`: owned background copy, move/rename, mkdir, and delete jobs.
- `src/ui/widget.zig`: owned widget trees, focus, modal input routing, invalidation,
  layout/paint traversal, and deferred removal.
- `src/ui/layout.zig`: reusable horizontal/vertical boxes and centered geometry.
- `src/app/widgets/file_pane.zig`: pane bindings, viewport layout, directory table,
  cursor, metadata, and status rendering.
- `src/ui/text.zig`: safe filesystem text and grapheme layout using Ghostty's
  existing Unicode support.
- `src/ui/text_input.zig`: reusable single-line editor and caret rendering.
- `src/ui/dialog.zig`: centered, clipped dialog framing.
- `src/app/theme.zig`: named application palette shared by panes and dialogs.
- `src/app/widgets/`: application terminal, function-key bar, and file-action dialogs.
- `src/app/view.zig`: retained widget composition and application focus projection.
- `src/app/controller.zig`: application commands and owned modal/job workflows.
- `src/app/layout.zig`: file-manager geometry and compact-window policy.
- `src/app.zig`: the owning `App` lifecycle (`init`, `deinit`, `run`), with private
  methods for worker polling, input, resizing, terminal I/O, and frame output.

The [UI library guide](docs/UI.md) describes widget ownership, callbacks, layout,
focus, and app composition. Import the `lighthouse-ui` build module to use the
toolkit without importing the file manager.

The [cleanup review](docs/CLEANUP.md) records the extracted helpers and the
design-pattern decisions for the current implementation.

Ghostty is pinned by commit and content hash in `build.zig.zon`. Its image support
is disabled. Its Unicode and SIMD dependencies supply the terminal's text
semantics and parsing; no separate UI dependency is introduced.

By default, a Debug application uses a ReleaseSafe Ghostty module. This retains
runtime safety without upstream's expensive full-page integrity scans on each
update. Use `-Dghostty-debug=true` when debugging inside Ghostty itself.

PTY writes are queued and nonblocking; input is backpressured when the queue
fills. Output is processed in bounded batches so a noisy process cannot consume
an unlimited event-loop turn. Render frames own their grapheme bytes, avoiding
references into Ghostty state that may be invalidated by the next read.

## Verification

```sh
zig build test
zig build test-ui
zig build test-integration
zig build fmt-check
```

Use `zig build fmt` to format Zig sources. Python integration suites share their
PTY harness and navigation helpers in `tests/support.py`. If Ruff is installed,
run `ruff check tests` and `ruff format --check tests` to check those sources.

Integration checks require Python 3 and `/bin/sh`; they launch the real program
inside a PTY. They check shell persistence, input focus, Unicode, resize/zoom,
Ctrl+C, shutdown under load, failed startup, tiny windows, and restoration of the
outer terminal attributes. Shell context-marker and diagnostic-routing checks
ensure library logs cannot corrupt the display. If `nvim` and `top` are installed,
they also exercise editing and resizing real interactive applications. Temporary editor fixtures
are removed after the check.

Browsing integration checks use temporary directory trees to exercise independent
navigation, empty directories, symlinks, errors, marks, sorting, hidden files,
refresh, unusual names, and a 2,500-entry listing alongside the persistent shell.
Unit tests also verify scan supersession, snapshot ownership, selection retention,
Unicode editing, cell clipping, dialog overlap with wide glyphs, input framing,
layout bounds, Ghostty state transitions, and focus/key routing. File-action
checks cover Shift marking, marked copy/move/delete batches, destination defaults, recursive copies, raw names,
symlinks, conflicts, descendant rejection, partial results, cancellation during
a large copy, folder creation, pane refresh, and shell access from result dialogs. Deletion checks cover confirmation and
paste isolation, recursive deletion, symlink targets, cancellation, permission
errors, partial completion, and stale sources.

## Current limits

- Linux only. The process boundary will need a ConPTY implementation for Windows.
- Overwrite/merge handling, cross-filesystem moves, editor/viewer launching,
  directory synchronization, the broader widget set/signals, and native plugins
  are not implemented yet.
- Browsing is keyboard-driven; mouse interaction, search/filtering, automatic
  refresh, and persistent navigation history are later work.
- Mouse routing, clipboard integration, image protocols, and enhanced host
  keyboard protocols are deferred. Input currently uses conventional xterm
  sequences; unknown sequences are ignored.
- Colors are emitted as RGB; palette fallback and terminal capability discovery
  are later work. Underline variants are displayed as a single underline.
- Quitting ends the embedded shell session. There is no detach/session recovery.
- Automated PTY coverage is not a substitute for testing a range of terminal
  emulators and SSH configurations; that compatibility pass is still pending.
