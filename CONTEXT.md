# LightHouse

LightHouse is a dual-pane file manager with a persistent terminal.

## Language

**Pane**:
An independent directory-browsing area with its own location, listing, cursor,
marks, and viewport.
_Avoid_: panel

**Cursor**:
The current row in a pane, which may be a directory entry, Current row, or Parent row.
_Avoid_: selection (when referring only to the cursor)

**Mark**:
A choice of a directory entry for a file action, independent of the cursor.
_Avoid_: focus

**Current row**:
The synthetic `.` row representing a Pane's current Location; it is never
a marked entry or a file-action source.

**Parent row**:
The synthetic `..` row for navigating to the containing directory; it is never
a marked entry or a file-action source.

**Requested options**:
The pane's chosen sorting and hidden-entry settings, including changes whose
listing has not yet been displayed.

**Displayed options**:
The sorting and hidden-entry settings represented by the pane's current listing.

**File-action sources**:
The marked entries in a pane, or its cursor entry when nothing is marked.


**Provider**:
The authority for interpreting locations and listing their entries. Providers
can differ in navigation rules, supported file actions, and the representation
of an entry offered for Path insertion.

**Location**:
A place identified by its provider and that provider's locator. Its displayed
text is a label and does not determine identity or navigation rules.

**Locator**:
A provider's canonical identifier for a location, meaningful only to that
provider.

**Operation availability**:
Whether a file action has sources when required, the relevant locations support
its reads and writes, and an executor supports their combination.

**Path insertion**:
An explicit action that inserts a Provider-defined representation of a Pane's
Cursor row into the persistent terminal's input without submitting it.

**External tool session**:
A temporary terminal session for a file tool opened from a Pane, separate from
the persistent terminal and occupying the full application area until it exits.

**Persistent terminal session**:
The shell session used by LightHouse's integrated terminal, independent of Pane
navigation and external tools. Its exit ends that session rather than LightHouse;
a later explicit action can start a new session.

**Directory merge**:
A copy or move that combines source entries with an existing destination
directory, preserving destination entries absent from the source.

**Destination conflict**:
An existing destination entry that requires a choice before a copy or move
can proceed with the corresponding source entry.
