# VictoriaMetrics `isPartial` Correctness Bug

This test demonstrates that VictoriaMetrics cluster can return `isPartial=false`
(claiming a query result is complete) when data is silently missing.

## Background

VictoriaMetrics cluster uses a `replicationFactor` (RF) to replicate writes across
multiple vmstorage nodes. When querying, vmselect returns `isPartial=true` if enough
nodes are unavailable to trip the RF threshold, and `isPartial=false` otherwise —
trusting that the remaining nodes have complete data.

The bug: **vminsert does not guarantee writes reach RF nodes**. If some nodes are
unavailable during a write, vminsert accepts partial replication silently and returns
HTTP 204 to the caller. vmselect has no record of this. On a subsequent query, if the
node that holds the only copy is down but total failures are below the RF threshold,
vmselect returns `isPartial=false` with missing data — no error, no warning.

### Relevant code

vminsert accepts incomplete replication as success
(`app/vminsert/netstorage/netstorage.go`):

```go
// The data is partially replicated, so just emit a warning and return true.
// We could retry sending the data again, but this may result in uncontrolled duplicate data.
// So it is better returning true.
rowsIncompletelyReplicatedTotal.Add(br.rows)
incompleteReplicationLogger.Warnf("cannot make a copy #%d out of %d copies...")
return true  // write considered successful
```

vmselect assumes RF copies exist based on a node count threshold
(`app/vmselect/netstorage/netstorage.go`):

```go
// Assume that the result is full if the number of failed groups
// is smaller than the globalReplicationFactor.
if failedGroups < *globalReplicationFactor {
    return false, nil  // isPartial=false
}
```

These two halves share no state. vmselect's correctness assumption is never verified
against what vminsert actually achieved.

## Running the test

```bash
cd vm-ispartial-bug
chmod +x test.sh
./test.sh
```

## What the test does

1. Starts a 3-node cluster with RF=3
2. **Writes `test_series=1`** with all nodes up — all 3 nodes receive it
3. **Queries `test_series`** — `isPartial=false`, `value=1` *(correct)*
4. Stops vmstorage-2 and vmstorage-3 — only vmstorage-1 is available
5. **Writes `test_series=2`** — vminsert accepts the write (HTTP 204), but only
   vmstorage-1 receives it (1 of 3 copies, RF not met, silently)
6. Restarts vmstorage-2 and vmstorage-3, then stops vmstorage-1 — the only node
   with the `value=2` write is now down; nodes 2+3 are up with stale `value=1` data
7. **Queries `test_series`** — `isPartial=false`, `value=1` *(bug — stale data returned
   as if complete; last write was value=2)*

## Expected output

```
=================================================================
 VictoriaMetrics isPartial Correctness Bug
 RF=3, 3 vmstorage nodes
=================================================================

[Step 1] Writing test_series=1 (all 3 nodes up)...
  [query 1 — all nodes up, value 1 written to all 3 nodes]
    isPartial : False
    value     : 1

[Step 2] Stopping vmstorage-2 and vmstorage-3...
         only vmstorage-1 is available

[Step 3] Writing test_series=2 (only vmstorage-1 is up)...
         vminsert HTTP status: 204  (accepted, RF not met, silently)

[Step 4] Restarting vmstorage-2 and vmstorage-3, stopping vmstorage-1...
         vmstorage-1 down  — has test_series=1 AND test_series=2
         vmstorage-2 up    — has test_series=1 only
         vmstorage-3 up    — has test_series=1 only
         1 node down, 2/3 responding — below RF=3 failure threshold

=================================================================
 Results
=================================================================

  [query 1 — all nodes up]
    isPartial : False
    value     : 1

  [query 2 — vmstorage-1 down (only node with value=2)]
    isPartial : False
    value     : 1

=================================================================
 BUG CONFIRMED

  last write : value=2  (written to vmstorage-1 only, now down)
  query 2    : value=1  isPartial=False

  vmselect sees 1 node down — below RF=3 — assumes all copies present.
  Nodes 2+3 only received the value=1 write. vmselect returns stale
  data with no warning, no partial flag, no indication anything is wrong.
=================================================================
```

## Why this matters operationally

This is not a rare edge case. It occurs during any routine operation that causes
even one write to miss a replica:

- **Rolling restarts / rollouts**: nodes cycle through unavailability sequentially.
  Each restart creates a window where writes are under-replicated. If a later
  restart takes down the node holding those writes, results are silently incomplete.
- **Brief network partitions**: a momentary blip causes vminsert to skip a node.
  The write succeeds, the gap persists until retention expires.
- **Node overload**: a slow node causes vminsert to time out and skip it.

In all cases, downstream systems (dashboards, alerting, recording rules) receive
`isPartial=false` responses with missing data and no indication anything is wrong.
