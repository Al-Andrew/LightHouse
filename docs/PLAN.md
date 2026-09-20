# LightHouse implementation plan

Status: the terminal foundation, keyboard-driven local browsing, and initial
copy/move/mkdir/delete actions are implemented.
The application now provides keyboard-driven local browsing with independent
panes, concurrent directory scans, marking, sorting, hidden-file toggling,
refresh, path entry, keyboard help, and background file jobs with progress and
cancellation. F5 copies, F6 moves/renames within a filesystem, and F7 creates a
folder. F8 confirms permanent recursive deletion without following symlinks.
Jobs refuse conflicts and report partial completion; overwrite/skip prompts,
cross-filesystem moves, and external tools remain pending.
The retained widget foundation now exists as the independent `lighthouse-ui`
build module: parent ownership, measurement/layout/paint callbacks, focus,
modal input routing, clipped composition, invalidation, and deferred removal.
Application widgets live under `src/app/widgets/`; see [UI.md](UI.md).
Signals/slots and the plugin portion of milestone 2, mouse interaction, and the
remaining milestone 3 work are pending.

The next feature designs are recorded in [FEATURE-DESIGN.md](FEATURE-DESIGN.md):
a configured F4 editor, Provider-defined Ctrl+F Path insertion, independent
terminal visibility/session lifetime, and copy/move conflict and error prompts.
These designs are agreed; the features are not implemented yet.

Milestone 1 provides a pinned Ghostty dependency, a handmade cell renderer,
persistent shell/PTY, focus switching, resizable and zoomable terminal area,
scrollback, conventional keyboard input, and bracketed paste. Automated checks
cover Unicode, terminal protocol state, layout bounds, real PTY sessions,
interactive applications, and terminal restoration. See the repository README
for commands and current limitations; the broader terminal/SSH compatibility
pass remains open.

## Confirmed direction

- Zig application running inside an existing terminal.
- Linux first, with platform boundaries for later Windows and macOS support.
- Two file panes, inspired by Far Manager, with an integrated terminal below.
- A UI library built in this repository.
- A classic Java/Qt-style API: retained widget tree, layouts, signals/slots, and explicit ownership. This does not prescribe the visual theme.
- libghostty for terminal emulation.
- Native shared-library plugins supporting full application extensions, including custom widgets. Linux plugins are `.so` files; later Windows/macOS builds use `.dll`/`.dylib` files.

- One independent persistent shell. Ctrl+G changes focus; Ctrl+J hides/shows the terminal and starts a new session when needed. Shell EOF does not exit LightHouse. Ctrl+F inserts the Provider-defined reference for the Cursor entry, creating/showing the terminal as needed; automatic directory synchronization is deferred.
- Dependencies limited to Zig's standard library, OS/libc APIs, libghostty, and narrowly justified helpers such as Unicode support.
- First usable release includes browsing, selection, copy, move, rename, delete, and directory creation; editing and viewing initially launch external programs.

## Proposed implementation defaults

- Keyboard-first interaction, mouse support, configurable bindings, Far-like file-operation shortcuts.
- A resizable, collapsible bottom terminal that can temporarily fill the application.
- Trusted plugins loaded into the application process and retained until shutdown; hot reload is deferred. Plugins share the application's permissions and failure domain.
- Public plugin APIs can evolve during initial development, with explicit version checks from the first prototype.

## Architecture

### Platform and event loop

Isolate terminal setup/restoration, input, process creation, PTYs, dynamic loading, filesystem access, and resize notifications behind platform modules. Linux implements the first backend; later Windows support needs equivalents including ConPTY.

Use one UI thread for widget ownership, event dispatch, signals, layout, and painting. Run directory scans and file jobs outside UI callbacks, delivering bounded progress/completion messages back to the UI. Specify cancellation and shutdown behavior before adding background providers.

### Handmade UI library

Keep the toolkit importable independently of the file manager. Use Zig composition and explicit interface/callback tables to provide a retained widget API without relying on class inheritance or a meta-object compiler.

Core concepts: `Application`, `Widget`, `Layout`, `Event`, `Signal`, `Painter`, `Action`, and `Theme`.

- Parents own child widgets; ownership transfers and destruction are explicit.
- Signal connections have tracked lifetimes and disconnect when their owner is destroyed. Define behavior for reentrant callbacks and deferred widget destruction.
- Separate measurement, layout, invalidation, and painting.
- Paint into clipped cell buffers; composite once and emit changed cells to the host terminal.
- Handle grapheme clusters, wide cells, styles, cursor placement, and narrow terminal sizes deliberately.
- Centralize focus, keyboard shortcuts, mouse capture, dialogs, and modal event routing.
- Build horizontal/vertical layouts, splitters, labels, buttons, text inputs, lists/tables, scrollbars, menus, and dialogs as needed by working application slices.

The visual theme remains a separate choice from the API style.

### Integrated terminal

Use `libghostty-vt` behind a small adapter. It supplies terminal parsing/state; LightHouse supplies the PTY session, shell lifecycle, event routing, and cell rendering.

Output path: shell → PTY → libghostty-vt → terminal widget → UI compositor → host terminal.

Input path: host terminal input → application focus routing → terminal input encoding → PTY. Terminal protocol replies also return to the PTY.

Support resize/reflow, scrollback, alternate screens, Unicode, paste, cursor state, and mouse routing. Scope advertised terminal capabilities to what the complete integration can support. Advanced image protocols are outside the initial milestone.

When the persistent terminal has focus, forward application keys to the child
except for documented focus and visibility controls. Test interactive programs
as well as shell prompts. Pane navigation must not inject commands into a running
program. Ctrl+F is an explicit insertion action without command submission;
automatic directory synchronization is deferred. File jobs block terminal
interaction until result dismissal while shell execution and output collection
continue. F4 tools use a separate full-area session whose keys go to the tool.

### File-manager core

Keep pane state separate from widgets: location, entries, sorting/filtering, selection, cursor, and navigation history. Define provider interfaces early so plugins can supply non-local locations.

File operations are cancellable jobs with progress, conflict handling, and explicit partial-failure results. Define overwrite, symlink, recursive deletion, and cross-filesystem move behavior. Preserve source data when a move's copy stage fails. Bound directory work so large listings remain responsive.

### Plugin system

Expose a versioned C ABI with a single discovery/initialization entry point and host/plugin function tables. Include structure sizes and version negotiation. Use opaque handles, fixed-width fields, explicit string/buffer lengths, and documented memory ownership; keep Zig slices, error unions, and internal object layouts out of the ABI.

Provide a Zig SDK wrapper for ergonomic plugin authoring. Plugins are built independently of the application and discovered in documented plugin directories, not implicitly loaded from browsed folders.

Plan extension interfaces for commands/actions, menus, dialogs, events, file providers, viewers/editors, and custom widgets. Custom widget callbacks cover creation/destruction, measurement, layout, input, and painting through the host's clipped painter. Plugins participate in the same ownership and focus model as built-in widgets.

Document callback threading, errors, cancellation, and buffer lifetime. During shutdown, stop plugin work and destroy plugin-owned widgets/connections before releasing library handles. ABI versions describe supported extension contracts; incompatible plugins fail to load with a useful error.

## Delivery milestones

1. **Dependency and terminal feasibility prototype.** Pin Zig and a compatible Ghostty revision; build a minimal cell renderer, Linux PTY session, and libghostty adapter. Show a working bottom shell beneath two placeholder panes. Verify resizing, interactive applications, focus escape, Unicode, and outer terminal restoration.
2. **Toolkit and plugin vertical slice.** Implement widget ownership, layout, focus, events, signals, clipping, and painting. Load an independently built plugin that adds a command and custom widget. Exercise creation/destruction and reject an incompatible ABI. Use this to validate the public interface before building many widgets.
3. **Usable dual-pane browsing.** Implement local providers, independent pane navigation, selection, sorting, hidden-file toggle, path entry, menus, dialogs, and keyboard/mouse interaction. Keep listing work responsive while the shell produces output.
4. **File operations and external tools.** Add copy/move/rename/delete/mkdir, progress, cancellation, and conflict handling. Launch external editors/viewers in a defined terminal-session mode and refresh affected panes afterward.
5. **Complete the first extension contracts.** Add provider and viewer/editor registration. Prove provider support with a small virtual-filesystem plugin and document commands, events, custom widgets, and memory/threading rules in the SDK.
6. **Reliability and release preparation.** Persist settings, bindings, pane locations, and splitter sizes. Validate slow/large directories, permission errors, unusual filenames, links, interrupted operations, sustained terminal output, plugin lifecycle, and shutdown. Document build, installation, plugin development, and known terminal limitations.

The first usable milestone is complete when both panes support routine file operations, the persistent terminal remains interactive, and independently compiled plugins can add UI and file-provider behavior.

## Verification strategy

- Unit checks for consequential behavior: layout/clipping, focus routing, Unicode cell handling, and ABI negotiation.
- PTY integration checks for resize, alternate screens, paste, child exit, and terminal restoration.
- Temporary-directory tests for overwrite, symlinks, cancellation, partial failures, and cross-filesystem moves where available.
- Plugin integration checks for independent builds, host callbacks, ownership cleanup, and rejected versions.
- Manual sessions in representative Linux terminals, including an SSH session and narrow window sizes.

## Initial repository organization

```text
src/main.zig
src/platform/
src/ui/
src/terminal/
src/core/
src/app/
src/plugins/
sdk/
examples/plugins/
tests/
```

## Research notes

The initial repository contained a Zig 0.16.0 starter scaffold. Milestone 1 pins
Ghostty revision `44f2a44df7e8c4a0c6df3f7d872ef3d7ead88e51` by archive URL and content
hash, built with Zig 0.16.0. The application disables Ghostty's Kitty graphics
feature. Debug application builds use a ReleaseSafe Ghostty module by default
to avoid expensive internal integrity scans; `-Dghostty-debug=true` enables them.

- [Ghostty's libghostty status](https://github.com/ghostty-org/ghostty#cross-platform-libghostty-for-embeddable-terminals): libghostty-vt is usable from Zig and C; its API is still evolving.
- [Ghostling integration example](https://github.com/ghostty-org/ghostling): demonstrates that the consumer supplies rendering/windowing around libghostty-vt. LightHouse will supply terminal-cell rendering instead.
- [Ghostty build manifest](https://github.com/ghostty-org/ghostty/blob/main/build.zig.zon): compiler/dependency baseline inspected while planning.
