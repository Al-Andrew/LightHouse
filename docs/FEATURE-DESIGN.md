# External tools, path insertion, and destination conflicts

Design agreed with the user. This document describes planned behavior; these
features are not implemented yet.

## Agreed direction

### F4 editor

- F4 opens an editable terminal editor inside LightHouse in an independent session
  filling the full application area. The user exits the tool to return to the
  Panes; switching back while keeping the tool open is outside this feature.
  The persistent shell remains separate. F3 is left unassigned for future use.
- F4 acts on the Cursor entry independently of Marks. The initial supported
  targets are local regular files and symlinks resolving to regular files;
  directories retain their existing navigation behavior.
- Choose the editor from a config file, falling back to `$EDITOR` when the
  setting is absent. Use `$XDG_CONFIG_HOME/lighthouse/config.json`, falling back
  to `~/.config/lighthouse/config.json` when the configuration root is unset.
  The optional file stores executable and fixed arguments as a JSON array, for
  example `{"editor": ["nvim"]}`. The filename is appended as a separate argument.
- `$EDITOR` supports quoted arguments without shell evaluation. If neither
  configuration nor environment supplies an editor, F4 explains how to configure
  one. Invalid explicit configuration or a missing configured program produces
  an explanation and leaves browsing usable; it does not silently fall back.
  There is no `$VISUAL` or hardcoded `vi` fallback.
- Launch the editor in the active Pane's directory and pass the file separately
  from fixed editor arguments, without evaluating shell commands. Failed launch
  leaves the Panes usable with an explanation. Normal tool exit returns to the
  Panes and refreshes both; an unsuccessful exit retains final output until
  dismissed. Tool keys, including Ctrl+G, Ctrl+J, and function keys, go to the editor.
  F4 is unavailable while a file job or another modal workflow remains open.

### Ctrl+F Path insertion

- Ctrl+F with a Pane's Cursor entry asks its Provider what to insert into the
  persistent terminal, creates a session when none exists, and shows/focuses it.
  It inserts without Enter, clearing input, or ignoring existing input. Marks do
  not change the target. This is explicit input to the current foreground program,
  even if it is not a shell, and does not require prompt detection. It replaces
  directory synchronization in this feature discussion; automatic directory
  changing is outside this design.
- For local entries, insert the quoted absolute path followed by one space and
  no leading space. Files, directories, and symlinks are supported; use a
  symlink's own path. Exclude the Parent row. Refuse control-character paths with
  an explanation initially. Quoting uses original filename bytes rather than
  display escapes. A Provider supplies one unquoted reference or reports that
  insertion is unsupported. LightHouse owns quoting, control-character checks,
  the trailing space, and queueing.
- Initial quoting follows POSIX-style shell syntax, suitable for sh/Bash/Zsh
  command lines. There is no automatic syntax detection for an arbitrary shell
  or foreground program. Unsupported insertion is explained without injecting
  text or changing focus.
- Queue acceptance for Path insertion is all-or-nothing, including any paste
  framing. If it fails, terminal input and focus remain unchanged. This does not
  promise atomic delivery through the PTY after acceptance. Ctrl+F retains its
  normal terminal behavior when the terminal already has focus.

### File operations

- Copy/move conflict handling includes Directory merge, preserving unrelated
  destination entries, and overwrite, skip, and cancel choices for conflicting
  entries. Replacing an entire directory tree is not implied by merging.
- Conflict presentation includes an "apply to all" checkbox, initially off.
  Its choice is remembered only for the current job and matching conflict types;
  an overwrite decision for a file cannot authorize directory replacement.
- Automatically merge directory with directory. Files and symlinks may be
  replaced as entries, without following destination symlinks.
  File-versus-directory mismatches offer Skip or Cancel; Overwrite never
  authorizes recursive destination deletion.
- Remember choices for regular-file conflicts separately from conflicts involving
  symlinks. An ordinary "Overwrite all" cannot silently replace links.
- During a Directory merge for a move, leave skipped entries in the source,
  retain completed moves, and remove source directories only when empty.
  Cancellation retains completed moves and leaves remaining entries in place.
  Cross-filesystem moves remain unsupported in this feature.
- Copy/move errors affecting an individual entry offer Retry, Skip, and Cancel
  job. Retry repeats failed work without replaying completed directory children;
  Skip retains completed work and proceeds. An initially unchecked option can
  skip subsequent errors of the same kind in this job. Retry is never remembered
  as an automatic repeated action.
- If a directory error prevents further traversal, Skip abandons its unfinished
  portion and proceeds with its siblings, retaining completed children. Report
  the directory as incomplete. Retry resumes failed work; failure of a final
  step such as permission setting must not replay successful data transfers.
  Results distinguish completed work, skips, and unresolved errors; a partial
  job is not presented simply as "Completed."
- Deletion and directory creation retain their existing error results in this
  feature. Cancellation and failures such as worker-launch failure remain job
  outcomes, not entry prompts.
- File operations block terminal interaction while ongoing, including waiting
  for conflict/error decisions, and until the finished result is dismissed.
  This applies to copy, move, delete, and directory creation. The persistent
  shell and its foreground program continue running, with output collected;
  only user interaction is blocked. This replaces the earlier proposal to allow
  terminal use during jobs; current Ctrl+G behavior must change.
- A waiting job must support cancellation and application shutdown. Recheck
  affected entries before acting on a response; a destination changed since the
  prompt was shown requires a fresh decision rather than stale overwrite consent.

### Persistent terminal visibility and lifetime

- EOF from the persistent terminal ends only that terminal session. LightHouse,
  any external editor, and any file job remain alive; no workflow is canceled
  merely because the persistent shell exits.
- Ctrl+G continues switching focus between a visible terminal and the last active
  Pane, leaving the terminal visible. It is not an alias for Ctrl+J.
- Ctrl+J hides or shows the terminal. Showing gives it focus; hiding returns focus
  to the last active Pane and releases the space for the Panes. Hiding preserves
  the running shell. EOF closes its view. Ctrl+J with no existing session starts
  and shows a new one. File jobs continue blocking terminal interaction.
- A new shell starts in the active Pane's local directory when available;
  otherwise it starts in LightHouse's launch directory. Reuse the existing shell
  selection, including `--shell`, with fresh terminal state and no old input replay.
- Ctrl+J shares the LF byte in conventional input. Preserve normal CR Enter and
  pasted LF; an Enter key sending LF cannot be distinguished from Ctrl+J using
  that protocol. Scope Ctrl+J as a terminal-visibility action in ordinary Pane and
  persistent-terminal input, not as a global interceptor of modal or tool input.

## Integration rules

- Ctrl+G only changes focus when the persistent terminal is visible; Ctrl+J and
  Ctrl+F supply the explicit show/create behavior. Existing `t` and `z` commands
  keep their focus and zoom intent through the same session creation/show rules.
- Keep the current visible terminal at application startup. Hiding and showing
  an existing terminal preserves its session and chosen size; EOF returns focus
  to the last active Pane if necessary without changing an active modal or tool.
- Resolve and validate a Ctrl+F reference before starting a missing terminal.
  Unsupported references do not create a shell. Session-start or queue failures
  explain the failure without changing focus or inserting a partial reference.
- Missing or unusable local working directories fail launch with an explanation;
  they do not silently start a local operation in a different directory. The
  launch-directory fallback is for a Pane without a usable local representation.
- Application quit and host shutdown remain explicit cleanup paths: cancel/join
  file work and terminate/reap owned sessions. Persistent-terminal EOF alone is
  not an application-quit request.

## Implementation requirements derived from the behavior

- Keep configuration parsing, Provider reference resolution, terminal formatting,
  workflow ownership, and process execution in the modules owning those rules.
  Provider reference support must not depend on local file-job execution support.
- The controller owns job interaction and the external tool workflow. Enforce
  availability in both direct invocation and View input routing; painting and
  observations never start, finish, or retry work.
- Persistent-terminal EOF is independent of host-input EOF and application
  shutdown. Session replacement must release the old process/PTY resources and
  discard pending input/replies so they cannot reach the new shell.
- Workers expose owned conflict/error observations and consume explicit decisions.
  A waiting worker must wake for cancellation/shutdown. Borrowed Pane data cannot
  remain live across a prompt or asynchronous tool/job lifetime.
- Preserve the regular-file publication guarantee when adding overwrite: failed
  or canceled preparation leaves the old destination intact, and successful
  publication replaces the entry only after the new file is complete. Refuse
  source/destination aliases that would overwrite or remove the same source.
- Retry rechecks current filesystem state and may lead to a new conflict prompt.
  Diagnostics identify the failed entry and stage, with source and destination
  context. Cleanup failures and partial directory progress must not be hidden.
- Keep confirmed behavior in the specification while leaving internal type names,
  storage, parsing helpers, and process-launch mechanics to implementation.

## Verification expected from implementation

- External tools: configuration precedence and invalid input; literal filename
  arguments and fixed options; local file/symlink eligibility; isolated shell and
  editor lifetimes; full-area resize and key forwarding; launch/exit failures;
  both-Pane refresh and terminal restoration.
- Persistent terminal: EOF leaves the application, editor, and file job alive;
  creation by Ctrl+J or Ctrl+F, launch failure and repeated cleanup; independent
  Ctrl+G focus and Ctrl+J visibility; ordinary Enter and pasted newlines; hidden
  shell output, geometry restoration, no old input replay; and restart/toggle
  restrictions during file jobs and tool sessions.
- Path insertion: local and opaque test Providers; unsupported references;
  Cursor versus Marks and Parent row; spaces, apostrophes, shell metacharacters,
  control characters, and symlinks; exact spacing; all-or-nothing queue admission;
  resulting focus; foreground-program delivery and normal terminal Ctrl+F.
- File jobs: automatic directory merge; separate conflict-choice groups; atomic
  replacement and alias rejection; entry/stage Retry and Skip; current-job-only
  remembered choices; incomplete-directory results; partial merged moves;
  changed destinations; cancellation/shutdown while waiting; and terminal input
  blocked until result dismissal while output continues to drain.
- Preserve existing Pane, Provider, Job, and View behavior outside the chosen
  changes. Replace tests asserting shell interaction during jobs with tests for
  the newly chosen rule. Run `zig build test`, `zig build test-integration`, and
  `zig build fmt-check` during implementation.

## Current implementation constraints

- App currently owns one persistent PTY and Emulator, and that PTY's EOF ends
  LightHouse. The agreed design replaces this rule with independent session
  lifetime. The current shell spawn path is
  documented as running before workers start; runtime tool launching needs a
  suitable process-creation path.
- Input decoding currently maps both LF and CR to Enter while retaining the
  original byte. Pane Enter is consumed before global command dispatch, so
  Ctrl+J needs deliberate decoding/routing rather than an ordinary text binding.
- There is no shell prompt/readiness detection. Terminal input is queued, and
  explicit insertion must define its effect on whatever currently receives it.
- Provider display text is not a filesystem path. Local execution uses the
  Provider's identity-checked local-path conversion, and filenames retain raw
  bytes even when their displayed text contains escapes.
- Jobs currently stop at the first conflict. Regular-file copies publish only
  after completion; moves use no-replace rename and reject cross-filesystem
  moves. There is no worker state for waiting on a conflict decision.

Starting points: `src/app.zig`, `src/platform/linux.zig`,
`src/terminal/emulator.zig`, `src/core/directory.zig`,
`src/core/operations.zig`, and `src/app/controller.zig`.

## Implementation tickets

1. [#21: Persistent terminal visibility, focus, and session lifetime](https://github.com/Al-Andrew/LightHouse/issues/21):
   Ctrl+G versus Ctrl+J, shell EOF, creation, hidden-session processing, and workflow gating.
2. [#22: Provider-defined Path insertion with Ctrl+F](https://github.com/Al-Andrew/LightHouse/issues/22):
   includes create/show behavior; depends on #21.
3. [#23: Configured F4 editor in an independent full-area terminal](https://github.com/Al-Andrew/LightHouse/issues/23):
   depends on #21 while preserving separate tool and persistent-shell policies.
4. [#24: Copy/move merging, conflict choices, and per-entry error recovery](https://github.com/Al-Andrew/LightHouse/issues/24):
   coordinates with #21 to preserve terminal blocking for all file jobs until result dismissal.

All four issues are labeled `ready-for-agent`. Implement #21 before #22 and #23;
coordinate controller/View changes in #24 with the terminal work.

These are user-facing features; terminal lifecycle work is required by the new
behavior, not a reopening of the speculative refactor closed in issue #19.
