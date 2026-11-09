# Lanebay

Lanebay is a native macOS app that puts real terminals on one board. Each card
is a live PTY console running a shell or a CLI coding agent (Codex, Claude Code,
OpenCode and others). You can arrange cards on a pan-and-zoom canvas, see at a
glance which ones are working, waiting for input or idle, and send one prompt to
several consoles at once.

> **Status: early alpha.** Expect rough edges and breaking changes. There are no
> signed releases yet. Build it from source.

## Features

- Pan/zoom canvas of terminal cards (SwiftTerm), with workspaces as tabs.
- Consoles run through your login shell, so your `PATH` and CLI logins work as usual.
- Status lights per console from optional agent hooks (Claude Code, Codex) with
  an output/idle heuristic fallback.
- Board layout is saved locally and restored on launch. Consoles come back stopped
  and start when you click Start.
- Send tasks to selected consoles, groups with a lead, and connected agent cards.
- Chat with cards by name or `@` handle, and route replies along wires.
- Schedule messages for a card in the app or with `lanebay cron`. Scheduled messages
  currently run only while the app is open and for the active workspace.
- Manage agents, models, loops, and workspaces from the board. Utility panels show
  docs, code, Markdown, skills, memory files, GitHub (via `gh`), and local usage.
- "Ask before sending to a terminal" is on by default. Lanebay never auto-approves agent permission prompts.

## Local CLI

With the app open, install the CLI and send a short task to an agent card:

```sh
scripts/install-cli.sh
lanebay spawn --provider freebuff --cwd ~/Code/myrepo --task "Run the tests" --timeout 55m
lanebay status
lanebay cron add Builder --when "hverdager 09:00" --text "Run the tests"
lanebay cron list
```

The control socket accepts only the current user and a per-launch token. Agent
tasks and handoff notes are written under `<cwd>/.lanebay/handoffs/`.

## Privacy

No account and no telemetry. Board state lives in
`~/Library/Application Support/Lanebay/`. Nothing leaves your Mac except what the
CLIs you run do themselves. See [docs/SECURITY.md](docs/SECURITY.md).

## Requirements

- macOS 14 or later (Apple silicon tested)
- Xcode 26 with Swift 6.2 or later (developed with Swift 6.3)

## Build and test

```sh
swift build
swift test
swift run Lanebay
```

## Package a local app

```sh
scripts/package.sh
```

This creates an ad-hoc signed `dist/Lanebay.app` and `dist/Lanebay.dmg` for local
use. It is not notarized. See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Docs

- [Architecture](docs/ARCHITECTURE.md)
- [Design system](docs/DESIGN.md)
- [Security](docs/SECURITY.md)
- [Distribution](docs/DISTRIBUTION.md)

## License

MIT, see [LICENSE](LICENSE). Third-party: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and
[Sparkle](https://sparkle-project.org) (MIT, see `Vendor/Sparkle/LICENSE`).
