# FTP connections, credentials and Location picker

Investigated 2026-09-20 against official documentation. This is comparative
research and a proposed design, not user testing or an accepted ADR.
The first version requires saved server credentials, a server-and-Location
window, FTP/FTPS, and full file actions across every Provider pair.
The user chose the credential store on the machine running LightHouse, including
when launched over SSH. This phase covers design and ticket preparation;
protocol test suites, fixtures and live-server validation are deferred.
See [FTP-RESEARCH.md](FTP-RESEARCH.md) for transport and transfer scope.

## Existing-client findings

| Product | Documented behavior | Proposed application to LightHouse |
| --- | --- | --- |
| WinSCP | Saved sites contain connection settings; saving a password is explicit. Login supports new and saved sites. [Sites](https://winscp.net/eng/docs/session_configuration), [Save dialog](https://winscp.net/eng/docs/ui_login_save) | Separate saving a server from connecting; make password persistence visible. |
| WinSCP | Bookmarks can be session-specific or shared; Location profiles can pair local and remote directories. [Navigation](https://winscp.net/eng/docs/task_navigate) | Keep a server's named Locations separate from credentials; paired Pane presets are optional later work. |
| FileZilla Pro | Site Manager has a server list, editable details and default directories. Bookmarks contain paths, not login information, and may be site-specific. [Site Manager](https://filezillapro.com/docs/v3/getting-started/site-manager/), [Bookmarks](https://filezillapro.com/docs/v3/getting-started/bookmark-a-directory/) | Reuse a single saved server for several Locations; avoid duplicating passwords for each path. |
| Midnight Commander | FTP link or a VFS path opens remote directories. Directory hotlist stores named paths. Its manual warns that passwords in paths can appear on screen and in history. [Official manual](https://source.midnight-commander.org/man/mc.html) | Make remote browsing fit the normal Pane; never encode a password in a Location or display label. |

These establish familiar patterns, not evidence that users prefer one layout.
LightHouse should use the same picker for either Pane, including remote-to-remote
work; neither Pane has a permanently local or remote role.

## Proposed concepts

These are proposed additions to the domain vocabulary, not new definitions in
[CONTEXT.md](../CONTEXT.md).

| Concept | Owns | Does not own |
| --- | --- | --- |
| Saved server | Stable ID, name, host, port, protocol/TLS mode, username, default path, credential reference | Plaintext password, mutable Pane cursor or marks |
| Saved credential | Secret bytes held by the selected durable credential store | Navigation history or display labels |
| Live connection | Immutable endpoint/account settings for ongoing work, authenticated transport resources and connection state | The editable saved-server record itself |
| Location bookmark | Name, saved-server ID and Provider-specific Locator (including path-base semantics) | Another password copy or a separate login |

Editing or deleting a saved server must not retarget an existing Pane or Job.
Jobs retain owned endpoint/authentication state until completion. Renaming a
server preserves bookmark/credential links; changing host/account must explicitly
replace or reconfirm credentials rather than silently sending an old password
to a new endpoint. Duplicate-server behavior must state whether secrets are copied.

## Proposed keyboard-first workflow

F2 **Locations** opens for the active Pane (binding subject to final key review).
Start on the saved-server list, offer type-to-filter, Up/Down and Tab/Shift+Tab;
Enter activates the focused action and Esc returns without switching the Pane.
Selecting a server only previews its settings. Connect performs network work.

```text
+ Locations — left Pane ------------------------------------------+
| Search: [                           ]                           |
| This computer                    | Server: Work archive         |
| > Work archive       FTPS        | archive.example:21   alice    |
|   Test uploads       FTP         | Location: [ /incoming      ]  |
|                                  | Base: [Login directory v]    |
|                                  | Bookmarks: incoming, reports |
| [New] [Edit] [Remove]             | [Connect] [Cancel]            |
+-----------------------------------------------------------------+
```

Offer **This computer** with that Pane's previous local Location. A remote
default starts at the server login directory; expose **Login directory** versus
**Server root** explicitly where supported, rather than requiring curl URL
syntax. Bookmarks retain that choice. On initial connection a user can enter a
path or choose a bookmark; ordinary directory discovery occurs in the Pane
after successful login. A nested remote browser is optional, not essential.

```text
+ New server -----------------------------------------------------+
| Name:       [ Work archive                                    ] |
| Host:       [ archive.example                    ] Port: [21 ] |
| Connection: [ FTPS — explicit TLS v ]                           |
| Username:   [ alice                                           ] |
| Password:   [ ********                                        ] |
| [x] Save password     Storage: system credential store          |
| Start at:   [Login directory v] Path: [                        ] |
| [Save] [Save and connect] [Cancel]                              |
+-----------------------------------------------------------------+
```

The displayed storage name reflects the chosen backend; it is not always the
system store. Password fields are masked from their first render. Editing an
existing server shows **Password saved / Change / Forget**, without loading the
secret into a normal text field. Save-only works offline; successful save is
reported only after required persistence succeeds. A failed secret write keeps
the draft and reports **Password not saved**; it must not silently downgrade.

Use one application-owned modal workflow for picker → edit → unlock → connect,
preserving draft fields and the back path. App-level focus traversal is enough;
a general nested-window framework is not required. During connecting show the
server, destination and current stage, with Cancel. Publish Provider plus first
Snapshot together; failures leave the prior Pane visible and usable. Pane titles
include server/account and path, so two different servers remain distinguishable
without relying on color. Narrow terminals need a stacked layout with reachable
buttons and scrolling, not clipped fields.

## Durable credential storage

**Saved credentials are required.** Optional “ask each time” behavior is useful,
but session-only passwords do not satisfy the first-version requirement.

The Secret Service specification describes durable secret collections, lookup
attributes, locked items and service-owned prompts. Attributes are not secret;
use an application identifier and opaque credential ID, never a password.
Unlocking can require interaction outside LightHouse, and can be cancelled.
The API does not standardize accepting an unlock password from a terminal.
[Secret Service specification §§1, 3, 5, 8–10](https://specifications.freedesktop.org/secret-service/latest-single/)
and [libsecret migration notes](https://gnome.pages.gitlab.gnome.org/libsecret/migrating-libgnome-keyring.html).

libsecret supplies a C API with GLib/GObject dependencies. Current upstream also
documents an encrypted-file backend using a secret obtained from a secret portal;
that is not proof of availability on a bare SSH session. Probe the deployment
environment instead of treating library installation as a working vault.
[API and dependencies](https://gnome.pages.gitlab.gnome.org/libsecret/),
[upstream README](https://github.com/GNOME/libsecret).

| Approach | Advantage | Constraint / decision |
| --- | --- | --- |
| Secret Service through libsecret | Reuses Linux credential infrastructure and existing unlock policy | Matches the agreed host-store direction; specify unavailable-service and unusable-unlock behavior, including over SSH. |
| Provisioned Secret Service on headless Linux | Keeps one credential API and durable secrets | GNOME's daemon supports reading an unlock password from stdin, but setup and unlock are backend-specific. This is an explicit operational dependency, not generic libsecret behavior. [Daemon source manual](https://raw.githubusercontent.com/GNOME/gnome-keyring/main/docs/gnome-keyring-daemon.xml) |
| External encrypted password manager, e.g. pass | Durable encrypted storage with terminal-oriented tooling | Requires GPG keys/agent and a defined prompt/cancellation integration; use a fixed adapter, not arbitrary shell interpolation. [pass documentation](https://www.passwordstore.org/) |
| Application encrypted vault with master password | Can offer the same TUI unlock flow on desktop and SSH | Adds encryption format, key derivation, atomic writes, recovery and master-password changes to scope; use a reviewed library, not custom cryptography. FileZilla demonstrates the UX pattern, not a design to copy blindly. [Master-password documentation](https://filezillapro.com/docs/v3/advanced/master-password/) |

The host credential store is the agreed direction. The external password-manager
and application-vault options above are research background, not additional v1
requirements. Specify the host-store integration and its failure paths.

Do not select plaintext/Base64 config as an invisible fallback. FileZilla's
documentation explicitly distinguishes its unprotected storage from master-
password protection. Saved credentials remain required when the host store is
available; store unavailability must be visible to the user.

## Failure and lifecycle behavior

| State | Proposed behavior |
| --- | --- |
| Vault locked | Show Unlock / Retry / Cancel and which store requires attention; preserve the server/path draft. Service prompts must not freeze redraw or cancellation. |
| Vault absent or unlock UI unavailable | Explain the host-store prerequisite and offer Retry, Cancel or explicit one-time login. One-time login is not “password saved”; no automatic fallback to another store. |
| Saved secret missing or login rejected | Prompt for replacement; distinguish vault failure from server rejection. Do not overwrite an existing saved credential merely because one login failed. |
| Certificate invalid or host mismatch | Explain failure and allow correction/cancel; no silent plaintext downgrade or automatic verification bypass. |
| Remote path missing or denied | Keep the requested path editable; explicitly offer the login directory instead of silently landing elsewhere. |
| Connection lost while browsing | Retain the last Snapshot with a visible stale/disconnected state; Reconnect retries the same endpoint and Location. |
| Connection lost during a Job | Keep the foreground Job's retry/cancel/result workflow; distinguish unknown mutation outcomes from failures known to precede execution. Never blindly replay delete/rename/source cleanup. |
| Disconnect / switch | Return to the remembered local Location or chosen new server; detach only this Pane and retain resources still owned by another Pane or Job. |
| Remove saved server / Forget password | State what is removed; bookmarks and credential deletion need explicit consistent behavior. Report incomplete cleanup if the vault is unavailable; do not claim deletion succeeded. |

The Job behavior must follow [ADR 0002](adr/0002-file-jobs-own-foreground-interaction.md).
Connection secrets must stay out of diagnostic messages, URLs, shell input,
history, profile exports and rendered buffers. Profile and vault writes are two
separate persistence operations: specify recovery from either failing and avoid
claims of atomic cross-store updates.

## Fit with the current application

[docs/UI.md](UI.md) and [ui/root.zig](../src/ui/root.zig) provide modal scope,
clipped layouts and text editing, but no ready-made profile list/form or automatic
focus traversal. [TextInput](../src/ui/text_input.zig) renders its original text
and has no password mode; a secret field must avoid passing raw password bytes
to Frame storage. Add the small controls this workflow needs without requiring
a general window framework.

[commands.zig](../src/app/commands.zig) leaves F2 unassigned. The application
[modal widget](../src/app/widgets/modal.zig) projects controller workflow state,
which can also own the picker/form/unlock/connecting sequence. Keep shell input
routing and the foreground Job restriction from ADR 0002.

[editor.zig](../src/app/editor.zig) only reads editor configuration; a writable
profile/bookmark store and secret persistence are new work. Provider switching
must preserve stable Pane pointers borrowed by application widgets, as described
in [the transport investigation](FTP-RESEARCH.md). The
[published tickets](FTP-TICKETS.md) separate persistence, transport, connection
lifetime, UI and file-action execution with explicit dependencies.

## Remaining design work

1. Specify the host credential-store integration and unavailable/locked-store
   behavior, including when LightHouse runs on a machine reached over SSH.
2. Confirm TLS modes (explicit FTPS default; implicit FTPS inclusion is open),
   path-base behavior and profile-removal/bookmark policy.
3. Walk through the proposed flow: first saved server, returning after restart,
   different remote server in each Pane, wrong password, locked store, missing
   path, cancel and disconnect. This is a planned usability check, not completed
   user testing. Review keyboard-only use and narrow-terminal layouts.
4. Specify save/retrieve/change/delete across restart, cancellation of unlock/login,
   secret handling, edits during existing sessions and failure between profile
   writes and vault writes. Defer executable test suites and live integration
   validation; these are not gates for the current design work.

This study supports ticket drafting now. Implementation tickets should follow
the agreed host-store direction and preserve credential persistence.
No application code or live vault
integration was implemented or tested for this note.
