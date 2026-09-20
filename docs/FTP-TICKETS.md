# FTP first-version tickets

Published 2026-09-20 under [epic #39](https://github.com/Al-Andrew/LightHouse/issues/39).
The user has agreed to full file actions across every supported Provider pair,
login, saved credentials, and a server/Location selection window. Technical and
UI recommendations are in [FTP-RESEARCH.md](FTP-RESEARCH.md) and
[FTP-CONNECTION-UX.md](FTP-CONNECTION-UX.md).

Current work is design, research and ticket preparation. Protocol test suites,
test-server fixtures and live FTP/FTPS validation are deferred; they are not
prerequisites for completing this design or publishing tickets. The criteria
below describe intended behavior, not a required test project for this phase.
Credentials use the store on the machine running LightHouse, including when
LightHouse is launched there over SSH.

## Epic: FTP/FTPS Panes with saved connections and full file actions

A user can save a server and its credentials, open a chosen remote directory in
either Pane, and use the existing file actions across local and remote Locations.
Copy and move include different FTP servers and mixed FTP/FTPS connections.
The user never needs to choose the transfer mechanism.

Completion requires all implementation tickets below and support for each
Provider pair. A browsing-only build is an intermediate milestone.
Remote editing, SFTP and a public plugin ABI are outside this epic.

## D0: Validate the connection workflow and settle credential persistence

Readiness: suitable for a design/research issue now. Implementation tickets
must incorporate its conclusions before being marked `ready-for-agent`.

- Specify integration with the credential store on the machine running
  LightHouse, including access over SSH. Define locked/unavailable-store handling;
  an application-owned encrypted vault is not required by the agreed direction.
- Walk through first connection, returning user, alternate remote directory,
  expired password, locked/unavailable secret storage, failed login and cancel.
- Validate the Locations window and profile editor at 80×24 and smaller sizes:
  keyboard navigation, visible focus, field errors and return paths.
- Specify saved/default/last-used directory behavior, remote browsing before
  opening a Pane, login-root semantics and server compatibility expectations.
- Record the chosen workflow, secret lifecycle, dependency/build choices and
  acceptance examples. Distinguish reviewed mockups from actual usability tests.

## D1: Persist server profiles, saved Locations and credentials

Depends on D0.

- Profiles have stable IDs, display names, endpoint/security settings, username,
  default Location and named saved Locations. Secrets are referenced separately.
- Create/edit/remove and restart preserve saved values without touching editor
  configuration. Save failures retain the editable draft and report the failure.
- A changed endpoint/account cannot silently receive an old saved password;
  define explicit credential replacement/rebinding behavior.
- Support save, retrieve, replace and forget credentials with observable
  locked/unavailable/not-found states. Never report a failed secret write as saved.
- Define profile/secret partial-write recovery, deletion cleanup and concurrent
  app-instance writes; avoid losing unrelated profiles on update.
- Password bytes never enter profile JSON or diagnostics.

## D2: Add cancellable FTP/FTPS transport and directory listings

Depends on D0's transport/build and server-compatibility decisions.

- Integrate libcurl behind a transport boundary and validate required linked
  features; network work and secret-service calls do not run in UI callbacks.
- Support the agreed FTP/FTPS modes, authenticated login, remote path rules and
  listing format; preserve names and optional metadata in owned Snapshots.
- Enforce configured certificate verification and protect both channels for
  explicit FTPS. Distinguish login, certificate, timeout and listing failures.
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
- Specify explicit disconnect/return-to-local and reconnect behavior. Profile
  edits/removal cannot mutate an in-flight Job or unexpectedly retarget a Pane.
- Respect the existing foreground Job policy.

## D4: Add the Locations window, profile form and login workflow

Depends on D0, D1 and D3; UI can be developed against fake connection work.

- Add a discoverable command (proposed F2) scoped to Panes. Identify the target
  Pane; present saved servers, saved directories and an editable remote path.
- Provide new/edit/remove profile, credential save/replace/forget, connect,
  disconnect and return-to-local actions with clear labels and keyboard access.
- Baseline Location choice uses an editable path and saved bookmarks; remote
  directory discovery then uses ordinary Pane navigation. Add a browser inside
  the picker only if D0 establishes that need.
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
- Define incomplete-destination handling, publication, metadata limitations,
  unsupported entry types and temporary-resource cleanup.
- If staging is used, surface storage exhaustion and release temporary resources
  according to the partial-result policy. Preserve existing local behavior.

## D6: Add remote directory creation, deletion and rename

Depends on D2 and D3.

- F7 creates remote directories and F8 deletes remote File-action sources,
  recursively where needed, with existing confirmation and result behavior.
- Add same-server rename support for use by move execution. Define destination
  conflicts and unsupported server behavior explicitly.
- Define link handling and recursive traversal boundaries; synthetic Current
  and Parent rows never become mutation sources.
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

## Published issues and readiness

| Draft ID | GitHub issue | Triage |
| --- | --- | --- |
| epic | [#39 — FTP/FTPS Panes with saved connections and full file actions](https://github.com/Al-Andrew/LightHouse/issues/39) | `needs-triage` |
| D0 | [#40 — Design: Validate the connection workflow and settle credential persistence](https://github.com/Al-Andrew/LightHouse/issues/40) | `ready-for-agent` |
| D1 | [#41 — Persist server profiles, saved Locations and credentials](https://github.com/Al-Andrew/LightHouse/issues/41) | `needs-triage` |
| D2 | [#42 — Add cancellable FTP/FTPS transport and directory listings](https://github.com/Al-Andrew/LightHouse/issues/42) | `needs-triage` |
| D3 | [#43 — Connect, switch and disconnect a Pane without losing its last good view](https://github.com/Al-Andrew/LightHouse/issues/43) | `needs-triage` |
| D4 | [#44 — Add the Locations window, profile form and login workflow](https://github.com/Al-Andrew/LightHouse/issues/44) | `needs-triage` |
| D5 | [#45 — Execute copy across every Provider pair](https://github.com/Al-Andrew/LightHouse/issues/45) | `needs-triage` |
| D6 | [#46 — Add remote directory creation, deletion and rename](https://github.com/Al-Andrew/LightHouse/issues/46) | `needs-triage` |
| D7 | [#47 — Complete move across every Provider pair](https://github.com/Al-Andrew/LightHouse/issues/47) | `needs-triage` |

The epic links all eight tickets. Each child links its epic and dependencies.
D0 can start now; implementation tickets retain explicit dependencies until the
required decisions are incorporated. GitHub issues are the authoritative work
tracker; the sections above preserve the initial breakdown.
