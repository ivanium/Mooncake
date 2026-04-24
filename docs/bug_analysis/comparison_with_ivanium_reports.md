# Cross-reference: these fixes vs. the existing bug-class reports

This branch adds four patches that make Mooncake usable at large-scale
DEP (8-node × DP=32 × EP=32). The patches are described in
[`8n_bigep_external_cache_rca.md`](./8n_bigep_external_cache_rca.md).
This document maps each patch onto the three bug-class reports in
[`ivanium/vllm @ feat/mooncake-store-int-Ao`](https://github.com/ivanium/vllm/tree/feat/mooncake-store-int-Ao/sprint_dist_kv_results/bug_analysis):

- [`bug_class_metadata_not_found_cn.md`](https://github.com/ivanium/vllm/blob/feat/mooncake-store-int-Ao/sprint_dist_kv_results/bug_analysis/bug_class_metadata_not_found_cn.md) — Layer 2 (segment)
- [`bug_class_rdma_handshake_timeout_cn.md`](https://github.com/ivanium/vllm/blob/feat/mooncake-store-int-Ao/sprint_dist_kv_results/bug_analysis/bug_class_rdma_handshake_timeout_cn.md) — Layer 1 (RDMA QP)
- [`bug_class_batch_put_transfer_fail_cn.md`](https://github.com/ivanium/vllm/blob/feat/mooncake-store-int-Ao/sprint_dist_kv_results/bug_analysis/bug_class_batch_put_transfer_fail_cn.md) — Layer 3 (object)

---

## Our tree vs. the reports' tree

The reports are written against Mooncake HEAD **`be75ca0`** (2026-04-18,
`client_service: quorum write on WaitForTransfers + richer failure
logging`). Our base is **`71b6212`**, which does **not** include
`be75ca0`. Other 2026-Q1 family-2 PRs that the reports assume:

| Upstream PR | Description | In our base? |
|---|---|---|
| #398 | software-based 60 s transfer timeout | ✅ `22f17c0` |
| #993 | `put_start_discard_timeout_sec` + `client_id` tracking | ✅ `6d05c93` |
| #1560 | bootstrap RPC re-entrancy deadlock | ✅ `58b933c` |
| #1705 | avoid resetting RDMA endpoint on duplicate concurrent bootstrap | ✅ `692ccda` |
| #1733 | simultaneous-open handshake fix | ✅ `4b3d44f` |
| #1803 | duplicate notify recv WR / PLOG misuse | ✅ `a85800b` |
| #1762 | handshake deadlock | ❓ title grep did not match |
| **`be75ca0`** | **quorum write on `WaitForTransfers`** | ❌ **missing** |

Our `WaitForTransfers` therefore still uses
`all_transfers_succeeded` (all-or-nothing) semantics — the report's
§3.9.b bug is still latent in this tree. Fix D on our branch is a
deadline cap, not a quorum rewrite; cherry-picking `be75ca0` on top of
our branch is a logical follow-up.

---

## Mapping our fixes to the reports

### Fix A (multi-threaded handshake listener) — closes an item the reports flag as missing
- **Report:** `rdma_handshake_timeout_cn.md` §7.2 **#10** — "握手 RPC
  listener 改多线程 (场景 A 机制 ②)", status *"需本地改 / 向上游提"*.
- At 32-peer × 4-engine scale (~1000 pair-wise handshakes within
  ~50 ms of the first transfer), the old single-threaded "accept →
  callback → wait-for-client-half-close" loop stalls. That produces
  the report's §2.1 signatures (`packet mismatch`, `unexpected
  handshake message type`, `malformed json format`). Our listener
  rewrite keeps the accept loop moving by detaching per-connection
  workers.

### Fix B (handshake RPC retry + backoff) — closes another item the reports flag as missing
- **Report:** `rdma_handshake_timeout_cn.md` §7.2 **#9** — "握手链路
  RPC 级 retry + backoff (场景 A 机制 ④)", same status.
- Absorbs transient `ECONNREFUSED` during peer startup and short-read
  / protocol-desync glitches. Combined with Fix C, a single transient
  RPC failure no longer becomes a permanently dead endpoint.

### Fix C (no mark-inactive on single handshake failure) — different direction from the reports' proposal
- **Reports:** `rdma_handshake_timeout_cn.md` §3.8 and §7.2 **#5**
  propose the **opposite direction** — "Fail-fast on inactive
  endpoint" (check `active()` before submit and return immediately).
  Their concern is "scenario B" (peer genuinely dead): once marked
  inactive, the 60 s × N wait in `WaitForTransfers` wastes the whole
  benchmark window.
- **Our concern is scenario A** (peer fine, one handshake racing at
  startup): marking inactive on a single transient failure is too
  aggressive and cascades (a context is also marked inactive after
  32 failed polls). So we removed the marking rather than adding
  fail-fast.
- These two approaches are complementary, not mutually exclusive: the
  ideal long-term solution is Fix C here **plus** the reports' Fix #5
  wired to a proper health-check signal so that a genuinely dead peer
  still short-circuits quickly. Fix D (below) mitigates the worst case
  until then.

### Fix D (`WaitForTransfers` batch-level deadline) — weaker symptom-level version of a reported long-term TODO
- **Report:** `batch_put_transfer_fail_cn.md` §3.3 identifies the
  60 s × N accumulation as a primary amplifier of the object-layer
  bugs. §8.3 long-term action 2 is **"WaitForTransfers 改为并行等待
  + quorum early-return + cancel"** — i.e. the `be75ca0` quorum
  rewrite plus a follow-on cancel of losing futures.
- Our Fix D caps the total wait at 600 s at the batch level. That
  doesn't give quorum or cancel, but it guarantees the two-phase PUT
  always finalizes in bounded time so master's accounting stays
  consistent. Cherry-picking `be75ca0` on top makes Fix D redundant
  for the quorum case but still useful as a hard ceiling on total
  wait.

---

## Items in the reports that we did **not** address

Logical follow-ups for future patches on top of this branch:

| # | Source | Description |
|---|---|---|
| 1 | `batch_put_transfer_fail_cn.md` §3.9.b / upstream `be75ca0` | **Quorum write on `WaitForTransfers`**. Most direct cherry-pick; replaces Fix D's all-or-nothing bailout with `num_succeeded / failed_replicas` + quorum early-return. Keep Fix D as the hard deadline. |
| 2 | same §3.9.a | `SubmitTransfers` replica-0 failure breaks the whole op. Latent with `num_replica=1`; would bite with multi-replica writes. |
| 3 | `batch_put_transfer_fail_cn.md` §3.4 | `ExistKey` three-state semantics (absent / processing / complete). The root cause of the `OBJECT_NOT_FOUND` amplification chain (§3.1). Needs an upstream design change. |
| 4 | `rdma_handshake_timeout_cn.md` §7.2 #5 | Fail-fast on inactive endpoint (complements our Fix C for scenario B). |
| 5 | `rdma_handshake_timeout_cn.md` §7.2 #6–8 | Background auto-revive / circuit breaker / heartbeat (scenario B proper fix). |
| 6 | `rdma_handshake_timeout_cn.md` §3.12 | Enable `MC_SLICE_TIMEOUT` (half-finished mechanism, default `-1`). Quick win for scenario C. |
| 7 | `batch_put_transfer_fail_cn.md` §11, plans A–J | Observability: metadata access log, `PutStart discard` structured logs, `WaitForTransfers` progress, `ExistKey` MISS debug, decode-side load-success counters. |

---

## Summary

- Fix A and Fix B directly close action items `#10` and `#9` in the
  reports' "handshake-timeout" missing-fixes table.
- Fix C attacks the same symptom as the reports' fail-fast proposal
  but from the opposite side (don't mark inactive rather than
  short-circuit the inactive path).
- Fix D is a simpler stand-in for the reports' long-term
  quorum+cancel `WaitForTransfers` rewrite; `be75ca0` remains the
  right next cherry-pick.
