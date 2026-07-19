# Agent Token Recovery

## Status

Approved by round-table and adversarial design gates.

Implementation is blocked on the L0 prerequisites in this design.

## Problem

Parle core exposes human-session endpoints for principal-wide token inventory and exact token revocation:

- `GET /v/agent-tokens`
- `POST /v/agent-tokens/{agentTokenID}/revoke`

The Pi adapter can log in, persist a human session, and mint room-bound agent tokens, but it cannot list or revoke all server-side tokens. Generic `parle_request` intentionally cannot use human-session authority. A quota error therefore leads to a recovery dead end when a server token is absent from local profiles.

The shared client advertises a generic `human_session` auth option but does not implement it. Pi separately owns account transport, session storage, error parsing, and profile persistence. Adding two more Pi-local requests would deepen split brain.

## Objective

Provide complete, browser-free token recovery through typed Pi and local stdio MCP tools while keeping Parle HTTP, account OpenAPI, the error registry, and version-pinned conformance fixtures authoritative.

Adapters must not classify stale tokens, recommend a candidate, infer token lifecycle state, or repair malformed canonical responses. Local mechanical failures must be clearly namespaced and structurally identical across bridges.

## Layer boundaries

1. L0 owns account authorization, credential audience, token inventory, lifecycle, quotas, response completeness, canonical errors, and mutation semantics.
2. L1 owns fixed endpoint mechanics, exact-origin credential confinement, protected local stores, redaction, and namespaced local transport failures.
3. L2 owns tool registration, input schemas, explicit mutation confirmation, and host UX.
4. L3 wrappers own packaging only.
5. Generic request paths cannot obtain human-session authority.
6. Local profiles are never presented as server inventory.
7. Tool contracts are reviewed and pinned. Live OpenAPI never generates tools at runtime.

## Blocking L0 prerequisites

No adapter implementation begins until `parlehq/parle` and refreshed conformance artifacts agree on:

1. `token_quota_exceeded`. Current pinned artifacts conflict on HTTP 403 versus 409.
2. Canonical error envelopes for quota failure, invalid or expired human sessions, and uniform revoke 404.
3. Canonical token inventory pagination. `GET /v/agent-tokens` must accept pinned `status`, `cursor`, and bounded `limit` inputs and return server-authored continuation metadata. Default recovery use requests `status=active`. Ordering and cursor stability must be pinned. No adapter silently truncates or invents aggregation bounds.
4. Canonical revoke 204 and the rule that clients must not automatically retry when transport failure leaves the mutation outcome unknown.
5. Human-session credential audience. Core must define the exact origin a returned `__Host-parle_session` credential may be sent to and state that manual clients must not forward it across redirects.
6. Conformance fixtures for every account endpoint moved from Pi to L1: email login start and complete, room inventory, agent inventory, room creation, own-agent seat admission, room-token mint, principal token inventory, and token revoke. Fixtures must cover success, canonical errors, redirect rejection, missing login proof, malformed success bodies, and cookie extraction.
7. Authoritative mint idempotency. `POST /v/agents/{agentID}/tokens` must require an `Idempotency-Key` and guarantee that a byte-identical retry under the same principal, agent, key, and body creates at most one token. Core keeps two separate records: a bounded securely retained replay response that may include the original plaintext token, and a durable consumed-key tombstone. Replay-response expiry may remove plaintext recovery, but the tombstone remains at least as long as the minted token can exist and permanently prevents that scoped key from minting another token. A replay after plaintext expiry returns a canonical recovery response containing the committed `agent_token_id` and an instruction to revoke before minting under a new key. Conflicting body reuse returns canonical `idempotency_conflict`. Core must pin key scope, tombstone lifetime, replay lifetime, in-progress duplicate behavior, secure response retention, post-commit response loss, malformed committed responses, and token-revocation interaction. The adapter never invents these semantics.
8. Stable principal binding. Returning login completion must return the authenticated principal's stable non-secret `principal_id`. The protected session record and every mint recovery journal bind to that ID. Core must pin its stability and disclosure classification.
9. Revocation recovery evidence. Add human-session `GET /v/agent-tokens/{agentTokenID}` for an exact token owned by the principal. It returns current metadata, including non-null `revoked_at`, and retains a minimal non-secret tombstone for at least the principal account lifetime. This exact lookup is not part of paginated inventory cardinality. Uniform revoke 404 remains insufficient proof. Core pins authorization, retention, and no-oracle behavior.

The adapter pin refresh is the explicit act of adopting these contracts.

## Tool surface

### `parle_list_agent_tokens`

Read-only inputs mirror the canonical pagination contract:

- `status`: optional canonical enum, default `active`
- `cursor`: optional opaque server cursor
- `limit`: optional value inside the server-pinned bound

Calls fixed `GET /v/agent-tokens` through L1 and returns one canonical server page plus unchanged continuation metadata after shared redaction. Agents page explicitly until the server returns no continuation. The tool never claims one page is complete, aggregates under a local bound, or rewrites cursors.

It does not label tokens stale, rank candidates, correlate profiles, or interpret `last_used_at`. The description repeats only canonical server text.

### `parle_revoke_agent_token`

Inputs:

- `agentTokenId`: required non-zero UUID
- `confirmMutation`: required `true`
- `reason`: required non-empty local rationale

Calls fixed `POST /v/agent-tokens/{agentTokenID}/revoke` with retries disabled. On canonical 204 it returns only:

```json
{
  "agent_token_id": "<requested UUID>",
  "http_status": 204
}
```

It does not mutate profiles, rotate credentials, switch runtime profiles, or claim sessions ended. The rationale is checked at L2 and never transmitted, persisted, or logged.

### `parle_login`

Expose the existing named tool in both Pi and local stdio MCP, but tighten its action semantics:

- `start`: requests a returning-login email code. No mutation confirmation is required.
- `complete`: exchanges the code and atomically persists only the protected human session. It never mints an agent token.
- `mint-from-session`: selects room and agent, mints a room-bound token with a caller-supplied or generated `idempotencyKey`, and persists a profile. It requires `confirmMutation: true` and a non-empty `reason` in both Pi and MCP. It never retries automatically. An explicit recovery call must reuse the returned key with byte-identical selectors.

This is an intentional breaking correction to existing Pi behavior, where `complete` can continue into minting when selection is implicit. Tool annotations are descriptive only and never substitute for the explicit mint confirmation gate.

## L1 account client

Add a headless `ParleAccountClient` or equivalent cohesive module to `@parlehq/agent-client`.

### Fixed methods

- start returning email login
- complete returning email login
- list owned rooms and agents
- create an owned room
- add an owned agent seat
- mint a room-bound agent token
- list paginated principal agent tokens
- read exact principal token status for recovery
- revoke an exact agent token

A private `accountRequest` primitive backs these methods. No public method accepts a cookie, arbitrary path, arbitrary method, arbitrary headers, or redirect policy.

Remove the unimplemented `human_session` member from exported generic `RequestOptions`. The client package is currently private and pre-1.0. This is still an explicit API-surface break requiring a package version, changelog entry, type-surface test update, and repository-wide consumer scan. If publication occurs first, use the applicable public semver policy before removal.

### Atomic Pi migration

All Pi account HTTP moves to L1 in the same release. Delete Pi-local `humanJson` and direct account fetches. Pi may retain orchestration and rendering, but no second account transport or error parser remains.

The recovery tools do not ship while dual transports exist.

## Exact-origin human-session store

### Stored record

The protected session file beside the profile catalog becomes a versioned JSON record:

```json
{
  "version": 1,
  "origin": "https://api.parle.sh",
  "principal_id": "<stable principal UUID>",
  "cookie": "__Host-parle_session=parle_sess_<43 base64url characters>"
}
```

The token grammar comes from the pinned L0 `human_session_cookie` token class. The file is capped at 1024 bytes before parsing. Unknown keys, duplicate keys, non-canonical origin spelling, extra content, and invalid token shape fail closed.

Legacy one-line files are accepted only for read-only inventory when the configured account origin is exactly `https://api.parle.sh`. Mint and journal recovery require a versioned record with `principal_id`. The next successful login rewrites the record. Legacy files for any other origin are rejected and require login again.

### Origin confinement

- Login completion records the exact normalized origin that returned the cookie.
- Every account call compares the stored origin with the configured account origin before reading cookie material into a request.
- Account requests use fixed relative paths resolved against that exact origin.
- Only HTTPS origins accepted by the reviewed account-origin policy are allowed.
- Fetch uses manual redirect handling. Any 3xx response fails closed before another request and the cookie is never forwarded.
- The Cookie header is attached only after exact origin equality and immediately before the fixed request dispatch.
- Response final URL, where exposed, must retain the same origin.

The account-origin policy is narrower than the generic agent request safe-host policy. A wildcard `*.parle.sh` decision is not sufficient for human cookies.

### POSIX file safety

- parent directory is real, current-user owned, and mode 0700
- session path and profile path are regular files and never symlinks
- reads use no-follow behavior where available, then validate the opened descriptor
- file owner equals the current user and group or other mode bits are zero
- both session-record and profile-catalog writes use one protected-store writer primitive
- the writer acquires a store-specific lock through atomic exclusive creation; the lock is never automatically superseded or removed by another process
- session temporaries can contain human cookies and profile temporaries can contain plaintext agent tokens; both are random mode-0600 files created with exclusive and no-follow flags
- the writer syncs the temporary file, atomically replaces the target while it still owns the unchanged lock, then opens and syncs the parent directory before reporting the transition durable
- journal creation, every journal transition, profile replacement, session replacement, and terminal journal removal use file sync plus parent-directory sync; unsupported filesystems fail closed for account mutation
- caught failures close and unlink every temporary in `finally`; normal completion removes the lock in `finally`
- a process crash can leave a protected temporary and lock indefinitely
- any later account operation that finds crash residue fails closed with `parle_adapter_store_recovery_required`; it does not infer liveness, remove a lock, scavenge a temporary, or write the store
- operator recovery requires verifying that the prior adapter process is gone, inspecting only adapter-owned filenames in the protected directory, then removing the residual lock and temporary through documented local recovery steps
- automatic stale-lock recovery is a separate design. PID existence, PID age, and PID reuse never grant cleanup or commit authority in this release
- an existing symlink target is rejected

### Windows posture

Human-session account tools are unsupported on Windows in this release. They fail closed before credential access. Agent-token data-plane tools remain available. Windows account support requires a separate reviewed credential-store design.

### Credential lease and cross-process consistency

Each top-level account tool obtains one immutable in-memory session lease after validating the file. The lease contains the exact origin and cookie snapshot but is never publicly exposed.

Every network call in that tool invocation uses the same lease. A cross-process session-file replacement affects only the next top-level invocation, never the active login, selection, mint, or persistence workflow.

The credential secret exists in the protected session record, transient protected temporary files during atomic replacement, and ordinary JavaScript or transport memory needed for the active call. L1 deliberately retains no public reference after the top-level call settles, but JavaScript cannot guarantee physical heap erasure or exclusion from privileged process-memory dumps.

One 120-second active-work deadline begins before lock acquisition for every top-level account-tool invocation. It covers lock acquisition, inventory selection, requests, bounded body reads, and persistence. Individual HTTP attempts are capped at 30 seconds and cannot extend active work. Caller cancellation can shorten but never extend it.

L1 checks the deadline before starting every network, bounded read, lock, journal transition, and persistence phase. A synchronous filesystem operation that began before expiry may finish after it; the design does not claim preemption. Once expiry is observed, L1 starts no new mutation phase, aborts outstanding fetches, drops reachable lease references, and enters `finally` cleanup. Cleanup is local and synchronous but is not claimed to complete inside the expired budget. These are local resource controls, not server semantic promises.

The adapter never deliberately copies the secret to public config, tool output, argv, child environment, application logs, adapter-authored runtime snapshot fields, or wrapper config. Security claims do not extend to privileged OS memory inspection, debugger heap snapshots, transport internals, or the protected temporary files described above.

Login completion is a single exchange followed by atomic session replacement. `mint-from-session` acquires the shared L1 profile-store lock, records the catalog digest, performs selection and mint with one session lease, verifies the digest before commit, writes the profile atomically, then releases the lock. Lock acquisition is bounded. A residual lock is never removed automatically.

Every adapter-owned profile-catalog writer, including login bootstrap, mint persistence, replacement, and future rotation helpers, MUST use the same L1 lock and digest protocol. No bridge may write the catalog directly. This guarantees serialization among adapter processes. Manual or third-party writers are outside that guarantee; the final digest check detects races before commit when observable, but the design does not claim filesystem compare-and-swap against nonparticipating writers.

## Principal-bound mint journal and deterministic reconciliation

Before mint dispatch, L1 validates the profile sink, acquires the non-supersedable lock, prepares the protected temporary destination, records the catalog digest, and selects one idempotency key.

Whether caller-supplied or generated, L1 atomically writes a non-secret journal before dispatch. The journal contains:

- schema version
- authenticated `principal_id` from the session record
- idempotency key
- fixed operation ID
- agent ID, room ID, and profile label
- canonical request-body hash
- created time
- monotonic integer `revision`
- state and state-specific non-secret evidence

It never contains the human cookie or plaintext agent token. Recovery refuses to use a lease whose `principal_id` differs from the journal. Dispatch cannot begin until state `prepared` is durable.

Every journal transition uses a journal-specific non-supersedable lock and compare-and-transition protocol: read the current durable record, require the expected state and revision, write revision plus one atomically, sync the file and parent directory, then release. A concurrent or stale transition fails and restarts reconciliation from the newest state. State regression is forbidden.

Journal states and idempotent transitions:

1. `prepared`: no trusted mint response is recorded. Recovery replays the byte-identical mint with the same key.
2. `minted`: a canonical complete response was received. The journal stores `agent_token_id` before profile replacement.
3. `profile_committed`: the profile catalog durably contains the same profile label, `agent_token_id`, and new local `mint_idempotency_key` field. This evidence is written in the same atomic profile replacement.
4. `cleanup_required`: core reports a committed token without recoverable plaintext, or profile persistence failed. The journal stores `agent_token_id`.
5. `revoked`: principal token inventory shows that exact token row with non-null `revoked_at`.
6. `resolved`: terminal local state. The journal can be removed idempotently.

All adapter-owned profile writers understand and preserve the optional `mint_idempotency_key` field. The profile parser's allowlist and conformance tests update in the same release.

Deterministic startup and pre-mint reconciliation:

Startup and ordinary pre-mint checks never replay a mutation. They report the unresolved journal and require an explicitly confirmed recovery call with the recorded key and byte-identical selectors.

During that explicit recovery call:

- `prepared`: replay core idempotency under the same principal and exact request hash. A canonical committed-without-secret response transitions directly and durably from `prepared` to `cleanup_required` with `agent_token_id`
- `minted`: if the profile already matches token ID and key, first execute a fresh successful parent-directory sync, then advance to `profile_committed`; matching visible contents without a successful barrier remain `minted`. Otherwise finish profile persistence while replay plaintext is available, or advance to `cleanup_required`
- `profile_committed`: advance to `resolved` without revoke, even if the prior process crashed before journal update
- `cleanup_required`: block new mint for that profile until exact token cleanup is proven
- `revoked`: advance to `resolved`
- `resolved`: remove the journal

Canonical `parle_revoke_agent_token` success compare-and-transitions matching journals to `revoked`. If a crash occurs after server revoke but before that transition, explicit reconciliation calls fixed exact-token status, requires the same `agent_token_id` and non-null `revoked_at`, then advances. Uniform revoke 404 alone never proves cleanup.

Mint never retries automatically. Recovery is a new explicitly confirmed call using the same key and byte-identical journal-bound request. If a response is lost or malformed, the journal remains `prepared` and the canonical idempotency contract is the only mutation authority.

If profile persistence reports failure after a complete mint response, L1 keeps the profile lock and re-reads the catalog, then executes a fresh parent-directory durability barrier. Matching profile contents prove visibility only. L1 transitions to `profile_committed` only when profile label, `agent_token_id`, and `mint_idempotency_key` match and the fresh directory sync succeeds. If contents do not match, it transitions from durable `minted` to `cleanup_required`. If contents match but the durability barrier fails, the journal remains `minted`, the profile lock is released through normal cleanup, and recovery fails closed for a later explicitly confirmed reconciliation. Plaintext token material is redacted from errors and released from reachable workflow state. L1 never automatically revokes.

## Response and error handling

### Canonical server errors

A non-success response is canonical only when it validates against the pinned error-envelope contract. L1 preserves its redacted snake-case `error` object unchanged.

A malformed, unknown, or non-JSON error body is never presented as canonical and is never returned raw. L1 emits `parle_adapter_server_contract_mismatch` with only `operation` and `http_status`. The body is discarded after bounded reading and redaction checks. For mint, any malformed post-dispatch response uses `parle_adapter_mint_outcome_unknown` so the canonical idempotency key remains available for recovery.

### Success responses

Every fixed method validates its pinned success shape. A mismatch emits `parle_adapter_success_contract_mismatch` with `operation` and `http_status`. Revoke 204 bypasses JSON parsing.

### Transport failures

Revoke never retries automatically. Any exception after dispatch begins and before an HTTP response emits:

```json
{
  "adapter_error": {
    "code": "parle_adapter_mutation_outcome_unknown",
    "operation": "revoke_own_agent_token",
    "message": "No server response was received. Inspect token inventory before deciding whether to retry.",
    "outcome": "unknown",
    "request_may_have_reached_server": true,
    "retry_attempted": false,
    "agent_token_id": "<requested UUID>"
  }
}
```

Non-mutation transport errors remain namespaced adapter errors and do not invent canonical retryability.

### Local error registry

L1 owns one registry and serializer for:

- invalid input
- unsupported platform
- missing, unsafe, invalid, or origin-mismatched credential store
- safe-origin rejection
- redirect rejection
- login proof missing
- canonical error contract mismatch
- success contract mismatch
- transport failure
- operation aborted
- revoke mutation outcome unknown
- mint outcome unknown with canonical idempotency key
- profile conflict or unsafe profile store
- profile lock conflict or crash-residue recovery requirement
- unresolved, revision-conflicted, or principal-mismatched mint recovery journal
- persistence failure after mint

Every entry defines a stable code, operation, message template, required fields, and constrained reason enum. Paths are never returned. Credential locations use fixed labels such as `resolved_session_file` and `resolved_profile_catalog`.

Pi and MCP return structurally equal objects from the shared serializer. JSON byte order is not a contract.

## Bridge behavior

Pi and MCP register account tools statically. Each invocation either creates a login lease or resolves the protected session lease.

### Pi

- migrate every account action to L1
- add list and revoke
- require explicit mint confirmation
- name `parle_login` in reauthorization guidance

### MCP

- add `parle_login`, list, and revoke over L1
- require the same mint confirmation
- use conservative mutation annotations for the action-based login tool

### Wrappers

Claude Code, Command Code, and Claude Desktop receive the tools only through the rebuilt MCP artifact. They add no protocol rules or credential logic.

## Contract and release gates

Strengthen the MCP tool lock to capture canonicalized full input schemas, required fields, constraints, titles, and annotations.

Required release work:

- version and changelog `@parlehq/agent-client`
- version and changelog `@parlehq/pi-extension`
- version and changelog `@parlehq/mcp-server`
- explicit breaking-change note for login completion and generic request type cleanup
- repository-wide consumer scan for `RequestOptions.human_session` and login completion assumptions
- version and changelog each wrapper whose copied artifact changes
- rebuild and byte-check Claude Code plugin, Command Code, and Claude Desktop artifacts

## Validation

### L0 and conformance

- resolve quota status and envelope conflicts
- pin exact session origin and redirect rules
- pin every migrated account endpoint, success shape, canonical error, cookie extraction, redirect rejection, and malformed response
- pin paginated inventory ordering, status filters, cursor stability, and bounds
- pin exact-token recovery status and account-lifetime tombstone retention

### L1

- exact-origin mismatch and redirect leak tests
- versioned record, safe legacy production migration, size, token grammar, permissions, ownership, symlink, descriptor race, and atomic replacement tests for both session and profile stores
- one immutable lease per top-level workflow with finite request and workflow deadlines
- the 120-second active-work deadline covers locks, requests, reads, and persistence
- 30-second request attempts cannot extend active work
- deadline is checked before each phase; already-started synchronous filesystem work may finish, while no new phase begins after expiry is observed
- deadline and cancellation stop new network dispatch, release reachable references, then enter best-effort synchronous cleanup
- caught failures clean both session and profile temporaries and locks
- crash residue is never automatically scavenged or superseded and later writes fail closed pending documented operator recovery
- tests and docs avoid impossible heap-erasure or privileged-snapshot claims
- cross-process replacement cannot alter an active workflow
- every adapter-owned profile writer uses the same non-supersedable lock and digest protocol
- manual nonparticipating writer limitations are documented and not overstated
- explicit mint confirmation is required before dispatch
- every mint key, caller-supplied or generated, is durably journaled before dispatch and survives process crash
- unresolved journals block accidental mint under a new key for the same profile
- mint sends one canonical idempotency key and never retries automatically
- L0 tombstones prevent key reuse from minting again after plaintext replay expiry
- explicit recovery reuses the key with a byte-identical journal-verified request and cannot create a second token
- post-dispatch response loss and malformed committed mint recover only through the canonical idempotency contract
- a reported profile replacement failure requires matching contents plus a fresh successful parent-directory sync before `profile_committed`; matching contents with failed sync remain `minted`
- post-mint persistence failure returns the exact non-secret cleanup ID and idempotency key with no plaintext token
- file and parent-directory sync are required for every durable state and removal
- malformed server bodies are discarded and mapped to contract mismatch
- revoke 204 bypasses JSON parsing and retries stay disabled
- local errors are structurally equal across bridges
- no absolute path appears in tool output

### Pi and MCP

- all Pi account requests route through L1
- Pi-local account transport is absent
- login complete never mints
- mint requires confirmation and rationale in both bridges
- static registration works before login
- MCP login independently provisions the protected record
- full schemas and annotations match the strengthened lock

### Artifacts and live smoke

- build, typecheck, tests, package validation, secret scans, consumer scan, and all wrapper byte checks pass
- disposable smoke logs in, creates three tokens, pages through active inventory, revokes one, and exercises every journal crash boundary: before dispatch, after mint before `minted`, after `minted`, after profile replacement before `profile_committed`, after server revoke before `revoked`, during concurrent stale journal transitions, after rename before parent-directory sync, and before journal removal. It verifies principal mismatch rejection, idempotent replay without duplication, replay expiry with consumed-key tombstone, fail-closed crash residue and operator recovery, then cleans every token, session, journal, temporary, lock, and resource

## Rollout

1. Resolve all L0 contracts, including pagination, exact-token status, and mint idempotency, then refresh conformance.
2. Add principal-bound exact-origin session records, finite leases, the journal state machine, the local error registry, non-supersedable protected-store writers, and fixed account methods to L1.
3. Atomically migrate Pi account transport and change login completion semantics.
4. Add Pi recovery tools.
5. Strengthen the MCP lock and add MCP login and recovery tools.
6. Version packages and wrappers, update changelogs, rebuild artifacts, and run all gates.
7. Run cleanup-safe disposable smoke.

## Non-goals

- stale-token classification or automatic quota cleanup
- automatic revoke or mutation retry
- profile mutation as a revoke side effect
- runtime profile switching
- generic human-session requests
- runtime OpenAPI tool generation
- Windows human-session support
- pagination without renewed design review

## Acceptance criteria

- Pi and local stdio MCP can establish an exact-origin protected human session, page through canonical server inventory, and revoke an explicitly selected token without raw cookie handling.
- Minting is always an explicitly confirmed action.
- One L1 implementation backs every account call.
- L0 remains the only authority for token state, pagination, exact recovery status, quotas, lifecycle, credential audience, and canonical errors.
- Malformed server responses never masquerade as canonical.
- Active workflows cannot change principals through local credential replacement, and journal recovery requires the same stable principal ID.
- Every journal crash boundary, including committed-without-secret, profile commit, concurrent state updates, and revoke before journal transition, reconciles deterministically through revisioned local evidence and retained exact server token state without duplicate minting or adapter inference.
- Local profiles remain separate and untouched by revoke.
- Generic request paths cannot obtain human authority.
- Credential exposure is limited and stated precisely: protected records, possible crash-residual mode-0600 temporary files, and active process or transport memory are acknowledged; public outputs, argv, child environments, application logs, adapter-authored runtime fields, and wrapper config remain secret-free.
- Conformance, contract lock, versions, changelogs, consumer scan, builds, tests, byte checks, secret scans, and disposable cleanup pass.
