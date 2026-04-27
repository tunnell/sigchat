# Testing sigchat

This document describes the testing methodology used in this project
and how to run all four test families. The methodology section is
not boilerplate — it's adapted from `xous-signal-client`'s
`tests/README.md` (PR #2 there), which distilled six principles from
the Phase A protocol-debugging arc. Sigchat shares the codebase
ancestry and the bug exposure: the principles apply directly here,
and one of the bugs (the v6 `DataMessage.timestamp` proto-tag
regression) is currently still present in this repo's send and
receive paths. See "Currently expected wire-byte audit failure"
below.

For the per-check verification discipline that gates every commit
(build, size, i686, Renode boot, reporting), see
[`TESTING-PLAN.md`](../TESTING-PLAN.md). This document is the
higher-level methodology that frames why the four families exist;
`TESTING-PLAN.md` is the operational checklist.

## Quick start

Run everything:

```
./tools/run-all-tests.sh
```

The orchestrator runs four test families: Rust unit/integration,
hosted-mode E2E send, hosted-mode E2E receive, and footprint
(static size + Renode boot smoke). Families whose prerequisites
aren't met (no `tools/.env`, no `signal-cli`, no `renode`) are
reported as **SKIPPED** rather than treated as failures. Exit code
reflects whether all families that COULD run actually passed.

Skip flags:

```
./tools/run-all-tests.sh --skip-e2e        # both send and recv
./tools/run-all-tests.sh --skip-send
./tools/run-all-tests.sh --skip-recv
./tools/run-all-tests.sh --skip-footprint
./tools/run-all-tests.sh --skip-renode
```

### From a fresh clone

1. Install the Rust toolchain xous-core uses. xous-core must be on
   `feat/05-curve25519-dalek-4.1.3` for path-dep compatibility (see
   `TESTING-PLAN.md` Pre-flight).
2. (Optional, for E2E) Install `signal-cli`. For send tests, link
   sigchat as a secondary device on a Signal account and capture a
   PDDB snapshot. For receive tests, also have a SECOND signal-cli
   account that can send to the linked account's username.
   Configure both via `tools/test-env.example`.
3. (Optional, for footprint) Install `riscv64-unknown-elf` binutils
   and `cargo-bloat`. For the Renode smoke, install Renode v1.16.1+.
4. `./tools/run-all-tests.sh`

## Testing methodology

Six principles, all grounded in real bugs from the Phase A
debugging arc that flowed across this codebase and into
`xous-signal-client`:

### 1. Mocks must simulate real-server behavior, not just wire format

The earliest send-path tests used a canned-response queue. The
shape was correct, the response codes were plausible, and 39 unit
tests passed. The first real send to `chat.signal.org` failed
immediately because Signal-Server's prekey-bundle responses are
unpadded base64 (Java's `Base64.getEncoder().withoutPadding()`),
and our `STANDARD.decode` rejected them. The mock had been
padded. A second bug — encrypting only for the original recipient
device on every retry, never picking up the missing device the 409
told us about — would have passed canned-response mocks forever.
The fix introduced `StatefulMockHttp` (see
`src/manager/send.rs::tests`): the mock tracks the registered
device set for an account UUID, and its 409 response is computed
dynamically from the symmetric difference between the registered
set and the device set in the request body.

**Rule for new tests in this repo:** prefer `StatefulMockHttp`
over canned-response mocks for any test that exercises retry,
reconnection, or device enumeration.

### 2. Self-consistent encoders pass tests by being bidirectionally wrong

The `DataMessage.timestamp` field on the wire is `tag = 7` per
canonical `SignalService.proto`. Tag 5 in that proto is
`expireTimer (uint32)` — a different field, a different type. The
hand-rolled prost definition in this codebase has `timestamp` at
tag 5, in both the send-side and the receive-side definitions:

- `src/manager/outgoing.rs:59` — `tag = "5"` for timestamp (send)
- `src/manager/main_ws.rs:129` — `tag = "5"` for timestamp (recv)

The 89 unit tests pass. The receive-path round-trip tests pass
because the project's own decoder also reads tag 5; sender and
receiver agree on a non-canonical wire format. iPhone Signal's
`EnvelopeContentValidator` rejects DataMessages without timestamp
at tag 7 and silently drops the message at content validation —
invisible from the sender's side. signal-cli (used in this
project's E2E loop) surfaces the rejection as
`Invalid content! [DataMessage] Missing timestamp!`, which is how
the bug was caught in the parallel `xous-signal-client` arc and
fixed there in commit `da08f2e`.

**Currently expected wire-byte audit failure:** until the proto-
tag bug is fixed in production code, `tools/decode-wire.sh` against
a real send capture will report
`DataMessage.timestamp (tag 7) absent` and exit 1. This is by
design: the wire-byte tool validates against canonical, not
against our own decoder, and so it surfaces a class of bug that
self-consistent unit tests cannot. The fix is one character in
two files (`tag = "5"` → `tag = "7"` in both the encoder and
decoder); intentionally out of scope for this testing-
infrastructure PR.

**Rule for new tests in this repo:** validate field tags against
the canonical protobuf schema, not against your own encoder's
output. The Rust round-trip tests in this PR are useful for
catching encoder/decoder *symmetry* regressions; the canonical
check lives in `tools/decode-wire.sh`.

### 3. The three-legged stool of verification

A `200 OK` from `PUT /v1/messages` proves the server accepted the
ciphertext. It does not prove anything was delivered, decrypted,
or rendered. Three sessions in the `xous-signal-client` Phase A
arc declared "send works" based on log lines reading
`INFO: post: sent to <recipient-uuid>`. None of those messages
reached a recipient phone.

The verification rule has three legs:

1. **Wire bytes** match the canonical Signal protobuf format —
   verified offline via `tools/decode-wire.sh` against a captured
   `XSCDEBUG_DUMP=1` trace.
2. **Recipient parse** succeeds at the protocol layer — verified
   by `signal-cli receive` showing `Body: <text>`.
3. **User-visible confirmation** — Signal app on a physical phone
   shows the message.

For sigchat:

- Send tests: `tools/scan-send.sh` covers leg 1 (wire dump) and
  prepares for leg 2 (signal-cli on the sigchat-linked account
  receives a `SyncMessage::Sent` for any send by sigchat). Leg 3
  is human.
- Receive tests: `tools/recv-verify.sh` covers leg 1 (the
  envelope decrypted and Content parsed without dropping) and
  leg 2 (the `[recv-debug]` line emitted by the
  `SIGCHAT_DEBUG_RECV=1` hook contains the marker body).

### 4. Stateful protocols need stateful test doubles

Signal's multi-device fan-out is a stateful protocol. A mock that
returns one canned 409 followed by 200 misses the
retry-and-re-enumerate logic. The session store changes between
attempts; the device list changes between attempts; the new list
must come from session enumeration on each iteration, not from a
captured value at the top of the loop. Several variants of the
single-device-retry bug existed in this codebase and slipped
through canned-response tests.

`StatefulMockHttp` (in `src/manager/send.rs::tests`) holds a
registered device set and a registered prekey-bundle response;
the 409 it returns reflects the actual diff against the registered
set, and a subsequent retry is checked against the same state.

### 5. Diagnostic instrumentation belongs in the codebase

Two diagnostic hooks are committed in this repo:

- `XSCDEBUG_DUMP=1` (`src/manager/outgoing.rs::xsc_dump`) — when
  set, writes labelled hex of the unpadded Content protobuf, the
  padded plaintext, and the per-device ciphertext to
  `/tmp/sigchat-wire-dump.txt`. Consumed by
  `tools/decode-wire.sh`. The runtime cost when not enabled is
  one environment variable check per send.
- `SIGCHAT_DEBUG_RECV=1` (`src/manager/main_ws.rs::deliver_data_message`
  and `deliver_sync_message`) — when set, emits a structured
  `[recv-debug] kind=... author=... ts=... body_len=... body=...`
  log line containing the message body. Consumed by
  `tools/recv-verify.sh`. **Bodies are NOT logged unless this env
  var is set**; production logs remain body-free by default.

**Rule:** if you find yourself writing-and-removing the same
audit instrumentation twice for protocol-correctness work, commit
it under an env-var gate. The cost of carrying it is one branch
per send/receive; the cost of reproducing it from scratch each
session is dramatically higher.

### 6. Real-server testing has costs that mock testing avoids

Hosted-mode E2E tests cannot run in CI without exposing account
credentials. They send real traffic on a real network, are subject
to rate limits, and require human verification of leg 3. They take
2–5 minutes per run vs. ~0.5s for the Rust family. For day-to-day
development, the Rust family catches most regressions; hosted
E2E is the gate before declaring a protocol change complete.

This project's split is:

- **Rust:** runs every commit, in CI, deterministically.
- **Send / Recv E2E:** run locally before opening a PR for any
  protocol-touching change. Not in CI.
- **Footprint:** runs in CI for static size; Renode boot smoke
  runs locally on an ad-hoc basis.

## Test families

### Family 1: Rust unit and integration tests

**Run:**
```
cargo test --features hosted
```

**Validates:** protocol-level logic against in-process mocks.
Includes the multi-device fan-out logic (`send.rs`), 409 / 410
retry handling, sealed-sender encryption wrapping (`outgoing.rs`),
ISO-7816 padding, the unpadded-base64 codec, the receive-side
`strip_signal_padding` round-trip and `is_timeout` classification
(`main_ws.rs`), AES-CTR encrypt determinism (`libsignal.rs::aes256_ctr_encrypt`),
and the small enum/state types (`trust_mode.rs`,
`group_permission.rs`, `link_state.rs`,
`account/service_environment.rs`, `manager/config.rs`).

**Does not validate:** real-server behavior, real cryptographic
round-trips against a different libsignal implementation, or the
UI. Per the methodology section, self-consistent encoder bugs and
mock/server divergences pass this family by design and require
Family 2/3.

**Where the tests live:** inline `#[cfg(test)] mod tests` blocks
at the bottom of each source file. The current inventory is 89
tests after this PR.

### Family 2: Hosted-mode E2E send

**Setup (one-time):**

1. Pick a Signal account you control. Link sigchat (running on the
   Precursor emulator in hosted mode) as a secondary device on
   that account, and capture a PDDB snapshot of the linked state.
2. Pick a separate recipient (a different account, or any contact
   that has Signal). Configure your default outgoing peer in
   sigchat's PDDB pointing at that recipient.
3. Copy the env template and fill in your values:
   ```
   cp tools/test-env.example tools/.env
   $EDITOR tools/.env
   ```

**Run:**
```
./tools/scan-send.sh                # sends "Test"
./tools/scan-send.sh "Hello world"  # custom text
```

The script restores the linked PDDB snapshot, boots Xous in
hosted mode, navigates the emulator UI, types the message,
presses Enter, and watches for `post: sent to ...` (success) or
`RetryExhausted` / `send failed`. Wire bytes are captured to
`/tmp/sigchat-wire-dump.txt` via `XSCDEBUG_DUMP=1`.

**Verify wire bytes (leg 1):**
```
./tools/decode-wire.sh
```
Reports the structure of each captured Content protobuf and runs
canonical-tag conformance checks: DataMessage at tag 1 (body) and
tag 7 (timestamp); SyncMessage.Sent at tag 2 (timestamp), tag 3
(inner DataMessage), tag 7 (destinationServiceId). Until the v6
proto-tag bug is fixed in production, this check is expected to
report `DataMessage.timestamp (tag 7) absent`.

**Verify recipient parse (leg 2):** since signal-cli is also
linked to the sigchat account, it sees the `SyncMessage::Sent`
that sigchat fans out to its own account devices. Run
`signal-cli -a $SIGCHAT_LINKED_NUMBER receive` after the scan and
look for `Body: <your test message>`.

**Verify on phone (leg 3):** open Signal on the recipient phone
and confirm.

### Family 3: Hosted-mode E2E receive

**Setup:** same as Family 2, plus a SECOND signal-cli account
(different phone number) that can send to the
`SIGCHAT_LINKED_USERNAME`. signal-cli's auto-detect picks the
sender if exactly one account is registered;
`tools/signal-send.sh` lets you override via `SIGNAL_SENDER`.

**Run:**
```
./tools/recv-verify.sh
```

The script:

1. Restores the linked PDDB snapshot, boots sigchat with
   `SIGCHAT_DEBUG_RECV=1`.
2. Waits for `main_ws: authenticated` in the scan log.
3. Calls `tools/signal-send.sh` with a unique
   `phase-r-recv-<timestamp>` marker. This script appends an
   ISO-timestamped prefix to the body and sends to the
   `PrecursorEmulator.02` username (the sigchat-linked account).
4. Watches the scan log for a `[recv-debug]` line that contains
   the marker substring. Match = leg 1 (envelope decrypted and
   Content parsed) AND leg 2 (body matches what was sent) in one
   step.

**Common failure modes:**

| Symptom | Likely cause |
|---|---|
| `[recv-debug]` line never appears | sigchat WS auth failed, or session state on Signal-Server doesn't match the PDDB snapshot — try signal-cli `--end-session` against the sender to reset |
| `[recv-debug]` line appears but body doesn't match | rare; check signal-send.sh log for the actual body sent and compare |
| `signal-send.sh` "FAILED rc=N" | signal-cli account flagged inactive; run `signal-cli -a $SIGNAL_SENDER receive` to drain pending and re-prove liveness, then retry |

### Family 4: Memory footprint

The Xous-target binary has a per-crate, per-section, and total
budget in `.size-budget.toml`. CI runs the full check on every PR
(`.github/workflows/size-budget.yml`).

**Run static measurement:**
```
./tools/measure-size.sh
```

Reports section + per-crate sizes vs hard limits. The TOTAL is
currently over the 1.5 MiB hard limit by design until size-
reduction work lands; per `.size-budget.toml::meta.note` and
`TESTING-PLAN.md` Check 2, a TOTAL-only breach is documented
expected state. `measure-size.sh` treats it as PASS-WITH-NOTE.
Per-section or per-crate breach = real failure (exit 1).

**Run Renode boot smoke (optional):**
```
./tools/measure-renode.sh
```

Builds a Xous image with sigchat, boots it under Renode v1.16.1+
for up to 90 seconds, and checks for absence of panic / abort /
exception and presence of `INFO:sigchat: my PID is N`. Detects
and SKIPs cleanly on the documented `LiteX_Timer_32.cs(23,62):
cannot convert from 'long' to 'ulong'` peripheral compile failure
(Renode 1.16.1 vs current xous-core; one-line upstream patch
candidate; see `tests/renode/README.md`).

The Renode PDDB-format ceremony (`tests/renode/pddb-format.robot`)
is a separate Robot Framework test invoked via `renode-test`; see
`tests/renode/README.md` for that workflow.

## Per-family pros and cons

| Family | Pros | Cons |
|---|---|---|
| Rust | Fast, deterministic, CI-able, covers protocol edge cases | Cannot catch mock/server divergence or self-consistent encoder bugs |
| Send E2E | Validates real-server behavior; catches encoder bugs Rust tests miss | Requires test accounts; sends real traffic; cannot run in CI |
| Recv E2E | Validates the receive path against real Signal traffic | Requires a second signal-cli account; rate-limit-aware |
| Footprint | Catches binary-bloat regressions before hardware testing; static size runs in CI | Static size doesn't capture runtime peak; full validation needs Renode |

## When to run which

- **Every commit (locally):** Family 1.
- **Before declaring a protocol change complete:** Family 2 + 3.
- **Before declaring a memory-affecting change complete:** Family 4.
- **Before opening a PR:** `./tools/run-all-tests.sh`.

## Adding new tests

- **Family 1 (Rust):** add `#[test]` in the appropriate source
  file's inline `mod tests`. Prefer `StatefulMockHttp` over
  canned-response mocks for any retry/reconnection/device-
  enumeration test.
- **Family 2 / 3 (E2E):** new scenarios become new helpers in
  `tools/test-helpers.sh` plus a new top-level driver. Anonymized
  configuration goes in `tools/test-env.example`; never commit
  real account values.
- **Family 4 (footprint):** new per-crate budgets are added to
  `.size-budget.toml`. The check script reads `[budget.crates.*]`
  and applies the listed `hard` ceiling. Caps should be
  `measured + 30% headroom` per `.size-budget.toml::meta.note`.

## Out-of-band tooling

`tools/signal-send.sh` (existing, pre-Phase-R) is the external
Signal traffic injector used by `recv-verify.sh`. It auto-detects
the sender account, prepends an ISO timestamp to the body, and
appends to `tools/signal-send.log`. Note: signal-cli accounts can
be flagged inactive by Signal-Server after a quiet period — run
`signal-cli -a <number> receive` periodically (cron or manually)
on whichever account drives the test traffic.

## See also

- [`../TESTING-PLAN.md`](../TESTING-PLAN.md) — operational
  per-check verification discipline (build, size, i686, Renode
  boot, report).
- [`renode/README.md`](renode/README.md) — Renode + Robot
  Framework test infrastructure (Antmicro pattern).
- [`../.size-budget.toml`](../.size-budget.toml) — current size
  budgets and growth policy.
- `../.github/workflows/size-budget.yml` — CI size check.
- The parallel
  [`xous-signal-client/tests/README.md`](https://github.com/tunnell/xous-signal-client/blob/main/tests/README.md)
  — the methodology section here is adapted from there. The bug-
  arc evidence applies to both repos because they share code
  ancestry.
