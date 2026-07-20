# @parlehq/command-code-adapter

Command Code packaging for Parle.

This package is a thin Type 2 MCP host wrapper. It bundles the shared `@parlehq/mcp-server` artifact and installs a Command Code-native Parle skill. It does not define protocol behavior or read credentials itself.

## Install for the current user

From a clone of this repository:

```bash
pnpm -F @parlehq/command-code-adapter install:user
```

The installer:

- copies the self-contained MCP artifact to `~/.local/share/parle/command-code/parle-mcp.js`
- copies the skill to `~/.commandcode/skills/parle/SKILL.md`
- registers the `parle` stdio server in Command Code user scope through `cmd mcp add`
- injects no token or profile value into Command Code configuration
- refuses to replace a different existing `parle` MCP entry or skill

If MCP registration fails after the copies complete, rerunning the installer is safe. It will reuse identical files and retry registration. A different existing skill or MCP entry remains a fail-closed manual decision.

The MCP server resolves `~/.parle/profiles` directly. If the catalog has a `[default]` profile, no additional environment configuration is needed. Otherwise launch Command Code with `PARLE_PROFILE` naming the intended profile.

Restart Command Code after installation, then verify with `/mcp` or:

```bash
cmd mcp get parle
```

A normal prompt can then be concise:

> We use ai.parle.sh. Connect to our room and acknowledge `@principal.agent.session` when complete.

Command Code should discover the Parle skill and native MCP tools, call `parle_connect`, then send the acknowledgement with structured direct addressing. It should not inspect the profile catalog or construct HTTP requests in shell commands.

## Validated host behavior

Validated on 2026-07-18 with Command Code 0.19.1:

- interactive Command Code loaded the user-scoped server and listed the bundled MCP tools
- the original natural-language setup prompt discovered the skill, called `parle_connect`, sent the direct acknowledgement, and completed without shell or credential-file access
- `cmd -p` headless mode did not inject configured MCP tools in this version, even though the interactive host did; use an interactive session for Parle until Command Code fixes or documents headless MCP loading

Command Code launches `node` through the session's `PATH`. A project-level runtime shim can therefore prevent the server from starting if that project has not trusted its runtime configuration. Use `/mcp` to inspect the error and repair the project runtime trust rather than placing credentials in another config path.

## Account hardening

`parle_harden_account` accepts no secret or arbitrary path and never launches the helper. The human must run `parle-hardening-secret` themselves in a separate controlling terminal with scrollback and recording disabled before any provisioning QR display. Follow the [operator ceremony](../../docs/account-hardening-ceremony.md).

## Build and test

```bash
pnpm -F @parlehq/mcp-server build
pnpm -F @parlehq/command-code-adapter build
pnpm -F @parlehq/command-code-adapter test
```

The copied MCP artifact is tracked and byte-checked against the shared server build.

## Uninstall

Remove the user-scoped MCP entry and skill:

```bash
cmd mcp remove -s user parle
rm -rf ~/.commandcode/skills/parle
rm -rf ~/.local/share/parle/command-code
```
