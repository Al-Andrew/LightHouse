# LightHouse

LightHouse is a dual-pane file manager with a persistent terminal.

## Language

**Pane**:
An independent directory-browsing area with its own location, listing, cursor,
marks, and viewport.
_Avoid_: panel

**Cursor**:
The current row in a pane, which may be a directory entry or the parent row.
_Avoid_: selection (when referring only to the cursor)

**Mark**:
A choice of a directory entry for a file action, independent of the cursor.
_Avoid_: focus

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
