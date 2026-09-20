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

`operations.Context.available` separately checks that a supported executor
exists. Today only the local adapter identity can enter the local executor. A readable
non-local provider may support future copy-out, but read/write flags alone do
not authorize it or any cross-provider transfer. A non-local locator resembling
a local path cannot become a local request. `Provider.localPath` is the explicit
identity-checked bridge used inside preparation before `Job.create`.

`operations.Context` borrows the active and other pane for synchronous
`available(kind)` and `prepare(io, allocator, kind, target)` calls. It chooses the
other pane as the default copy/move destination, and the active pane for mkdir
and delete. The controller and presentation share this availability policy via
`State.actionAvailable`; callers do not collect names or convert provider
locations into local execution paths.

Preparation rechecks current default-context availability and the actual edited
destination. Copy/move retain the other pane's provider identity and context for
the edited destination; mkdir and delete use the active provider. Relative local
input still uses the source pane's base. Preparation uses the explicit local
adapter target conversion, preserving home expansion, trailing slashes and OS
symlink/parent traversal. File-job destinations keep their absolute execution
spelling instead of the lexical normalization used for navigation; capability
callbacks must accept these absolute destination locators too. Both source and
destination cross the local adapter bridge before job construction. Unsupported
provider combinations cannot construct a local job, even with path-like locators.

Successful preparation returns an unstarted `Job` owning all File-action sources
and destination bytes; it retains no pane or provider borrows and changes neither
pane. The controller owns the job through confirmation, launch, completion and
result dismissal, and refreshes both panes when it collects completion. Delete
confirmation rechecks availability before starting its prepared job. Unsupported
entry points do not open an editor/confirmation. Direct `State.submit` and
`State.confirmDelete` calls return `UnsupportedOperation` when support is lost
during an open workflow, keeping its payload for dismissal or correction. Preparation-interface tests cover provider contexts, capability
changes, destination spelling and request ownership; controller and View tests
cover the workflow lifetime and routing.

## Workflow recovery policy

`State.modalEvent`, reached through `View.event`, owns recovery for an editor's
submission or delete confirmation. It catches only this explicit rejection set:

- `UnknownLocation`, `UnknownChild`, and `InvalidLocation`: the Provider does not
  recognize the requested Location. `InvalidLocation` is the general contract
  for an adapter's invalid locator/input; the opaque test adapter currently uses
  `UnknownLocation` and `UnknownChild`.
- `UnsupportedOperation`: current sources, Provider capabilities, or the executor
  no longer support the requested action, including its edited destination.

The modal retains its input or prepared delete job and publishes a typed
`State.view().rejection`. The explanation is painted beside that payload. No job
starts, and synchronous resolution rejection leaves the Pane's last good
Location and listing unchanged. Further editor input clears the explanation;
Enter retries with current input and capabilities. Escape dismisses either
workflow; `n` also dismisses delete confirmation. Paste cannot confirm or dismiss
a deletion. Dismissal or successful submission releases the rejection with its
owning modal, so it cannot leak into a later workflow.

This is an application event policy, not a change to Provider or Pane error
semantics. Direct `State.submit`, `State.confirmDelete`, and `Pane.request` calls
still return synchronous errors. Every error outside the allowlist propagates
through `View.event`, including `OutOfMemory`, `Canceled`, lifecycle failures,
and transport failures; they are not presented as correctable input. Asynchronous
scan failures remain Pane status, and started-job failures remain job results.
New Provider error names require an explicit recovery-policy decision.

## Cursor reference capability

`Provider.reference` is an optional UI-thread callback receiving the opaque
location and the original `Entry`. It returns one owned, unquoted reference
allocated using the supplied allocator, or an error. It is independent of local
file-job eligibility. The local Provider joins its absolute location with the
entry name, without resolving symlink targets. The opaque test Provider uses
its own reference syntax through the same command workflow.

The controller releases the reference after validating and quoting it. Providers
do not add shell syntax, spacing, or paste framing. Empty/control-character
references are refused. LightHouse quotes for POSIX shell syntax, appends one
space, and admits the entire insertion before taking terminal focus. Original
filename bytes are retained; escaped display labels never become input.
