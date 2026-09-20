# Provider locations and file actions

`src/core/directory.zig` defines a provisional internal interface. The local
filesystem is the only production adapter and the only file-job executor.
`testing_provider.zig` is a test fixture, not a shipped provider. A second real
adapter may change this interface; it is not a native plugin ABI or universal
filesystem abstraction.

## Identity and navigation

A `Location` borrows a provider identity token and canonical locator bytes.
Equality compares both; display text is never identity. Each provider instance
uses a stable, distinct identity token unless instances intentionally share the
same location namespace and execution semantics. Tokens and context remain alive
at stable addresses until every borrowing pane and controller has been destroyed.
A pane copies its provider value and owns its initial canonical locator.
`Pane.create` accepts an already canonical locator, not user input. Application
startup supplies absolute local locations.

`resolve` owns user-input expansion, child lookup, parent and root semantics. It
returns locator bytes allocated with the supplied allocator; the caller frees
them. User-input resolution must accept the adapter's own canonical locators
unchanged, allowing current-location and root-prefilled path editors to round
trip. Only the local adapter expands `~` and `~/...` using HOME and normalizes
absolute/relative filesystem paths. Child entry names are not user input: a
literal `~name` remains a child name. `has_parent` describes the displayed
location's parent row. `parent_hint` optionally returns the exact entry name to
focus when returning to a parent. `display` returns an alias of its locator or immutable provider storage, valid
until that pane next mutates or is destroyed. Shared mutable formatting scratch
is forbidden: observing another pane must not invalidate an existing view.
`parent_hint` returns borrowed bytes valid through the calling UI operation. Root can have any locator and
need not resemble `/`; two different locations can display the same label.

## Snapshot and pane ownership

A scan returns a `Snapshot` owning its arena, canonical locator, listing names,
metadata and displayed options. The scan must not borrow names or locator bytes
from its request. An entry's name is unique within the snapshot and is its exact,
case-sensitive identity within that location. The listing excludes synthetic
`.` and `..` rows. Providers filter hidden entries and order the snapshot for the
requested options; the local adapter places directories first with deterministic
name tie breaks. Snapshots contain no cursor, viewport or mark state.

The pane owns a parallel mark array. Refresh at the same location retains cursor
and marks by exact entry name, independently of ordering. Only names still
visible in the new snapshot retain marks; hidden or removed entries lose them.
A different location clears marks even if its display is identical. Returning
to a parent uses its provider hint; otherwise navigation begins at the first row.
The synthetic parent row cannot be marked or used as a file-action source.
Cursor/viewport normalization happens during pane mutations, never painting.

`Pane.view`, `location`, `sources`, and row observations borrow pane storage until
the next mutation or destruction. Copy anything retained longer. A snapshot
transfers from worker to pane only after collection; superseded results are
freed without publication. The pane releases its previous snapshot and marks
only after the replacement has been prepared successfully.

## Callbacks, cancellation and failures

Resolution, display, parent observations and capabilities run on the owning UI
thread. Observations must be cheap, nonblocking and allocation-free; they must
not probe filesystem permissions. `scan` runs on a worker and may overlap UI
callbacks or scans from other panes sharing a context. Contexts must synchronize
mutable cross-thread state. A pane runs at most one scan at a time and retains
only the latest pending request. Request locator bytes remain valid until that
worker has joined. Scan options are passed by value.

Workers should check the cancellation flag and return `error.Canceled` promptly;
blocking I/O should use the supplied `std.Io` so shutdown can cancel it. A pane
never publishes a canceled or superseded scan even if the provider returns
success. Destroying a pane cancels and joins its worker before releasing context
borrows or request storage. A provider ignoring both cancellation mechanisms can
delay destruction.

Synchronous resolution errors propagate without changing the current listing.
Scan errors retain the last good location, listing, marks and displayed options;
status exposes the error and attempted location's display text. Requested options
survive cancellation and errors. Only a successful scan publishes new displayed
options. Providers own cleanup on error; the pane deinitializes every successful
snapshot, including unpublished ones.

## Availability and local execution

`Capabilities.source_read` describes reading sources at a location;
`destination_write` describes mutation there. Copy requires source-read and
destination-write, move additionally requires source-write, delete requires
source-write, and mkdir requires destination-write. Copy, move and delete also
require at least one file-action source. These observations describe structural
support, not OS permissions; real I/O errors remain execution results.

`operations.available` separately checks that a supported executor exists. Today
only the local adapter identity can enter the local executor. A readable
non-local provider may support future copy-out, but read/write flags alone do
not authorize it or any cross-provider transfer. A non-local locator resembling
a local path cannot become a local request. `Provider.localPath` is the explicit
identity-checked bridge to `Job.create`.

`State.actionAvailable` supplies the same file-action policy to presentation and
workflow entry points. Presentation uses the other pane as the default copy/move
destination; mkdir uses the active location. Submission converts typed input through the explicit local adapter target path,
preserving local relative destinations, home expansion, trailing slashes and OS
symlink/parent traversal. File-job destinations keep their absolute execution
spelling instead of the lexical normalization used for navigation; capability
callbacks must accept these absolute destination locators too. Submission rechecks
the actual destination as well as current default-context availability. Both
source and destination cross the local adapter bridge before job construction. Delete confirmation rechecks
availability before starting its prepared job. Unsupported entry points do not
open an editor/confirmation; support lost during an open workflow returns
`UnsupportedOperation` and keeps its payload for dismissal or correction.
