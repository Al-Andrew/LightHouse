# FTP provider investigation

Investigated 2026-09-20. The user selected full file actions for the first
version: browsing, upload/download, move/rename, directory creation and deletion.
Copy and move must work in every direction between supported Providers,
including separate FTP servers. Transfer mechanics such as local temporary
storage are implementation choices, not restrictions on the supported pairs.
The first version also requires login, saved server credentials, and a window
for choosing a server and Location. See the
[connection and UI study](FTP-CONNECTION-UX.md) and
[published ticket breakdown](FTP-TICKETS.md).
Credentials use the store on the machine running LightHouse, including over SSH.
Current scope is design and ticket preparation; protocol test suites, test-server
fixtures and live-server validation are deferred.
The implementation recommendations below remain proposals, not an ADR.
Recommendation: use libcurl behind an FTP Provider; prove cancellation and
connection switching with browsing first, then complete the file-action executors
before releasing the first version. Browsing alone does not meet this scope.
The existing Provider interface covers listings, but transfers and connecting a
running Pane require additional application work.

## Confirmed repository constraints

- [PROVIDERS.md](PROVIDERS.md) makes Location identity Provider-specific and
  requires stable context lifetimes, owned Snapshots, cheap UI-thread resolution,
  worker scans, and prompt cancellation. Connection discovery cannot happen in
  `resolve`, `display`, or capability observations.
- [directory.zig](../src/core/directory.zig) already permits missing size and
  modification time. Remote metadata does not require inventing zero values.
- [pane.zig](../src/core/pane.zig) chooses a Provider at creation; there is no
  runtime Provider-switching API. Application/controller/widgets retain Pane
  pointers. A proposed connection workflow should preserve the Pane object and
  publish Provider plus first Snapshot together on success, retaining the previous
  listing on failure. Contexts must outlive all borrowing workers and future jobs.
- [operations.zig](../src/core/operations.zig) checks both capabilities and the
  identity-checked `localPath` bridge. Enabling FTP flags cannot enable transfers.
  Its relative destinations currently use the local source base; cross-provider
  preparation needs destination-provider semantics and owned connection state.
- [controller.zig](../src/app/controller.zig) has local-only external editing.
  [ADR 0002](adr/0002-file-jobs-own-foreground-interaction.md) requires file jobs
  to retain foreground interaction through result dismissal. Neither behavior
  should change incidentally while adding FTP.
- [main.zig](../src/main.zig) has no connection options, and
  [editor.zig](../src/app/editor.zig) supplies editor configuration rather than
  a connection-profile or credential system.
- [build.zig](../build.zig) targets Linux and links libc;
  [build.zig.zon](../build.zig.zon) requires Zig 0.16.0 and has no curl dependency.
  The investigation's environment probe found curl 8.18.0 with FTP/FTPS,
  AsynchDNS and SSL, but `pkg-config --modversion libcurl` failed. Having the
  executable does not establish that headers/linkage for the app are available.

## Transport choice

| Option | Assessment for this application |
| --- | --- |
| libcurl through C interop | Recommended: existing FTP, TLS, passive networking and transfer APIs; isolate C handles, options and callbacks inside a transport module. Requires an explicit dependency/build policy and cancellation adapter. |
| Invoke the curl executable | Useful for a throwaway protocol probe; production would also need process lifetime, credential delivery, diagnostics and output framing policy. |
| Implement FTP in Zig | Offers direct `std.Io` control, but makes LightHouse own FTP reply/state handling, two connections and TLS. Too broad for this Provider investigation. |

These are engineering recommendations, not benchmark results. libcurl exposes
FTP commands through its [easy options](https://curl.se/libcurl/c/CURLOPT_CUSTOMREQUEST.html)
and application-driven work through its [multi interface](https://curl.se/libcurl/c/libcurl-multi.html).
Select system linking versus a pinned build before implementation; validate the
linked library's FTP, TLS and asynchronous DNS features with
[curl_version_info](https://curl.se/libcurl/c/curl_version_info.html).

## Listing and Locator rules

Confirmed protocol facts: MLSD provides machine-readable facts and names;
fact names and Type values are case-insensitive, while filename bytes must be
preserved. `cdir` and `pdir` describe current/parent directories. Size and Modify
may be absent; timestamps use UTC. The first separating space ends the facts;
remaining spaces belong to the name. FEAT advertises MLSx as `MLST`, and
`OPTS MLST` selects facts. TVFS slash-based path semantics are optional.
See [RFC 3659 §§2, 6–7](https://www.rfc-editor.org/rfc/rfc3659.html).

Recommendation: request a directory URL with constant `CUSTOMREQUEST="MLSD"`,
parse the data response ourselves, omit `cdir`/`pdir`, retain optional metadata,
and apply the Pane's requested sort/hidden options. libcurl allows replacing the
FTP listing command; this option passes text verbatim, so never construct it
from a filename. See [CURLOPT_CUSTOMREQUEST](https://curl.se/libcurl/c/CURLOPT_CUSTOMREQUEST.html).
Buffer/parser limits and duplicate-name handling must be explicit; unsupported
types should remain unknown rather than becoming guessed navigable directories.

LIST is system-dependent information intended for humans; NLST returns names
without metadata. Therefore neither is a general replacement for typed MLSD
entries. See [RFC 959 §4.1.3](https://www.rfc-editor.org/rfc/rfc959.html).
Proposed first scope: require MLSD and report unsupported servers clearly.
Add a tested LIST compatibility layer only if target servers require it.

curl's `ftp://host/` starts from the login directory. Server-absolute paths use
`//` or `/%2f`; curl also normalizes dot segments by default.
See [curl URL syntax](https://curl.se/docs/url-syntax.html#FTP).
Recommendation: keep endpoint/authentication in an owned connection context,
and Locator bytes separate from transport URLs. Decide whether `/` means the
connection's browsing root or server root. Discover any server-dependent login
directory during connection work; UI callbacks then perform only lexical work.
Document a slash-path server scope rather than claiming arbitrary FTP filesystems.
Encode filename bytes exactly once when constructing transport URLs; test `%`,
`#`, spaces, non-ASCII and dot segments. Reject unrepresentable command bytes.
[CURLOPT_URL](https://curl.se/libcurl/c/CURLOPT_URL.html) requires encoded URLs
and supports restricting allowed protocols; keep this adapter limited to FTP/FTPS.

## TLS and connection behavior

Recommendation: offer explicit FTPS as the default connection mode, with plain
FTP an explicit choice. For explicit FTPS use an FTP URL and `CURLUSESSL_ALL`,
which requires protection of both control and data channels and fails if it
cannot obtain it. Do not use opportunistic `TRY` or control-only protection.
See [CURLOPT_USE_SSL](https://curl.se/libcurl/c/CURLOPT_USE_SSL.html).
Whether to ship implicit FTPS in the first increment is an open decision.

Keep certificate-chain and hostname verification enabled, using system CA
configuration or an explicitly configured CA file. These are separate checks.
See [VERIFYPEER](https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYPEER.html) and
[VERIFYHOST](https://curl.se/libcurl/c/CURLOPT_SSL_VERIFYHOST.html).
Keep passwords outside Locators, labels, references and diagnostics; supply
credentials through [USERNAME/PASSWORD options](https://curl.se/libcurl/c/CURLOPT_USERNAME.html).
Required UI: login, persistent server credentials, and a server/Location picker.
Connection profiles hold host, port, username, TLS mode and saved Locations;
credentials are stored separately. The persistence backend and detailed
connection workflow are studied in [FTP-CONNECTION-UX.md](FTP-CONNECTION-UX.md).
Session-only passwords do not satisfy the agreed first-version scope.

Use passive networking: curl defaults to EPSV with PASV fallback, and EPSV
supports IPv6. Retain the policy of using the control peer's address for PASV.
See [FTP_USE_EPSV](https://curl.se/libcurl/c/CURLOPT_FTP_USE_EPSV.html) and
[FTP_SKIP_PASV_IP](https://curl.se/libcurl/c/CURLOPT_FTP_SKIP_PASV_IP.html).

## Cancellation is the main transport integration gate

libcurl handles must never be used concurrently by different threads. Initialize
globally before workers, use worker-owned handles, and set `NOSIGNAL=1`.
With synchronous DNS, this disables effective DNS timeouts; an asynchronous
resolver build avoids that limitation. See [thread safety](https://curl.se/libcurl/c/threadsafe.html).
Do not put one mutable FTP handle in a shared Provider context for both Panes.

The easy interface's progress callback can abort transfers but may run only
about once per second when idle, and requires `NOPROGRESS=0`.
See [XFERINFOFUNCTION](https://curl.se/libcurl/c/CURLOPT_XFERINFOFUNCTION.html).
Its sockets are not the supplied `std.Io`, so `Future.cancel` alone is not a
proven cancellation mechanism for this adapter.

Recommendation: drive worker-owned multi/easy handles with a short bounded
`curl_multi_poll` wait, checking the Pane cancellation flag between steps and
removing canceled transfers. The poll API accepts a timeout and supports an
explicit wakeup from another thread; removal is supported during transfers.
See [multi_poll](https://curl.se/libcurl/c/curl_multi_poll.html) and the
[multi interface](https://curl.se/libcurl/c/libcurl-multi.html).
Require asynchronous DNS; multi still blocks on synchronous resolution.
This is a proposed exception/adapter to the Provider's `std.Io` preference,
not proof of a hard shutdown bound. Test resolver and handle cleanup too.
Set explicit [connect](https://curl.se/libcurl/c/CURLOPT_CONNECTTIMEOUT_MS.html),
[server-response](https://curl.se/libcurl/c/CURLOPT_SERVER_RESPONSE_TIMEOUT.html)
and [overall scan](https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html) deadlines.

## First-version file actions

The agreed scope covers the existing F5–F8 actions for FTP Locations, with copy
and move available across every supported Provider pair:

| Source | Destination | Copy and move in v1 |
| --- | --- | --- |
| Local | Local | Required; preserve existing behavior |
| Local | FTP/FTPS | Required |
| FTP/FTPS | Local | Required |
| FTP/FTPS | FTP/FTPS, same server | Required |
| FTP/FTPS | FTP/FTPS, different servers | Required |

This includes plain FTP and FTPS combinations. Operation availability still
depends on valid sources and structural capabilities; server permissions and
network failures are execution results, not reasons to omit a Provider pair.
Proposed behavior and remaining execution design decisions:

- Copy transfers files and directory trees across all pairs above,
  retaining the existing destination-conflict and Directory merge workflows.
- Move includes remote rename/move and transfers across all pairs above.
  For a transfer-based move, remove each source only after its destination has
  been successfully completed. Report failed source cleanup as incomplete move
  work; do not repeat a successful transfer blindly on retry.
- Directory creation and deletion operate on the active FTP Pane. Recursive
  deletion retains explicit confirmation and reports partial completion.
- All actions use foreground Jobs with progress, cancellation and failure
  decisions. Define partial-file handling, overwrite behavior, link traversal,
  and recovery when a connection drops after a mutation but before its result is
  known. These are first-version design requirements, not later polish.

Execution may stream through the client, stage data in local temporary storage,
or use an applicable server operation. The user does not need to select a
strategy, and direct server-to-server transfer is not a requirement. Whichever
strategy is chosen must preserve conflict decisions, cancellation, accurate
partial results and source-retention rules. Remote editing through F4 is a
separate workflow from these file actions.

## Proposed implementation order

These are implementation steps toward the full first version, not separate
release scopes.

1. Integrate transport linkage, MLSD parsing, FTPS validation and cancellation,
   including shutdown behavior.
2. Add Connect/Disconnect and transactional Provider switching, then browsing,
   refresh, sorting, hidden entries and navigation. File actions remain unavailable
   until an executor supports them. Decide Path insertion syntax separately.
3. Add copy across every Provider pair through explicit executor dispatch, owned requests and
   foreground Job decisions, including partial-file handling, destination
   conflicts, recursion and reconnect behavior.
4. Complete remote mkdir/delete, remote rename/move and moves across every
   Provider pair with explicit source-cleanup behavior. Include transfers between
   distinct FTP servers before declaring the first version complete.

## Deferred verification considerations

The following are notes for later implementation work, not current test tasks or
prerequisites for the design or tickets. No fixtures or protocol suites are being
built in this phase.

Potential coverage includes two Panes scanning different directories concurrently;
connect/reconnect/login failures retaining the previous listing; cancellation
during DNS, connect, login, TLS and listing; stale scan publication; malformed,
missing and unknown MLSD facts; empty/duplicate/control-containing names;
spaces/percent/hash/non-ASCII names; MLSD unsupported; rejected certificates;
and root/login-directory navigation. File-action coverage can address correct
Provider dispatch across the entire matrix above, recursive copy/delete,
directory creation, rename, conflict
behavior and destination state after partial failure or cancellation. Move
behavior must preserve sources for incomplete transfers and report failed
source cleanup accurately. Consider ambiguous mutation outcomes after
disconnect and ensure retries cannot silently lose data.
No implementation or live-server validation was performed here.
