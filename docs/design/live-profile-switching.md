# Live profile switching

Status: implemented foundation with Pi bridge

## Decision

Live profile switching is local adapter lifecycle, not Parle API meaning. The HTTP API remains the canonical source for sessions, room entry, projection watermarks, and session retirement.

The shared client owns a credential-free `performProfileSwitch` orchestrator. It guarantees this ordering:

1. Resolve and validate the target without changing live state.
2. Prepare a target session on scratch state.
3. Commit the prepared state synchronously, including stopping use of the old room binding and resetting room-scoped cursor and deduplication state.
4. Retire the old agent session best-effort.
5. Restart host delivery best-effort.

Failures during resolution or preparation leave the active profile unchanged. Cleanup failures after commit are warnings because the new profile is already active and the old session will expire server-side.

## Persistence

Switches are ephemeral and process-local. They do not rewrite `.env`, the profile catalog, or credentials. A cold restart returns to the configured `PARLE_PROFILE` or implicit default profile.

Persistent profile selection is a separate host policy and is not part of this primitive.

## Bridge ownership

The shared orchestrator contains no credentials and no watcher implementation. Each bridge supplies its existing credential-bearing preparation and lifecycle callbacks.

Pi owns its in-process watcher, responsive-delivery buffer, injection state, footer, and runtime snapshot. Its bridge therefore:

- prepares the target using its existing bootstrap against scratch runtime state
- synchronously stops the old watcher and adopts the target
- resets cross-room baseline, pending, seen, and injected state
- publishes one coherent runtime snapshot
- restarts the watcher with the target configuration

The MCP bridge does not expose switching yet. Its watcher is a separate sibling process launched with frozen room and token environment, and the stdio tool process has no handle or IPC mechanism to stop and restart it. Exposing an MCP switch before watcher ownership is fixed would create mixed-room state.

## Safety invariants

- Never preserve a cursor across rooms.
- Never carry pending responsive rows or deduplication state across rooms.
- Never mutate `.env` to perform a live switch.
- Never commit target state before target session creation, room entry, and projection watermark retrieval succeed.
- Stop the old watcher as part of the synchronous commit.
- A failed target preparation must not end or alter the old live session.
- Status and runtime snapshots must show one coherent profile and room binding.
