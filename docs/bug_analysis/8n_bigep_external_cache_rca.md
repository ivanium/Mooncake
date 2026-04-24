# Large-scale DEP · Mooncake External Cache — Fixes

**Observed on:** 8 × GB200, DP=32, EP=32, MLA, Mooncake P2P-handshake
(Kimi K2.5, `mt_k25_mooncake.json`, 1000 prompts × 5 turns)

## Result

| Metric | Baseline (`71b6212`) | With these fixes |
|---|---|---|
| External cache hit rate | **0.00%** | **64.41%** |
| `master_batch_put_end_total` (commits) | 0 | 9,328 |
| `master_batch_put_revoke_total` (rollbacks) | ≈1 per run | 0 |
| Total token throughput | 21–35 k tok/s | **79,382 tok/s** |

Same recipe on 2-node / 4-node DEP was already hitting ~66 % on the
baseline — the symptom only manifests once the peer mesh passes the
scale threshold described below. The four patches here make large-scale
DEP behave like small-scale DEP.

---

## Why large-scale DEP specifically hits these bugs

In Mooncake's P2P-handshake mode every Transfer Engine instance is an
independent client that must establish an RDMA QP pair **on demand**
with every peer it transfers to. For vLLM with DP=*N* × per-rank RDMA
contexts =*M*, the peer mesh has *O(N·M)* pairwise connections
(8 nodes × 4 engines/node = 32 local TEs × 31 peers × ~4 HCA contexts
each ≈ **≥1000 pairwise handshakes**).

Because the handshakes are lazy, **all 1000 fire within the ~50 ms
window around the first batch-put of the benchmark** — the classic
thundering herd. At small scale (≤4 nodes) the mesh is small enough
that every handshake just succeeds on the first try. At large DEP the
burst saturates the single-threaded TCP handshake listener and
trips a chain of independent bugs that each individually sound
tolerable but compose into a permanent stall:

1. Listener can't drain connections fast enough → client-side reads
   return empty / partial payloads → RPC returns error.
2. A single RPC error permanently marks the endpoint (and eventually
   the whole local RNIC) as inactive.
3. Transfers to dead endpoints never complete → `WaitForTransfers`
   drains its per-future 60 s timeout once per op, serially.
4. 62 ops × 60 s per BatchPut ≈ one hour before the two-phase PUT
   ever reaches `PutEnd` / `PutRevoke`.
5. During that hour master holds the keys in the "reserved, not yet
   committed" state; other clients' `batch_is_exist` can't
   distinguish that from "committed" and skip their own PUTs.
6. Once the original op finally times out and revokes, the benchmark
   window is already over: no key ever got committed, 0 % hit.

At small scale only steps 1–2 occasionally trip, and step 3 self-heals
before step 5 can cascade. At large DEP all five compound.

---

## The four fixes

Each fix targets one link in the chain above.

### Fix A — Multi-thread the handshake listener

**File:** `mooncake-transfer-engine/src/transfer_metadata_plugin.cpp`
**Addresses:** step 1 (listener can't drain connections).

**Before** (`SocketHandShakePlugin::startDaemon`): a single listener
thread did `accept → read request → run callback → writeString
response → shutdown(SHUT_WR) → blocking read() waiting for the client
half-close → close()`. The whole pipeline, including that blocking
"wait for client to close" step, ran on one thread. 1000 concurrent
handshakes can't drain through it in time, and the client side sees
empty / partial / mis-typed responses (`malformed json format`,
`unexpected handshake message type`) followed by endpoint resets.

**After:** the listener thread only does `accept()`, then detaches
each accepted connection onto its own worker thread that runs the rest
of the pipeline. A `workers_in_flight_` counter + condition variable
in the destructor drains outstanding workers on shutdown so the
handshake callbacks can't touch freed state.

### Fix B — Retry `sendHandshake` / `sendNotify` / `getSegmentDesc` with exponential backoff

**File:** `mooncake-transfer-engine/src/transfer_metadata.cpp`
**Addresses:** step 1 residue (transient RPC failures not fully
eliminated by Fix A) and the self-triggering feedback loop with Fix C.

**Before:** each of the three handshake-family RPCs called
`handshake_plugin_->{send,sendNotify,exchangeMetadata}()` exactly once.
Any transient failure — `ECONNREFUSED` from a peer that hasn't yet
called `listen()`, a short read under listener contention, a TCP
connect racing with the peer's bind — propagated straight up to
`setupConnectionsByActive` → worker pool.

**After:**

| RPC | Retries | Backoff | Budget |
|---|---|---|---|
| `sendHandshake` (Connection type) | 10 | 100 ms…1 s | ~6 s |
| `sendNotify` (Notify type) | 10 | 100 ms…1 s | ~6 s |
| `getSegmentDesc` → `exchangeMetadata` (Metadata type) | 5 | 100 ms…800 ms | ~1.5 s |

The passive-side `receivePeerMetadata` intentionally stays single-shot
— it runs inside the listener's callback path, and blocking it would
stall concurrent handshakes (see the comment in the file).

### Fix C — Stop marking endpoints / RNIC inactive on a single handshake failure

**File:** `mooncake-transfer-engine/src/transport/rdma_transport/worker_pool.cpp`
**Addresses:** step 2 (single failure cascades to permanent dead
endpoint).

**Before** (`WorkerPool::performPostSend`): when
`endpoint->setupConnectionsByActive()` returned non-zero, the worker
would
1. call `endpoint->set_active(false)` — permanent until the endpoint
   is explicitly deleted,
2. increment `failed_nr_polls`; once `> 32 && !success_nr_polls`,
   also mark the entire local RDMA context inactive via
   `context_.set_active(false)`.

Under the startup handshake burst, 32 concurrent transient failures
are exactly enough to disable the local RNIC, after which every
subsequent transfer fails fast and drags the benchmark through
`WaitForTransfers`'s 60 s-per-future tarpit.

**After:** log a `WARNING`, requeue the slices via
`failed_slice_list`, and rely on the existing redispatch path +
`globalConfig().retry_cnt = 9` for retry. No endpoint is marked
inactive on first failure. Combined with Fix B the redispatch
eventually succeeds once the listener catches up.

### Fix D — Cap `WaitForTransfers` with a batch-level deadline

**File:** `mooncake-store/src/client_service.cpp`
**Addresses:** steps 3–4 (serial per-future timeout compounds into
multi-minute batch stalls).

**Before:** `WaitForTransfers` called `pending_transfers[i].get()` in a
straight `for` loop. Each `get()` has its own ~60 s internal timeout;
with 62 ops per batch the worst-case wait is 62 × 60 s ≈ 62 minutes
per BatchPut. If the happy path took ~1 s but a single peer's QP
setup was stuck, the whole BatchPut blocked for the entire benchmark
window and never reached finalize.

**After:** a single `deadline = now() + 600 s` is computed once at the
top of `WaitForTransfers`. Inside the per-op loop, if an op's future is
still unready past the deadline, the code skips the blocking `get()`
and takes the existing `SetError(first_error, ...)` path. Every op
always reaches `FinalizeBatchPut` in a definitive state, which in turn
always produces exactly one of `BatchPutEnd` (commit) or
`BatchPutRevoke` (rollback) to master — so master's accounting never
stalls.

---

## Files changed

```
mooncake-store/src/client_service.cpp                                  Fix D
mooncake-transfer-engine/src/transfer_metadata.cpp                     Fix B
mooncake-transfer-engine/src/transfer_metadata_plugin.cpp              Fix A
mooncake-transfer-engine/src/transport/rdma_transport/worker_pool.cpp  Fix C
```

## How the fixes compose

Mooncake at small scale works because the thundering herd never forms.
At large DEP scale, the herd is the load-bearing variable — any single
one of bugs 1–4 above, in isolation, would still let the system
recover; all four together create a one-way street into the
"reserved-never-committed" trap.

- Fix A widens the listener bottleneck so **fewer** handshake RPCs
  fail in the first place.
- Fix B makes the failures that do happen **transient** rather than
  fatal.
- Fix C prevents a single transient failure from **permanently**
  disabling the path.
- Fix D ensures that even in the worst case where something does get
  permanently stuck, the batch **still finalizes** in bounded time and
  master's accounting stays consistent so the next batch can proceed.
