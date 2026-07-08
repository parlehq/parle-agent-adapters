import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import {
  ParleAgentClient,
  isLiveRuntimeSnapshot,
  runtimeDirPath,
  runtimeFilePath,
} from "../dist/index.js";

const ENV = { PARLE_ROOM_ID: "room-1", PARLE_ROOM_AGENT_TOKEN: "opaque-token", PARLE_ROOM_HANDLE: "test-room" };

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function happyFetch(counters = {}) {
  return async (url, init) => {
    const u = String(url);
    if (u.endsWith("/v/agent/sessions")) {
      counters.sessions = (counters.sessions || 0) + 1;
      return json({ agent_session_id: "as-1", session_credential: "parle_ses_secret1", address: "@p.a.s1", expires_at: new Date(Date.now() + 3_600_000).toISOString() }, 201);
    }
    if (u.includes("/end")) {
      counters.ends = (counters.ends || 0) + 1;
      return json({});
    }
    if (u.endsWith("/participants")) return json({ participant_id: "part-1" }, 201);
    if (u.includes("/projection")) return json({ watermark: 7, messages: [] });
    return json({});
  };
}

function tempCwd() {
  return mkdtempSync(join(tmpdir(), "parle-runtime-"));
}

function snapshotFor(pid, overrides = {}) {
  return {
    schemaVersion: 1,
    pid,
    processStartedAt: new Date().toISOString(),
    state: "ready",
    sessionAddress: "@p.a.other",
    agentSessionId: "as-x",
    roomId: "room-1",
    updatedAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 3_600_000).toISOString(),
    adapter: { name: "test" },
    ...overrides,
  };
}

function deadPid() {
  const child = spawnSync(process.execPath, ["-e", ""], { encoding: "utf8" });
  return child.pid;
}

test("concurrent bootstrap callers converge on a single session mint", async () => {
  const counters = {};
  const client = new ParleAgentClient({ env: ENV, fetch: happyFetch(counters) });
  await Promise.all([client.connect(), client.connect(), client.ensureBootstrapped()]);
  assert.equal(counters.sessions, 1);
  assert.equal(client.runtime.bootstrapState, "ready");
  assert.equal(client.runtime.cursor, 7);
});

test("bootstrap failure records failed state with backoff and ensureReadySafe respects the window", async () => {
  let nowMs = Date.parse("2026-07-07T00:00:00Z");
  let attempts = 0;
  const client = new ParleAgentClient({
    env: ENV,
    now: () => new Date(nowMs),
    fetch: async () => {
      attempts += 1;
      return json({ error: { code: "boom", message: "server down" } }, 500);
    },
  });
  assert.equal(await client.ensureReadySafe(), true);
  assert.equal(attempts, 1);
  assert.equal(client.runtime.bootstrapState, "failed");
  assert.match(client.runtime.lastBootstrapError, /server down/);
  assert.equal(client.runtime.nextRetryAt, new Date(nowMs + 5000).toISOString());
  // Inside the backoff window: no attempt.
  assert.equal(await client.ensureReadySafe(), false);
  assert.equal(attempts, 1);
  // Past the window: retries, and backoff doubles.
  nowMs += 6000;
  assert.equal(await client.ensureReadySafe(), true);
  assert.equal(attempts, 2);
  assert.equal(client.runtime.nextRetryAt, new Date(nowMs + 10_000).toISOString());
  // Explicit user-paced calls always retry, even inside the window.
  await assert.rejects(() => client.connect());
  assert.equal(attempts, 3);
});

test("ensureReadySafe is a no-op without configuration or when already live", async () => {
  let fetched = 0;
  const unconfigured = new ParleAgentClient({ env: {}, fetch: async () => { fetched += 1; return json({}); } });
  assert.equal(await unconfigured.ensureReadySafe(), false);
  assert.equal(fetched, 0);
  const counters = {};
  const live = new ParleAgentClient({ env: ENV, fetch: happyFetch(counters) });
  assert.equal(await live.ensureReadySafe(), true);
  assert.equal(await live.ensureReadySafe(), false);
  assert.equal(counters.sessions, 1);
});

test("publishRuntime writes a credential-free 0600 snapshot and endSession removes it", async () => {
  const cwd = tempCwd();
  try {
    const counters = {};
    const client = new ParleAgentClient({ cwd, env: ENV, fetch: happyFetch(counters), publishRuntime: { adapterName: "@parlehq/mcp-server", adapterVersion: "0.4.0" } });
    await client.connect();
    const path = runtimeFilePath(cwd, process.pid);
    assert.ok(existsSync(path));
    const raw = readFileSync(path, "utf8");
    assert.doesNotMatch(raw, /parle_ses_/);
    assert.doesNotMatch(raw, /opaque-token/);
    const snapshot = JSON.parse(raw);
    assert.equal(snapshot.schemaVersion, 1);
    assert.equal(snapshot.state, "ready");
    assert.equal(snapshot.pid, process.pid);
    assert.equal(snapshot.sessionAddress, "@p.a.s1");
    assert.equal(snapshot.agentSessionId, "as-1");
    assert.equal(snapshot.roomHandle, "test-room");
    assert.equal(snapshot.adapter.name, "@parlehq/mcp-server");
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.equal(statSync(runtimeDirPath(cwd)).mode & 0o777, 0o700);
    await client.endSession();
    assert.equal(counters.ends, 1);
    assert.equal(existsSync(path), false);
    assert.equal(client.runtime.bootstrapped, false);
    assert.equal(client.runtime.bootstrapState, "unstarted");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("bootstrap failure publishes a failed snapshot readers reject", async () => {
  const cwd = tempCwd();
  try {
    const client = new ParleAgentClient({ cwd, env: ENV, fetch: async () => json({}, 500), publishRuntime: { adapterName: "test" } });
    await client.ensureReadySafe();
    const snapshot = JSON.parse(readFileSync(runtimeFilePath(cwd, process.pid), "utf8"));
    assert.equal(snapshot.state, "failed");
    assert.ok(snapshot.lastError);
    assert.equal(isLiveRuntimeSnapshot(snapshot, new Date()), false);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("construction prunes provably stale sibling files and keeps uncertain ones", () => {
  const cwd = tempCwd();
  try {
    const dir = runtimeDirPath(cwd);
    mkdirSync(dir, { recursive: true });
    const gone = deadPid();
    writeFileSync(join(dir, "expired.json"), JSON.stringify(snapshotFor(process.pid + 1, { expiresAt: new Date(Date.now() - 1000).toISOString() })));
    writeFileSync(join(dir, "dead.json"), JSON.stringify(snapshotFor(gone)));
    writeFileSync(join(dir, "uncertain.json"), JSON.stringify(snapshotFor(1)));
    writeFileSync(join(dir, ".tmp-ignored"), "not json");
    new ParleAgentClient({ cwd, env: ENV, publishRuntime: { adapterName: "test" } });
    assert.equal(existsSync(join(dir, "expired.json")), false);
    assert.equal(existsSync(join(dir, "dead.json")), false);
    assert.equal(existsSync(join(dir, "uncertain.json")), true);
    assert.equal(existsSync(join(dir, ".tmp-ignored")), true);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("isLiveRuntimeSnapshot gates on schema, state, expiry, and pid liveness", () => {
  const now = new Date();
  assert.equal(isLiveRuntimeSnapshot(snapshotFor(process.pid), now), true);
  assert.equal(isLiveRuntimeSnapshot(snapshotFor(process.pid, { state: "failed" }), now), false);
  assert.equal(isLiveRuntimeSnapshot(snapshotFor(process.pid, { schemaVersion: 2 }), now), false);
  assert.equal(isLiveRuntimeSnapshot(snapshotFor(process.pid, { expiresAt: new Date(now.getTime() + 1000).toISOString() }), now), false);
  assert.equal(isLiveRuntimeSnapshot(snapshotFor(process.pid, { expiresAt: "" }), now), false);
  assert.equal(isLiveRuntimeSnapshot(snapshotFor(deadPid()), now), false);
});

test("status exposes bootstrap state and keeps the session credential redacted", async () => {
  const client = new ParleAgentClient({ env: ENV, fetch: happyFetch() });
  await client.connect();
  const status = client.status();
  assert.equal(status.runtime.bootstrapState, "ready");
  assert.equal(status.runtime.sessionHandle, "<redacted>");
  assert.doesNotMatch(JSON.stringify(status), /parle_ses_/);
});
