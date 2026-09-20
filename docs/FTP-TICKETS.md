# FTP first-version tickets

Published 2026-09-20 under [epic #39](https://github.com/Al-Andrew/LightHouse/issues/39).
The user has agreed to full file actions across every supported Provider pair,
login, saved credentials, and a server/Location selection window. Technical and
UI specifications and research are in [FTP-RESEARCH.md](FTP-RESEARCH.md) and
[FTP-CONNECTION-UX.md](FTP-CONNECTION-UX.md).

Current work is design, research and ticket preparation. Protocol test suites,
test-server fixtures and live FTP/FTPS validation are deferred; they are not
prerequisites for completing this design or publishing tickets. The criteria
below describe intended behavior, not a required test project for this phase.
Credentials use the store on the machine running LightHouse, including when
LightHouse is launched there over SSH.

## Approved triage decisions

The user confirmed these decisions after the grilling interview. They resolve
#40 and supply the implementation criteria below. No application implementation
or live validation is claimed by closing the design issue.

| Decision | Agreed behavior |
| --- | --- |
| Q1: Location picker | F2 opens saved servers, bookmarks and an editable directory for the active Pane. Browse remote directories in the Pane after connecting; no nested picker browser in v1. |
| Q2: Starting directory | Use an explicitly chosen bookmark/path, otherwise the configured starting directory, otherwise the login directory. Do not substitute the last-browsed directory. |
| Q3: Password saving | Save password defaults on for saved servers; users may uncheck it to be asked each time. |
| Q4: Missing/locked host keyring | Offer explicit Connect without saving when storage cannot be used. Keep that password only for the connection and report that it was not saved. |
| Q5: Profile edits | Host or username changes require fresh password entry. Changing the display name or starting directory keeps the saved credential. |
| Q6: Profile removal | Confirm removal of the profile, bookmarks and saved password together. Existing live connections continue until disconnected. |
| Q7: Disconnect | Return that Pane to its previous local Location; the other Pane is unaffected. |
| Q8: Connection loss | Keep the last listing visibly disconnected and offer explicit Reconnect. Jobs keep their retry/cancel/result workflow. |
| Q9: Modes | Offer plain FTP, explicit FTPS and implicit FTPS. Default to explicit FTPS. |
| Q10: Older servers | Prefer MLSD; support common older listing formats as a fallback. Reject unknown/ambiguous formats rather than guessing names or types. |
| Q11: Certificates | Invalid/untrusted certificates block connection. Allow trusted-CA configuration for private servers; no verification-bypass switch in v1. |
| Q12: Links | Preserve links when supported. Otherwise offer Skip / Cancel; never silently copy their targets. Recursive deletion never follows links. |
| Q13: Unsafe overwrite | If replacement requires deleting the old destination first, explain the loss risk and offer Overwrite anyway / Apply to all / Skip / Cancel. |
| Q14: Metadata | Copy contents, preserve modification times when supported, and use normal destination permissions for remote transfers. Report metadata limitations without failing a successful content transfer; exact remote ownership/permissions preservation is outside v1. |
| Q15: Override scope | Apply to all covers subsequent unsafe overwrites in the current Job only. Ordinary overwrite consent does not authorize this stronger operation; new Jobs start without permission. |
| Q16: Override failure | Retain the source, attempt incomplete-replacement cleanup, and report that the original destination cannot be restored. Identify leftover partial files if cleanup fails. Never automatically repeat the destructive overwrite. |

Existing local Directory merge, conflict categories and foreground Job policy
carry over. Local-only metadata behavior is unchanged. Moves remove sources only
after successful destination completion; skipped/failed entries retain sources.
The persistent terminal remains a normal shell.

## Epic: FTP/FTPS Panes with saved connections and full file actions

A user can save a server and its credentials, open a chosen remote directory in
either Pane, and use the existing file actions across local and remote Locations.
Copy and move include different FTP servers and mixed FTP/FTPS connections.
The user never needs to choose the transfer mechanism.

Completion requires all implementation tickets below and support for each
Provider pair. A browsing-only build is an intermediate milestone.
Remote editing, SFTP and a public plugin ABI are outside this epic.

## D0: Validate the connection workflow and settle credential persistence

Resolved through the user-confirmed decision record above. The original study
and wireframes are retained in FTP-CONNECTION-UX.md; accepted transport and
file-action behavior is reflected in FTP-RESEARCH.md. This is specification
completion, not implementation or usability/live-server validation.

## D1: Persist server profiles, saved Locations and credentials

Depends on D0 (resolved).

- Profiles have stable IDs, display names, endpoint/security settings, username,
  default Location and named saved Locations. Secrets are referenced separately.
- Create/edit/remove and restart preserve saved values without touching editor
  configuration. Save failures retain the editable draft and report the failure.
- Save password defaults on for saved servers; an unchecked option asks each
  time. Host or username changes require fresh password entry; changing a name
  or starting directory retains the credential.
- If host storage is unavailable or cannot be unlocked, offer explicit Connect
  without saving and retain the password only for the live connection.
- Confirm removal of a profile, its bookmarks and saved credential together;
  existing live connections continue. Report any failed secret cleanup.
- Support save, retrieve, replace and forget credentials with observable
  locked/unavailable/not-found states. Never report a failed secret write as saved.
- Define profile/secret partial-write recovery, deletion cleanup and concurrent
  app-instance writes; avoid losing unrelated profiles on update.
- Password bytes never enter profile JSON or diagnostics.

## D2: Add cancellable FTP/FTPS transport and directory listings

Depends on D0 (resolved). Transport/build details are implementation choices
within the approved compatibility and cancellation requirements.

- Integrate libcurl behind a transport boundary and validate required linked
  features; network work and secret-service calls do not run in UI callbacks.
- Offer FTP, explicit FTPS and implicit FTPS; default to explicit FTPS.
- Prefer MLSD, falling back to recognized common legacy listing formats. Reject
  unknown/ambiguous formats without guessing names or types. Preserve original
  names and optional metadata in owned Snapshots.
- Enforce configured certificate verification and protect both channels for
  explicit FTPS. Invalid/untrusted certificates block connection; offer trusted-CA
  configuration for private servers and no verification-bypass switch.
  Distinguish login, certificate, timeout and listing failures.
- Two simultaneous requests must not share a mutable handle unsafely.
- Cancel and shutdown must remain responsive during connection and listing;
  malformed listings and unsupported servers produce explicit errors.

## D3: Connect, switch and disconnect a Pane without losing its last good view

Depends on D1 and D2.

- Model connection work, credential prompts and errors outside cheap Provider
  observations. Own contexts until every borrowing Pane/worker/Job releases them.
- Keep the Pane object stable and publish the new Provider and first Snapshot
  together only after connection and directory opening succeed.
- Cancel/failure preserves the previous Location, Cursor and Marks. Stale work
  cannot replace a newer request or reopen a dismissed connection workflow.
- Distinguish authentication success from failure to open the requested remote
  directory; let the user correct that directory without starting over.
- An explicit path/bookmark overrides the configured starting directory for that
  connection; otherwise use that directory or the login directory. Do not
  substitute the last-browsed path for the configured default.
- Disconnect returns this Pane to its previous local Location, leaving the other
  Pane unaffected. Connection loss keeps a visibly disconnected last listing;
  only explicit Reconnect retries. Profile edits/removal do not retarget a Pane
  or in-flight Job, and removing a profile leaves live connections running.
- Respect the existing foreground Job policy.

## D4: Add the Locations window, profile form and login workflow

Depends on D0 (resolved), D1 and D3; UI can be developed against fake connection work.

- Add F2 Locations scoped to Panes. Identify the target
  Pane; present saved servers, saved directories and an editable remote path.
- Provide new/edit/remove profile, credential save/replace/forget, connect,
  disconnect and return-to-local actions with clear labels and keyboard access.
- Baseline Location choice uses an editable path and saved bookmarks; remote
  directory discovery then uses ordinary Pane navigation. No nested browser in v1.
- Reflect the agreed password-saving, one-time login, profile-removal and
  starting-directory defaults; preserve drafts on login, path and storage errors.
- Add masked password input that never paints secret bytes into Frames; preserve
  paste-as-data behavior. Saved secrets display status, not password contents.
- Implement deliberate Tab/Shift+Tab traversal, list navigation, explicit action
  activation, Escape/back behavior and retained drafts using the existing modal
  scope. Text-entry shortcuts cannot delete a profile or submit pasted input.
- Show connecting, unlock, invalid-login and inaccessible-directory states with
  correction/retry paths. Persistence failure is distinct from connection failure.
- Keep actions reachable at normal and compact sizes and restore focus on close.

## D5: Execute copy across every Provider pair

Depends on D2 and D3.

- Replace local-only preparation with explicit supported-executor dispatch,
  preserving the local executor and rejecting accidental local interpretation
  of remote Locators. Jobs own request and connection state.
- Copy files and directory trees for local→local, local→FTP/FTPS,
  FTP/FTPS→local and remote→remote, including distinct servers and mixed TLS modes.
- Resolve edited targets in the destination Provider's namespace. Keep conflict,
  Directory merge, progress, retry/skip/cancel and foreground result workflows.
- Preserve links when supported; unsupported link transfers offer Skip / Cancel
  and never silently follow the link. Copy contents and modification times when
  supported, using normal destination permissions for remote transfers. Report
  metadata limitations without failing a successful content transfer; exact
  remote ownership/permissions preservation is outside v1.
- Prefer completing a replacement before publication. If the server must delete
  the old destination first, explain that failure cannot restore it and offer
  Overwrite anyway / Apply to all / Skip / Cancel. This is separate from ordinary
  overwrite consent. Apply to all covers unsafe overwrites in this Job only.
- Failed/canceled overridden transfers retain their sources and attempt cleanup
  of the incomplete replacement. Report original-destination loss and any partial
  file left after failed cleanup; never repeat destructive overwrite automatically.
- If staging is used, surface storage exhaustion and release temporary resources
  according to the partial-result policy. Preserve existing local behavior.

## D6: Add remote directory creation, deletion and rename

Depends on D2 and D3.

- F7 creates remote directories and F8 deletes remote File-action sources,
  recursively where needed, with existing confirmation and result behavior.
- Add same-server rename support for use by move execution. Define destination
  conflicts using existing Job decisions; route server operations that are
  unsupported into the explicit failure workflow without destructive retries.
- Recursive deletion never follows links; remove the link itself when supported.
  Unsupported link actions offer Skip / Cancel. Synthetic Current and Parent
  rows never become mutation sources. Preserve existing Directory merge and
  file/directory mismatch behavior.
- Surface permission failures and partial completion. A lost response to a
  mutation must not trigger a blind destructive retry.

## D7: Complete move across every Provider pair

Depends on D5 and D6.

- Support the same pair matrix as copy. Use suitable rename or transfer-based
  execution internally without requiring the user to select a mechanism.
- Delete a source only after its destination completes successfully. Skipped,
  failed or canceled transfers retain their sources; partial tree moves report
  which entries moved and which remain.
- A successful copy followed by failed source deletion is reported accurately;
  retry targets the remaining work without blindly repeating the transfer.
- Cover same-source/destination and destination-inside-source cases, Directory
  merge, overwrite decisions and loss of connection after mutation.
- Inherit D5's link/metadata policy and separate unsafe-overwrite consent,
  including per-Job Apply to all and failed-replacement cleanup. No failed or
  skipped destination permits source deletion.

## Published issues and readiness

| Draft ID | GitHub issue | Triage |
| --- | --- | --- |
| epic | [#39 — FTP/FTPS Panes with saved connections and full file actions](https://github.com/Al-Andrew/LightHouse/issues/39) | `ready-for-agent` |
| D0 | [#40 — Design: Validate the connection workflow and settle credential persistence](https://github.com/Al-Andrew/LightHouse/issues/40) | Closed: design resolved |
| D1 | [#41 — Persist server profiles, saved Locations and credentials](https://github.com/Al-Andrew/LightHouse/issues/41) | `ready-for-agent` |
| D2 | [#42 — Add cancellable FTP/FTPS transport and directory listings](https://github.com/Al-Andrew/LightHouse/issues/42) | `ready-for-agent` |
| D3 | [#43 — Connect, switch and disconnect a Pane without losing its last good view](https://github.com/Al-Andrew/LightHouse/issues/43) | `ready-for-agent` |
| D4 | [#44 — Add the Locations window, profile form and login workflow](https://github.com/Al-Andrew/LightHouse/issues/44) | `ready-for-agent` |
| D5 | [#45 — Execute copy across every Provider pair](https://github.com/Al-Andrew/LightHouse/issues/45) | `ready-for-agent` |
| D6 | [#46 — Add remote directory creation, deletion and rename](https://github.com/Al-Andrew/LightHouse/issues/46) | `ready-for-agent` |
| D7 | [#47 — Complete move across every Provider pair](https://github.com/Al-Andrew/LightHouse/issues/47) | `ready-for-agent` |

The epic links all eight tickets. Each child links its epic and dependencies.
D0 is resolved. D1 and D2 can start now. D3 and D6 follow their listed
prerequisites, D4 follows D1/D3, D5 follows D2/D3, and D7 follows D5/D6.
`ready-for-agent` means the specification is triaged; it does not waive open
implementation dependencies. GitHub issues are the authoritative work tracker.
