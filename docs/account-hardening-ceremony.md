# Human account hardening ceremony

`parle_harden_account` coordinates one bounded account-hardening transition without accepting a password, TOTP code, recovery code, session cookie, provisioning URI, or arbitrary path. It never starts the helper.

The person hardening the account must run `parle-hardening-secret` themselves in a separate controlling terminal. The orchestration tool never launches it. Before displaying the provisioning QR, disable terminal scrollback and terminal recording. Do not use `script`, asciinema, or a multiplexer. The helper rejects known recording environments as a best-effort safeguard, not a proof that recording is absent.

For the initial administrator ceremony, use a clean `parle-adapters` checkout at the reviewed commit. Run `pnpm install --frozen-lockfile` and `pnpm build` before the ceremony. In the separate terminal at the checkout root, invoke the helper with `pnpm exec parle-hardening-secret <command>`. Do not substitute an unpinned downloaded package or an agent-authored wrapper. Issue #521 owns a generally distributed early-adopter entrypoint.

## Procedure

1. Run `parle_harden_account` with `action: "status"`.
2. In the separate terminal, run `pnpm exec parle-hardening-secret password`. Select `set` or `change`; all password prompts have disabled echo.
3. Run `parle_harden_account` with `action: "prepare"`, `confirmMutation: true`, and a reason.
4. Run `parle_harden_account` with `action: "enroll_totp"`, explicit confirmation, then run `pnpm exec parle-hardening-secret show-provisioning-qr` and scan the displayed QR directly into the human authenticator.
5. Run `pnpm exec parle-hardening-secret totp-code`, then `parle_harden_account` with `action: "confirm_totp"` and explicit confirmation. The recovery batch is written only to the protected local sink. It is never returned through the harness.
6. Move the recovery batch to the operator's protected destination. In the separate terminal run `pnpm exec parle-hardening-secret ack-recovery-stored`, typing its literal confirmation.
7. Run `parle_harden_account` with `action: "finalize"` and explicit confirmation. This removes local secret copies and retains only a non-secret completion record.

The helper finds the active ceremony next to the resolved profile catalog, under `hardening/current/`. It accepts no secret in argv or environment, requires a TTY, and uses fixed owner-only files only. Do not edit or copy files from that directory.

## Recovery stops

Never automatically retry a password, enrollment, confirmation, or recovery-code regeneration mutation after a transport error or HTTP 5xx. Re-run `status` and take only the named next action.

- After an expired sudo grant while still unhardened, stage a fresh `bootstrap-proof` and use `refresh_sudo`. Do not repeat the password mutation.
- After an ambiguous enrollment, a later explicit `enroll_totp` supersedes the inaccessible pending secret. Any previously scanned pending QR is invalid.
- After an ambiguous confirmation, `recover_confirm` checks `whoami` first. If still unhardened, stage a fresh TOTP code and make one explicit confirmation. If hardened but recovery capture is missing, stage a fresh TOTP code and make one explicit recovery-code regeneration.
- Every recovery-code regeneration invalidates all prior batches, including a batch whose response was lost. Trust only the latest durably captured batch.

No production ceremony is implied by this guide. Each account mutation requires the affected person's fresh authorization.
