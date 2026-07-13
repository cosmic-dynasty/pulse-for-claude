# Pulse for Claude Changelog

*Created: July 12, 2026 at 5:23 PM CDT*

## v1.0.9 (2026-07-12)

- **Paste works in dialogs** - Cmd+V (and cut/copy/select all/undo) now work in the "Track API Spend" and "Set Credits Balance" text fields. Menu bar apps have no Edit menu, so macOS had nowhere to route the paste shortcut; Pulse now installs a hidden one at launch.

## v1.0.8 (2026-07-12)

- **Staleness timestamps** - Menu footer now shows "data 4m ago" when polls are missed (sleep, network pause). Error states also display age when showing old data.
- **Exponential backoff retry** - Network and HTTP 5xx failures retry automatically (2s, 5s, 15s delays) instead of waiting silently for the next poll.
- **TTL cache for menu opens** - Menus opened within 45 seconds of a fresh fetch show cached data instantly without a network call, improving responsiveness.
- status.json now includes `lastSuccessAt` (ISO8601) so other tools can read data freshness.

## v1.0.7 (2026-07-12)

- Refresh latency improvements: usage, models, and spend fetches run in parallel.
- "Refreshing..." state indicator in menu during fetch.
- Menu stays open when clicking Refresh Now.
- 10 second network timeouts (down from 20).
- Auto re-seed of a rejected refresh token from Claude Code, exactly once per attempt, before asking for a manual reconnect.
- status.json health file for debugging staleness and rate limiting.

## v1.0.3 (2026-06-17)

- Refresh Now / Reconnect button revives a dead login in one click.
- File-first credentials reading avoids keychain prompts in steady state.

## v1.0.2 (2026-06-15)

- Pulse owns its keychain item, seeded once from Claude Code.
- Stops repeated keychain prompts on app wake.
- Single-flight token renewal.

## v1.0.0 (2026-06-14)

- Initial release.
- Live Claude plan usage in your Mac menu bar.
- Shows 5-hour limit, weekly limits per model, extra usage credits.
- Reads OAuth token from Claude Code.
