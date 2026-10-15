# UsageBar

macOS menu bar meter for Claude, Codex and Copilot subscription usage. One status item per account.

    ./build.sh && open UsageBar.app

## Homebrew

    brew tap gregorjan/tap
    brew install --cask usagebar

The cask is unsigned — I am not willing to pay $99 for an Apple Developer ID — so macOS blocks the first launch. Allow it in Applications: Control-click UsageBar.app, choose Open, then Open again. Later launches work normally.

## What it does

- Refreshes every 5 minutes, and on demand from any item's **Refresh usage** entry.
- **Reconnect Claude…** (also Codex/Copilot) renews authorization for the saved account in place. No sign-out, deletion, or adding another account is needed. Reconnecting as a different account is rejected without changing the saved account.
- Each provider fetches independently. Failed requests retain last-known usage (also across restarts), marked `⚠︎`; the dropdown and tooltip show the error and last successful update. With no saved reading, an error shows `⚠︎`, not a blank percentage.
- Access tokens renew automatically. Claude retries once after HTTP 401, and concurrent renewals share one request. Rotated tokens update the Keychain vault in place; failed saves are reported and retried. If the provider invalidates the refresh token itself, live usage cannot resume without fresh authorization.
- The bar shows percentages only. Reset times live in the dropdown, except for a window at 90% or more, which shows its reset inline.
- Multiple accounts per provider are supported: sign in again and a second status item appears.

## Tokens

Its own, obtained through its own OAuth flows, stored in one Keychain item (`to.gregor.usagebar` / `vault`). It reads nothing from `~/.codex`, `~/.claude` or `~/.config/github-copilot`, and never touches browser cookies.

| Provider | Flow | Usage endpoint |
|---|---|---|
| Claude | PKCE via `claude.ai/oauth/authorize`, paste `code#state` back | `api.anthropic.com/api/oauth/usage` |
| Codex | PKCE via `auth.openai.com`, loopback callback on `localhost:1455` | `chatgpt.com/backend-api/codex/usage` |
| Copilot | GitHub device flow | `api.github.com/copilot_internal/user` |

The Claude and Codex endpoints are undocumented and the flows use those CLIs' public client ids; they can change without notice. Copilot's is equally undocumented but stable in practice.

## Keychain prompts

The Keychain ACL is tied to the binary's code signature and `build.sh` signs ad-hoc, so every rebuild is a new identity and macOS asks once for the vault. A stable self-signed identity would remove even that.

## Log

`~/Library/Logs/UsageBar.log` — one line per fetch and per render.
