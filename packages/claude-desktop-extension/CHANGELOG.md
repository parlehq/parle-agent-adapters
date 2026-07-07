# Changelog

## 0.3.1 (2026-07-07)

Stale-credential diagnostics (bundled `@parlehq/agent-client` refresh):

- 401 errors append a hint when PARLE_ROOM_AGENT_TOKEN on disk differs from the value the process loaded at startup (token likely rotated; restart the host process to reload it).
- `parle_setup` reports `ok: false` with a `warning` on a stale-vs-disk token; `parle_status` carries the same warning in `warnings`.

## 0.3.0 (2026-07-07)

Wire protocol hard cut (parlehq/parle #436/#437; bundled artifact refresh; behavior shipped in adapters commit 207c8cc without a version bump - this release corrects that):

- Parle-Version 2026-07-07 required; prior version rejected. Pre-cutover sessions invalid; reconnect with parle_connect.
- Secret parle_ses_ session credential selects sessions. Optional PARLE_SESSION_ALIAS claims a durable named route with generation fencing, but should stay unset for ordinary sessions.
- parle_ses_ added to redaction.

## 0.2.0 (2026-07-07)

MCP tool contract change (bundled `@parlehq/mcp-server` artifact refresh):

- New `parle_connect` tool: establishes or reuses the room agent session and returns a redaction-safe connection summary. Idempotent while the session is live.
- Reads and sends that lazily establish a session now include a `session` block identifying the session they created.
- `parle_status` exposes `agentSessionId` (room-visible operational metadata; classification tracked in parlehq/parle#48). `sessionHandle` stays redacted. Optional config values are marked `optional`.
- `parle_setup` reports connection posture (`connected`) and points at `parle_connect`.

Upstream API-first counterparts: parlehq/parle#47, #48, #49.

## 0.1.0

Pre-changelog release; see git history.
