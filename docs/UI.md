# UI library and application widgets

`lighthouse-ui` is a separate Zig build module rooted at `src/ui/root.zig`.
It owns cell rendering, safe text layout, input decoding, text editing, widget
ownership, focus, modal routing, and reusable layouts. It has no imports from
the file-manager core, the application, or the Linux platform layer. Its Unicode
support still comes from the pinned Ghostty dependency.

The application imports this module and implements its widgets in
`src/app/widgets/`. File panes borrow domain `Pane` values; the terminal widget
borrows the emulator; dialogs borrow the application's workflow state. These
resources outlive the widget tree and are released by the application.

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
state into it. `src/app/controller.zig` owns application commands and file-action
workflows. `src/app/layout.zig` chooses the two-pane/terminal geometry.
`src/app.zig` owns startup, background polling, terminal I/O, and frame output.
The palette belongs to `src/app/theme.zig`.

## Defining a widget

A model is an ordinary Zig struct. `Tree.create(parent, Model, value)` allocates
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

Keep `Tree` at a stable address until `deinit`. Widgets borrow their tree and
parent pointers. Widget handles are valid until destruction, including the end
of a traversal that schedules destruction. Models can borrow other state, but
that state must outlive them. A model can keep its own mutable state or borrow
application state; call `node.invalidate()` when an external update needs paint.

## Layout and painting

`Tree.layout(size)` is a separate pass. A layout assigns parent-local child
rectangles with `setRect`; a parent may use `child.measure(available)` to obtain
a clamped preferred size. The library provides horizontal/vertical equal-share
boxes and centered geometry. Applications can supply custom layouts using the
same interface. The file-pane widget updates its viewport during layout, even
when a compact window gives it no visible rows.

`Tree.paint(frame)` walks the tree in child order, creating nested clipped
painters. The active modal subtree paints last and suppresses the underlying
cursor. Composite widgets can paint their internal content directly into their
painter. Geometry and visibility changes invalidate the tree; successful paint
clears that flag. The caller begins the frame and uses `screen.encode` for ANSI
output, keeping the library independent of terminal ownership and OS I/O.

Painting currently recomposes the complete visible tree when invalidated.
Differential ANSI encoding still limits host output to changed cells. Partial
widget repaint caching is not part of this interface yet.

## Focus, input, and lifetime

Set `node.focusable = true` and call `Tree.setFocus(node)` to make it the input
target. Events first visit that widget and bubble through its parents until a
handler returns `true`. `false` allows a parent to interpret an unhandled command.
Terminal input is handled by the terminal widget; Ctrl+G bubbles to the app.

`Tree.setModal(node)` establishes one modal scope. Input cannot escape that
subtree, including ignored events and the event that opens or closes the modal.
Closing the scope restores the prior focus if it is still alive. Replacing the
scope retains the original saved focus. The app uses its own policy to allow a
running or finished job dialog to yield to the shell.

Visibility controls painting, separately from input eligibility. This preserves
the application's existing compact-window behavior: a hidden pane can retain
keyboard focus. Hiding a widget does not implicitly dismiss a modal.

`Widget.destroy()` is safe during event callbacks, including destruction of the
current widget or an ancestor. It retires the subtree immediately, clears affected
focus references, and defers memory reclamation until traversal returns. Adding
widgets and recursive dispatch/layout/paint during a traversal return `TreeBusy`.
Create new widgets between passes, as the application does when composing its view.

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
