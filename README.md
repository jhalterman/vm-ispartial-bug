# VictoriaMetrics `isPartial` Correctness Bug

This test demonstrates that VictoriaMetrics cluster can return `isPartial=false`
(claiming a query result is complete) when the data returned is silently stale.

## Background

VictoriaMetrics cluster uses a `replicationFactor` (RF) to replicate writes across
multiple vmstorage nodes. When querying, vmselect returns `isPartial=true` if enough
nodes are unavailable to trip the RF threshold, and `isPartial=false` otherwise —
trusting that the remaining nodes have complete data.

The bug: **vminsert does not guarantee writes reach RF nodes**. If some nodes are
unavailable during a write, vminsert accepts partial replication silently and returns
HTTP 204 to the caller. vmselect has no record of this. On a subsequent query, if the
node that holds the most recent write is down but total failures are below the RF
threshold, vmselect returns `isPartial=false` with stale data — no error, no warning.

## Requirements

Docker, Docker Compose, Python 3, curl

## Running the test

```bash
./test.sh
```

## What the test does

1. Starts a 3-node cluster with RF=3
2. **Writes `test_series=1`** with all nodes up — all 3 nodes receive it
3. **Query 1**: `isPartial=false`, `value=1` *(correct)*
4. Stops vmstorage-2 and vmstorage-3 — only vmstorage-1 is available
5. **Writes `test_series=2`** — vminsert accepts the write (HTTP 204), but only
   vmstorage-1 receives it (1 of 3 copies, RF not met, silently)
6. **Query 2**: `isPartial=false`, `value=2` *(correct — proves the write reached vmstorage-1)*
7. Restarts vmstorage-2 and vmstorage-3, then stops vmstorage-1 — the only node
   with the `value=2` write is now down; nodes 2+3 are up with only the stale `value=1` data
8. **Query 3**: `isPartial=false`, `value=1` *(bug — stale data returned as complete; last acknowledged write was value=2)*

## Why this matters operationally

This is not a rare edge case. It occurs during any routine operation that causes
even one write to miss a replica:

- **Rolling restarts / rollouts**: nodes cycle through unavailability sequentially.
  Each restart creates a window where writes are under-replicated. If a later
  restart takes down the node holding those writes, subsequent queries return stale
  data with `isPartial=false`.
- **Brief network partitions**: a momentary blip causes vminsert to skip a node.
  The write succeeds, the data gap persists until retention expires.
- **Node overload**: a slow node causes vminsert to skip it and accept incomplete
  replication.

In all cases, downstream systems (dashboards, alerting, recording rules) receive
`isPartial=false` responses with stale or missing data and no indication anything
is wrong.
