# Architecture

## Core and UI

`LanebayCore` contains platform and application logic without UI frameworks. `LanebayUI` owns the SwiftUI board, design components, and SwiftTerm renderer; the app target presents a single board window and supplies zoom commands and orderly termination.

## Board model and persistence

`Workspace`, `Node`, `Group`, and the reserved `Loop` type are Codable value types in `LanebayCore`. A workspace has a schema `version`; the current schema is version 1. Nodes describe console, note, and panel board items, with their working directory, frame, optional agent/profile identifiers, title, and not started state. Group colors are stored as design token names, not resolved color values.

`WorkspaceStore` stores each workspace as `<id>.json` under `~/Library/Application Support/Lanebay/workspaces`. Its root URL can be injected for isolated use and tests. Saves encode the complete document to a unique temporary file in the same directory, then move or replace the destination so readers do not observe a partially written JSON document. The store supports list, load, save, and delete. On load, console nodes are marked not started because process sessions are not restored from disk.

The store accepts an optional migration hook that transforms a decoded JSON object from its stored schema version to the current version. This keeps version-specific transformations at the persistence boundary. A read or decode failure quarantines the source as `<id>.json.corrupt-<timestamp>` and throws a `WorkspaceStoreError.corruptFile` containing the quarantine URL and failure reason; `list()` propagates this error so callers can report the damaged workspace instead of silently omitting it. A newer unsupported schema is reported without moving the file. After load, every console node is marked not started regardless of its persisted not started flag.

## Process supervision

`ProcessSupervisor` is a Swift 6 actor that owns child processes and their pseudo terminals. `start(spec:)` returns a `StartedProcessSession` containing a stable `SessionID` and a single-consumer `AsyncStream<ProcessEvent>`.

### Launch and PATH

Launch uses `forkpty` with the requested initial terminal dimensions. The child changes to the requested directory and invokes `/bin/zsh -lc` with an `exec` command. Command names and arguments are individually shell-quoted. Bare executable names are resolved by the login shell **after** its startup files have configured PATH; paths containing slashes retain shell execution semantics. The environment inherits the host environment, applies caller overrides, and appends common Homebrew and user CLI directories. `resolveExecutable` is a standalone host-PATH lookup utility, not the launch resolver.

All strings and C argument/environment vectors are prepared before the fork. The child performs only signal setup, `chdir`, `execve`, and `_exit`. It resets terminal signal dispositions and clears the inherited signal mask: dispatch worker threads may block SIGTERM, which would otherwise prevent graceful termination. Setup/directory failure exits with 126; shell/command lookup failure exits with 127. Successful `start` means the child was created, not that exec succeeded; launch failures arrive through the event stream.

### I/O and lifetime

Blocking PTY reads, writes, and `waitpid(childPID, ..., 0)` run on dispatch threads, keeping them off the actor and Swift's cooperative executor. Writes use a serial queue per session, retry interrupted/partial writes, and hold a duplicated close-on-exec descriptor across suspension. Resize applies `TIOCSWINSZ` to the PTY master.

The reader awaits actor delivery of each byte chunk before reading the next. The independent reaper retries `waitpid` on EINTR and records the actual wait status. EOF and child exit can arrive in either order; the supervisor finishes only after both, so buffered output always precedes exactly one exit event. Normal exits report the process exit status; signal deaths report `128 + signal` and the signal number. Unexpected read/wait failures produce a `.failed` event. The master descriptor closes only after the reader is finished, avoiding descriptor reuse races.

Termination sends SIGTERM to the process group created by `forkpty`, then SIGKILL after the grace period (500 ms by default). Repeated requests keep the original deadline. An immediate request can also signal the child directly if its process group has not yet been established. On macOS the PTY can reach EOF when the leader exits while descendants remain alive; cleanup preserves the escalation timer while that process group still exists. The stream buffers at most 64 events (output chunks are at most 16 KiB each). If a consumer falls behind, the supervisor emits an explicit `.failed` event, stops enqueueing output, and terminates the process group immediately; the final exit event is retained. This bounds memory without silently corrupting a terminal stream. Cancelling stream consumption requests termination. The active reader/reaper retain the supervisor until cleanup completes.

### Scrollback and buffering

Each session retains a fixed-capacity byte ring, defaulting to 1 MiB; zero disables retention. Wrapping overwrites the oldest bytes without shifting history. `scrollback(for:)` returns a chronological snapshot during execution and after completion. The limit counts bytes, so a snapshot can start inside a UTF-8 sequence; terminal consumers must handle decoding boundaries.

Completed snapshots remain available until the owner calls `discardScrollback(for:)` or releases the supervisor. The board/session owner must discard history when deleting a session. Unread event buffering is bounded separately from the scrollback ring.

### Verification

Core integration tests exercise real PTYs: exact echo and nonzero exit status, output draining across multiple chunks, EOF before exit, initial size and resize observed with `stty`, input including a large write, login-profile PATH resolution, literal arguments, environment and directory handling, launch failures, ring wrapping, concurrent sessions, graceful TERM, and process-group KILL including a surviving descendant, completed-history disposal, and explicit overflow failure with a stalled output consumer. Tests isolate user shell startup files via temporary `ZDOTDIR` directories, synchronize with output markers, and use a three-second operation deadline. The descendant check polls process disappearance for at most one additional second and includes failure cleanup; it does not infer descendant death from PTY EOF.

## Canvas UI

`BoardViewModel` is a main-actor observable owner of workspace documents, selection, per-tab viewport state, and console sessions. Tabs create, rename, and switch workspaces. Document edits debounce for 300 ms; the save pass includes every dirty workspace, including tabs switched away from during the debounce. Failed saves remain dirty, surface a visible error, and can be retried. Quit flushes edits before terminating children and is cancelled if persistence fails. Workspace documents and tab names persist through `WorkspaceStore`; viewport, selection, and active tab are session-local.

The board uses the design system's left rail, console chrome, and bottom command bar. Background dragging and scrolling pan an unbounded world-coordinate canvas. Pinch zoom anchors to the gesture location; buttons and Command-plus/minus clamp zoom to 25–200%. Card-header dragging and corner resizing convert viewport deltas back into world coordinates; consoles have a minimum size of 280 × 160 points. Shift-click extends or toggles selection. The command bar sends to every selected running console. Selection uses the accent outline, and keyboard focus uses the separate system focus outline.

New and restored consoles are not started until Start is clicked. Shell, Codex, Claude Code, and OpenCode launch in the node's working directory through `ProcessSupervisor`. A `ConsoleSession` consumes the single event stream, forwards terminal input in order, and propagates terminal dimensions to the PTY. Its SwiftTerm view is retained across tab switches so emulator state and scrollback stay intact. Closing removes the board item, waits for process termination, and discards retained supervisor history. Shutdown joins launches and closes already in flight. `StatusHeuristics` classifies known permission/confirmation prompts as waiting for input, recognizable CLI prompts as idle after two seconds without output, and all other active output as running. Patterns and quiet interval are injectable for deterministic tests. Process completion and failures continue to set finished/error. Hook status delivery remains separate from this fallback.

`BoardViewModelTests` cover add/move/resize/close, selection and focus, anchored zoom limits, workspace round trips, debounced edits across tabs, save retry, live PTY command delivery, tab-switch session retention, PID termination, scrollback disposal, and shutdown during launch/close. The full `swift build` / `swift test` checks can run in restricted environments with workspace-local `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` plus SwiftPM's `--disable-sandbox` flag.

## Agent hook bridge and configuration

`HookServer` binds an `NWListener` to `127.0.0.1` on a randomized high port, retrying candidates until the bind succeeds. Each server instance gets a cryptographically unpredictable 256-bit bearer token. It accepts authenticated `POST /hook/<agent>` requests with a maximum 64 KiB body, parses JSON into typed `AgentEvent` values, and yields them through a bounded `AsyncStream`. The token and port are written to `~/.lanebay/hooks/runtime.json` with mode `0600`.

`HookScriptInstaller` writes `~/.lanebay/hooks/lanebay-hook.sh` with mode `0700`. It reads hook JSON from stdin, adds the normalized event supplied by the client config, posts to loopback with a one-second curl timeout, and always exits successfully so telemetry failures do not block an agent. The script requires macOS `/usr/bin/python3`, `/usr/bin/plutil`, and `/usr/bin/curl`.

`ConfigMerger` updates Claude's `settings.json` and Codex's `hooks.json`. Its roots can be injected for isolated use. Entries are marked in the shell command text, allowing removal without adding unsupported configuration keys. Existing valid files are backed up once as `*.lanebay.bak`; malformed or non-object JSON is refused before either config is changed. Repeated install is idempotent. Uninstall removes only marked commands and removes the generated hook script, leaving third-party entries intact. Claude-specific `PermissionRequest`, `Notification`, and `SubagentStop` hooks are not added to Codex. Golden tests use temporary fixture directories and never open real user config files.
