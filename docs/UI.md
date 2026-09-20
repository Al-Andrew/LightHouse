# UI library and application widgets

`lighthouse-ui` is a separate Zig build module rooted at `src/ui/root.zig`.
It owns cell rendering, safe text layout, input decoding, text editing, widget
ownership, focus, modal routing, and reusable layouts. It has no imports from
the file-manager core, the application, or the Linux platform layer. Its Unicode
support still comes from the pinned Ghostty dependency.

The application imports this module and implements its widgets in
`src/app/widgets/`. File panes borrow domain `Pane` values; the terminal widget
borrows the emulator; dialogs borrow the application's workflow state. These
resources outlive the widget tree. The controller releases workflow payloads;
`App` releases the borrowed panes and emulator after destroying the controller.

## Composition

The current application tree is:

```text
App root                       application layout and global bindings
├── Horizontal box             library layout
│   ├── File pane               app widget → core Pane
│   └── File pane               app widget → core Pane
├── Terminal                    app widget → terminal Emulator
├── Function-key bar            app widget → application state
└── Modal                       app widget → editor/help/confirmation/job
```

`src/app/view.zig` builds this tree once and projects application focus and modal
state into it. The view retains named handles for the pane area, terminal, key
bar, and modal; root layout uses those roles rather than child indices. These
handles borrow nodes owned by the tree and live until view destruction. The root
model borrows the heap-allocated view, which stays at a stable address until after
the tree is released. Adding another child does not change a role's geometry.
The opaque `State` in `src/app/controller.zig` owns application commands and
complete file-action workflows, including completion collection, refreshing both
panes, result retention, and modal/job cleanup. `src/app/layout.zig` chooses the
two-pane/terminal geometry.
`src/app.zig` defines `App`, which owns startup, background polling, terminal I/O,
and frame output through an explicit lifecycle:

```zig
var app = try lighthouse.App.init(io, allocator, shell);
defer app.deinit();
try app.run();
```

Initialization rolls back acquired resources on failure. Controller state has a
stable heap address because widgets borrow it; the `App` value can be returned
from initialization without invalidating those pointers. `run` coordinates
controller polling, input timeout, resize, rendering, and terminal I/O through
private methods. `State.create` borrows panes and I/O and owns its heap storage,
editors, prepared confirmations, and running/finished job. `State.destroy`
releases those payloads and cancels/joins outstanding file work before the
application destroys either borrowed pane. `deinit` releases the view, joins
background work, ends the embedded session, and restores the outer terminal. The executable performs this cleanup
before reporting runtime errors. Each successful initialization owns one session
and requires exactly one `deinit`.

Workflow callers use `openPath`, `openAction`, `openDelete`, `submit`,
`confirmDelete`, and `dismiss`. A second workflow is rejected until the current
modal/job is dismissed. `State.view()` provides borrowed, read-only observations;
painting and status reads never collect completion. Only `State.poll()` collects
jobs and requests one refresh of each pane for every completion, including
failure, cancellation, and launch failure. Both refreshes are attempted even if
one fails. The finished result remains owned until dismissal, including while
focus visits the persistent terminal. `App` schedules polling without accessing
or destroying workflow payloads.

The palette belongs to `src/app/theme.zig`.

## Defining a widget

`Tree` and `Widget` are opaque handles: ownership links, callback tables, focus,
modal scope, and traversal/retirement bookkeeping are private to the toolkit.
Create a tree with `const tree = try ui.Tree.init(allocator)` and release it with
`defer tree.deinit()`. Initialization allocates stable storage; the pointer may be
copied or held in a movable owner, but exactly one owner must call `deinit`.

A model is an ordinary Zig struct. `tree.create(parent, Model, value)` allocates
stable storage for its value and mounts it under the parent. Passing `null`
creates the single root. The library generates an internal callback table;
application models do not perform opaque pointer casts.

A model may implement these public methods:

```zig
pub fn measure(self: *Model, available: ui.Size) ui.Size;
pub fn layout(self: *Model, node: *ui.Widget, size: ui.Size) void;
pub fn paint(self: *Model, node: *ui.Widget, painter: ui.Painter) !void;
pub fn event(self: *Model, node: *ui.Widget, event: *const ui.Event) !bool;
pub fn deinit(self: *Model) void;
```

Omitted methods have defaults: fill the available size, lay children over the
whole local rectangle, paint nothing, ignore input, and perform no extra cleanup.
`TextInput` is a reusable editing model that composite widgets can own directly;
its accept/cancel outcomes acquire application meaning in their parent dialog.

Creation takes ownership of the model value only on success. The caller retains
responsibility for cleaning up that value if creation fails. Parents own their
children; `Tree.deinit()` releases every child before its parent. A model's
`deinit` releases its own resources and must not mutate the tree.

The toolkit keeps tree, node, and model allocations at stable addresses until
release. `node.tree()`, `node.parent()`, and `tree.root()` return borrowed handles;
none transfers ownership. A widget handle expires when it or an ancestor is
destroyed. During a callback traversal, retired handles remain allocated until
the outer traversal returns; `node.isAlive()` reports whether the node and its
ancestors remain live during that interval. It cannot validate an expired handle.

`node.children()` returns a borrowed `[]const *Widget`: callers can operate on
children through their methods, but cannot replace or reorder ownership slots.
Do not retain the slice across creation, destruction, or the end of a traversal.
Do not destroy children while iterating this slice outside a callback traversal;
reacquire the slice after each immediate destruction. Models can borrow other
state, but that state must stay at a stable address and outlive them. Call
`node.invalidate()` when an external update needs paint.

## Layout and painting

`Tree.layout(size)` is a separate pass. A layout assigns parent-local child
rectangles with `setRect`; `node.rect()` returns geometry by value. A parent
iterates `node.children()` and may use `child.measure(available)` to obtain a
clamped preferred size. `setVisible` and `visible()` control/observe a node's own
visibility, separately from its ancestors. The library provides horizontal and
vertical equal-share boxes and centered geometry. Applications can supply custom layouts using the
same interface. Application layout and view accept toolkit `Size` values.
`Layout.boundedSize` limits presentation geometry to nonzero dimensions and a
bounded allocation size. `App` converts host dimensions at the event-loop seam
and derives both emulator and PTY sizes from the same layout, including zoom,
compact, and one-cell windows. Linux continues to own the outer console and PTY
lifecycle; `App` retains nonblocking transport scheduling.

The file-pane widget updates its viewport during layout, even when a compact
window gives it no visible rows.

`Tree.paint(frame)` walks the tree in child order, creating nested clipped
painters. The active modal subtree paints last and suppresses the underlying
cursor. Composite widgets can paint their internal content directly into their
painter. Geometry and visibility changes invalidate the tree; successful paint
clears that flag; `tree.needsPaint()` observes it without allowing callers to
clear it. Invalidation during painting and paint errors leave the flag set.
The caller begins the frame and uses `screen.encode` for ANSI
output, keeping the library independent of terminal ownership and OS I/O.

Painting currently recomposes the complete visible tree when invalidated.
Differential ANSI encoding still limits host output to changed cells. Partial
widget repaint caching is not part of this interface yet.

## Focus, input, and lifetime

Call `node.setFocusable(true)` and `tree.setFocus(node)` to make it the input
target. `node.focusable()` observes eligibility, `node.focused()` observes active
focus, and `tree.focus()` returns the borrowed current target. Disabling
focusability clears both current and saved focus for that node. Events first
visit that widget and bubble through its parents until a handler returns `true`. `false` allows a parent to interpret an unhandled command.
`View.event` is the sole application input entry point. File-pane widgets handle
local navigation and marking; unhandled global bindings bubble to the root's
`State.globalEvent`. The root never retries pane bindings. Terminal input is
handled by the terminal widget; only Ctrl+G key events bubble to the root. Modal
widgets call `State.modalEvent` and consume every event, including ignored paste
events.
The controller owns focus policy; the view only projects its observed focus and
modal visibility into the tree.

Paste bytes, including Ctrl+G, stay terminal data. The widget forwards keys
and paste events through `Emulator.event`; the emulator owns paste state, captures
bracketed-paste mode at paste start, and frames the entire paste using that mode
even if child output changes it before paste end. Key encoding and VT replies
share its bounded output queue. `Emulator.scrollPage(.up/.down)` keeps page size
and Ghostty viewport state behind the terminal interface. Keys and paste start
return the viewport to the bottom.

`Tree.setModal(node)` establishes one modal scope. Input cannot escape that
subtree, including ignored events and the event that opens or closes the modal.
Closing the scope restores the prior focus if it is still alive. Replacing the
scope retains the original saved focus. `tree.modal()` observes the borrowed
modal handle without exposing its storage. The app uses its own policy to allow a
running or finished job dialog to yield to the shell.

Visibility controls painting, separately from input eligibility. This preserves
the application's existing compact-window behavior: a hidden pane can retain
keyboard focus. Hiding a widget does not implicitly dismiss a modal.

`Widget.destroy()` is safe during event callbacks, including destruction of the
current widget or an ancestor. It retires the subtree immediately, clears affected
focus references, and defers memory reclamation until traversal returns. Adding
widgets and recursive dispatch/layout/paint during a traversal return `TreeBusy`.
Create new widgets between passes, as the application does when composing its view.
Layout and paint callbacks may also retire nodes; reclamation waits until their
pass returns. Callbacks may update geometry, visibility, focus, modal scope, and
invalidation through the supported methods. They must not destroy the tree.
`measure` can run outside a traversal and must only compute a preferred size;
it must not mutate or traverse the tree through borrowed application state.
Model `deinit` must only release model-owned resources; it must not access child
handles (already released), mutate the tree, or start another traversal.

## Scope and verification

This is the retained widget foundation. General signals/slots, nested modal
stacks, automatic focus traversal, mouse capture, configurable actions, and the
native plugin ABI remain future work. The Zig model callbacks are internal
interfaces, not a plugin ABI.

Run `zig build test-ui` to test the toolkit independently. `zig build test` runs
both toolkit and application tests. The toolkit tests cover ownership, input
bubbling, modal trapping/restoration, removal during callbacks, reentrancy,
clipping, composition order, and tiny layouts. App tests and `zig build
test-integration` exercise the retained tree with real panes and shell sessions.
Workflow tests use the controller interface and count real provider scans for
successful, failed, canceled, and launch-failed jobs. Allocation-failure and
blocked-work tests verify cleanup; routing tests use `View.event` for compact
pane input, editor/help/delete paste isolation, terminal forwarding, and result
retention across focus changes.
