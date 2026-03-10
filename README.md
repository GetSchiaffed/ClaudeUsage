# ClaudeUsage

A lightweight macOS menu bar app that monitors your [Claude Code](https://claude.ai/code) usage in real time — showing token counts, API-equivalent cost estimates, and plan utilization windows without leaving your workflow.

## Quick Start

```bash
git clone https://github.com/GetSchiaffed/ClaudeUsage.git
cd ClaudeUsage
chmod +x build.sh
./build.sh
open ClaudeUsage.app
```

> Requires macOS 12+ and Xcode Command Line Tools (`xcode-select --install`)

---

## Features

- **Today's cost** — API-equivalent spend shown directly in the menu bar
- **Token breakdown** — input, output, cache creation, and cache reads for the current day
- **Usage windows** — 5-hour session and 7-day weekly limits with live utilization % and reset times
- **Live data** — fetches real utilization and reset timestamps directly from the Anthropic usage API (same data as Claude Code's built-in panel)
- **Estimated fallback** — if the live API is unavailable, falls back to JSONL sliding-window calculation
- **Recent sessions** — last 10 sessions with project name, timestamp, and cost
- **Plan efficiency** — compares your daily average against your monthly plan cost (🟢/🟡/🔴 indicator)
- **Multi-account** — detects the active Claude account via `claude auth status`
- **Dark/Light menu** — toggle menu bar appearance independently of system theme
- **Launch at login** — optional background autostart via LaunchAgent

---

## Requirements

- macOS 12 (Monterey) or later
- Xcode Command Line Tools

  ```bash
  xcode-select --install
  ```

- [Claude Code CLI](https://claude.ai/code) installed (one of):
  - `/usr/local/bin/claude`
  - `/opt/homebrew/bin/claude`
  - `~/.npm/bin/claude`
  - `~/.local/bin/claude`

---

## Build & Run

```bash
cd ClaudeUsage
chmod +x build.sh
./build.sh
open ClaudeUsage.app
```

The build script compiles `ClaudeUsage.swift` into a self-contained `.app` bundle — no Xcode project required.

### Rebuild & restart

```bash
pkill ClaudeUsage 2>/dev/null; ./build.sh && open ClaudeUsage.app
```

---

## How It Works

### Data source

Reads `~/.claude/projects/*/[sessionId].jsonl` — the log files written by Claude Code during every session. Parses `type == "assistant"` entries to extract token counts per model.

### Cost calculation

The JSONL logs contain **no `costUSD` field** (subscription plans aren't billed per-token). All costs shown are **API-equivalent estimates** calculated from token counts using Claude's published API pricing:

| Model | Input | Output | Cache Create | Cache Read |
|---|---|---|---|---|
| claude-opus-4\* | $15 / M | $75 / M | $18.75 / M | $1.50 / M |
| claude-sonnet-4\* | $3 / M | $15 / M | $3.75 / M | $0.30 / M |
| claude-haiku-4\* | $0.80 / M | $4 / M | $1.00 / M | $0.08 / M |

These are estimates — your actual subscription cost may differ.

### Account detection

Runs `claude auth status` on each refresh cycle to detect the active account (email, org, subscription type). Session logs contain no account field, so stats are aggregated across all local sessions.

### Live usage API

To show real utilization percentages and reset times, ClaudeUsage calls the same internal Anthropic endpoint used by Claude Code's "Account & Usage" panel:

```
GET https://claude.ai/api/organizations/{orgId}/usage
```

This requires a valid `sessionKey` cookie from your browser. ClaudeUsage reads it automatically from Safari, Chrome, Brave, or Arc — see [Permissions & Privacy](#permissions--privacy) below.

If no cookie is found or the request fails, the app falls back gracefully to local JSONL estimates.

### Settings

Click **Settings…** in the menu to:
- Set your monthly plan cost (default: $20) — used for the efficiency indicator
- Enable/disable **Launch at login** (creates `~/Library/LaunchAgents/com.claudeusage.app.plist`)

---

## Permissions & Privacy

ClaudeUsage runs entirely on your Mac and **sends no data to any external server** (other than the Anthropic API call described above, which uses your own account credentials).

The app accesses the following local resources:

| Resource | Why |
|---|---|
| `~/.claude/projects/*/` | Reads Claude Code session logs (JSONL) for token counts |
| `claude auth status` CLI | Detects your active account (email, orgId) |
| Browser cookies (`sessionKey`) | Authenticates the Anthropic usage API call to get live reset times |
| macOS Keychain | Reads the browser's encryption key to decrypt the `sessionKey` cookie (Chrome/Brave/Arc only) |

### Cookie reading details

- **Safari**: reads the binary cookies file directly — no decryption needed
- **Chrome / Brave / Arc**: cookies are AES-128-CBC encrypted; the decryption key is read from your macOS Keychain (this is standard practice — it's the same key your browser uses)

The first time the app accesses the Keychain, macOS will show a permission prompt. You can deny it — the app will fall back to local JSONL estimates for usage data.

---

## Troubleshooting

**Menu shows `$--.--`**
The app is still loading. Wait a moment and click Refresh, or check that Claude Code is installed and `claude auth status` returns valid output.

**No live utilization % (shows `--`)**
The app couldn't read your browser session cookie. This happens if:
- You denied the Keychain permission prompt
- Your browser isn't Safari, Chrome, Brave, or Arc
- You're not logged into claude.ai in your browser

The app will still show token counts and estimated cost from local logs.

**"Not logged in" in menu**
`claude auth status` returned no account. Run `claude auth login` in your terminal.

**Build fails: `swiftc not found`**
Install Xcode Command Line Tools: `xcode-select --install`

---

## Project Structure

```
ClaudeUsage/
├── ClaudeUsage.swift   # Full source — single-file app
├── build.sh            # Build script (no Xcode project needed)
└── README.md
```

---

## License

MIT — see [LICENSE](LICENSE).
