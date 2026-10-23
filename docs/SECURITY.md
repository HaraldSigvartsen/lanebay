# Security

## Local agent hook listener

- `HookServer` binds only to IPv4 loopback (`127.0.0.1`) and retries randomized high-port candidates for each launch until one binds.
- A fresh 256-bit bearer token is required on every request. The runtime file containing the token is mode `0600` under `~/.lanebay/hooks/`.
- Only `POST /hook/<agent>` requests are accepted. Request bodies are capped at 64 KiB, parsed as JSON, and delivered as typed events.
- Hook scripts use a one-second curl timeout and fail open, so a stopped listener or malformed event cannot prevent the CLI from proceeding.
- The listener does not expose an endpoint for commands or permission approval; events are observational status input.

## CLI configuration changes

- Claude and Codex configuration roots are injectable. Tests use temporary directories and never inspect or modify the real `~/.claude` or `~/.codex` paths.
- Installation validates both existing JSON files before writing either config and refuses malformed or non-object JSON.
- The first write preserves a `*.lanebay.bak` backup. Entries carry a Lanebay marker in their command string so uninstall can remove only managed entries.
- Hook scripts are installed with mode `0700`; unrelated settings and third-party hooks are retained.
- No CLI credentials are read, copied, or stored by the hook bridge.
