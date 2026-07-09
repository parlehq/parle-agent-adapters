import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(new URL("../package.json", import.meta.url)));
const script = resolve(root, "skills/parle/scripts/parle-watch.sh");

// The liveness check shells out to python3 and probes pids with kill(pid, 0);
// skip cleanly where the sandbox denies either.
const havePython = spawnSync("python3", ["-c", "import os; os.kill(os.getpid(), 0)"]).status === 0;

// PID-reuse hardening verifies process start times via /proc or ps etime;
// tests for it self-skip where neither is available (hardened sandboxes).
function canVerifyStart() {
  try {
    if (execFileSync("ps", ["-o", "etime=", "-p", String(process.pid)], { encoding: "utf8" }).trim()) return true;
  } catch {
    // fall through to /proc
  }
  return existsSync(`/proc/${process.pid}/stat`);
}
const haveStartVerify = canVerifyStart();

function stubServer(body) {
  return new Promise((resolveServer) => {
    const server = createServer((req, res) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
    });
    server.listen(0, "127.0.0.1", () => resolveServer(server));
  });
}

function writeSnapshot(cwd, agentSessionId, overrides = {}) {
  const dir = join(cwd, ".parle", "runtime");
  mkdirSync(dir, { recursive: true });
  const snapshot = {
    schemaVersion: 1,
    pid: process.pid,
    // The real start of this process, as the client writes it: a fabricated
    // "now" would trip the PID-reuse start-time check once the suite has run
    // longer than the tolerance. Snapshots for other pids (process.ppid)
    // override this with undefined so the unverifiable claim is omitted.
    processStartedAt: new Date(Date.now() - process.uptime() * 1000).toISOString(),
    state: "ready",
    sessionAddress: "@p.a.s1",
    agentSessionId,
    roomId: "room-1",
    updatedAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    adapter: { name: "test" },
    ...overrides,
  };
  writeFileSync(join(dir, `${snapshot.pid}.json`), JSON.stringify(snapshot));
}

function runWatch(cwd, apiBase, args, extraEnv = {}) {
  const child = spawn("sh", [script, ...args], {
    cwd,
    env: {
      ...process.env,
      PARLE_API_BASE: apiBase,
      PARLE_ROOM_ID: "room-1",
      PARLE_ROOM_AGENT_TOKEN: "parle_agt_test",
      ...extraEnv,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => (stdout += chunk));
  child.stderr.on("data", (chunk) => (stderr += chunk));
  const exited = new Promise((resolveExit) => child.on("exit", (code) => resolveExit(code)));
  return { child, exited, out: () => stdout, err: () => stderr };
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

async function assertStillWatching(watch) {
  await sleep(1200);
  assert.equal(watch.child.exitCode, null, `watch exited early: ${watch.err()}${watch.out()}`);
  watch.child.kill("SIGKILL");
  await watch.exited;
}

test("watch holds with a note when the watched session was never present (era gate)", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  writeSnapshot(cwd, "session-other");
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    await sleep(1200);
    assert.equal(watch.child.exitCode, null, `watch exited early: ${watch.err()}${watch.out()}`);
    assert.match(watch.err(), /has never appeared/);
    assert.match(watch.err(), /PARLE_WATCH_SESSION_LIVENESS=0/);
    assert.equal(watch.err().split("has never appeared").length, 2, "note must print exactly once");
    watch.child.kill("SIGKILL");
    await watch.exited;
  } finally {
    server.close();
  }
});

test("watch exits 3 when its session was present and then removed", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  writeSnapshot(cwd, "session-mine");
  writeSnapshot(cwd, "session-other", { pid: process.ppid, processStartedAt: undefined });
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    await sleep(400);
    rmSync(join(cwd, ".parle", "runtime", `${process.pid}.json`));
    const code = await watch.exited;
    assert.equal(code, 3);
    assert.match(watch.err(), /was live in this host's runtime snapshots and is now gone/);
    assert.match(watch.err(), /parle_connect/);
    assert.match(watch.err(), /remaining TTL/);
    assert.match(watch.err(), /parle-watch forensics: watched=session-mine verdict=DEAD/);
    assert.match(watch.err(), /mine=no/);
  } finally {
    server.close();
  }
});

test("an expired own-session snapshot exits 3 as scheduled expiry, era gate not required", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  // The snapshot itself proves the session is gone (past expiresAt), so the
  // watch exits affirmatively even though it never saw the session live.
  writeSnapshot(cwd, "session-mine", { expiresAt: new Date(Date.now() - 1000).toISOString(), pid: 99999999 });
  writeSnapshot(cwd, "session-other", { pid: process.ppid, processStartedAt: undefined });
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    const code = await watch.exited;
    assert.equal(code, 3);
    assert.match(watch.err(), /expected pre-expiry rollover/);
    assert.match(watch.err(), /parle-watch forensics: watched=session-mine verdict=MINE_EXPIRED/);
    assert.match(watch.err(), /mine=yes/);
  } finally {
    server.close();
  }
});

test("a dead writer pid on the own snapshot exits 3 even with no siblings", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  // Unexpired and ready, but the publishing process is gone: affirmative exit,
  // no sibling snapshot needed and no prior live observation required.
  writeSnapshot(cwd, "session-mine", { pid: 99999999 });
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    const code = await watch.exited;
    assert.equal(code, 3);
    assert.match(watch.err(), /no longer running/);
    assert.match(watch.err(), /verdict=MINE_PIDDEAD/);
  } finally {
    server.close();
  }
});

test("a recycled writer pid (start-time mismatch) exits 3 as pid-dead", { skip: (!havePython && "python3/kill unavailable") || (!haveStartVerify && "no /proc or ps for start-time verification") }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  // The pid answers kill(pid, 0) (it is this test process), but the snapshot
  // claims a writer that started long ago: a verifiable start-time mismatch
  // means the pid was recycled and the real writer is gone.
  writeSnapshot(cwd, "session-mine", { processStartedAt: new Date(Date.now() - 7 * 86_400_000).toISOString() });
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    const code = await watch.exited;
    assert.equal(code, 3);
    assert.match(watch.err(), /no longer running/);
    assert.match(watch.err(), /verdict=MINE_PIDDEAD/);
    assert.match(watch.err(), /startcheck=mismatched/);
  } finally {
    server.close();
  }
});

test("a non-ready own snapshot holds with a one-time note while the host retries", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  // Bootstrap retry in progress: own snapshot present but state != ready must
  // hold as inconclusive even while a live sibling would otherwise force DEAD.
  writeSnapshot(cwd, "session-mine", { state: "starting" });
  writeSnapshot(cwd, "session-other", { pid: process.ppid, processStartedAt: undefined });
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    await sleep(1200);
    assert.equal(watch.child.exitCode, null, `watch exited early: ${watch.err()}${watch.out()}`);
    assert.match(watch.err(), /not in the ready state/);
    assert.equal(watch.err().split("not in the ready state").length, 2, "note must print exactly once");
    watch.child.kill("SIGKILL");
    await watch.exited;
  } finally {
    server.close();
  }
});

test("watch survives one transient DEAD liveness cycle", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  writeSnapshot(cwd, "session-other");
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    await sleep(250);
    writeSnapshot(cwd, "session-mine");
    await assertStillWatching(watch);
  } finally {
    server.close();
  }
});

test("watch keeps holding while its session snapshot is live", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  writeSnapshot(cwd, "session-mine");
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    await assertStillWatching(runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]));
  } finally {
    server.close();
  }
});

test("watch keeps holding when no snapshots exist (indeterminate)", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    await assertStillWatching(runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]));
  } finally {
    server.close();
  }
});

test("PARLE_WATCH_SESSION_LIVENESS=0 disables the liveness exit", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  writeSnapshot(cwd, "session-other");
  const server = await stubServer({ messages: [], watermark: 1 });
  try {
    await assertStillWatching(runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"], { PARLE_WATCH_SESSION_LIVENESS: "0" }));
  } finally {
    server.close();
  }
});

test("watch still exits 0 on relevant activity with a live snapshot", { skip: !havePython && "python3/kill unavailable" }, async () => {
  const cwd = mkdtempSync(join(tmpdir(), "parle-watch-"));
  writeSnapshot(cwd, "session-mine");
  const server = await stubServer({
    messages: [{ seq: 2, author: { agent_session_id: "session-other" }, addressing: { kind: "unaddressed" } }],
    watermark: 2,
  });
  try {
    const watch = runWatch(cwd, `http://127.0.0.1:${server.address().port}`, ["1", "session-mine"]);
    const code = await watch.exited;
    assert.equal(code, 0);
    assert.match(watch.out(), /relevant activity/);
  } finally {
    server.close();
  }
});
