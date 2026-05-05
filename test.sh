#!/bin/bash
set -euo pipefail

VMINSERT="http://localhost:8480/insert/0/prometheus"
VMSELECT="http://localhost:8481/select/0/prometheus"

write_metric() {
  local metric=$1 value=$2 ts_ms=$3
  curl -s -o /dev/null -w "%{http_code}" -X POST "$VMINSERT/api/v1/import/prometheus" \
    --data-binary "$metric $value $ts_ms"
}

query_metric() {
  local metric=$1
  curl -s "$VMSELECT/api/v1/query?query=$metric"
}

series_count() {
  echo "$1" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("data",{}).get("result",[])))'
}

metric_value() {
  echo "$1" | python3 -c '
import sys, json
data = json.load(sys.stdin)
results = data.get("data", {}).get("result", [])
print(results[0]["value"][1] if results else "(no data)")
'
}

is_partial() {
  echo "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("isPartial", False))'
}

show_result() {
  local label=$1 json=$2
  echo "  [$label]"
  echo "    isPartial : $(is_partial "$json")"
  echo "    value     : $(metric_value "$json")"
}

# Poll vmselect until it responds
wait_vmselect() {
  echo "         waiting for vmselect..."
  until curl -s "$VMSELECT/api/v1/query?query=up" > /dev/null 2>&1; do sleep 1; done
  echo "         vmselect ready"
}

# Write a metric and poll until vmselect returns it — ensures vminsert is
# fully connected to all vmstorage nodes before we proceed
wait_for_metric() {
  local metric=$1 ts_ms=$2
  local attempts=0
  until [ "$(series_count "$(query_metric "$metric")")" -gt 0 ] 2>/dev/null; do
    # Re-send the write in case vminsert wasn't fully connected on first attempt
    write_metric "$metric" 1.0 "$ts_ms" > /dev/null
    sleep 1
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 30 ]; then
      echo "ERROR: $metric never appeared — cluster not working end-to-end"
      docker compose logs vminsert
      exit 1
    fi
  done
}

wait_for_value() {
  local metric=$1 expected=$2 ts_ms=$3
  local attempts=0
  until [ "$(metric_value "$(query_metric "$metric")")" = "$expected" ] 2>/dev/null; do
    write_metric "$metric" "$expected" "$ts_ms" > /dev/null
    sleep 1
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 30 ]; then
      echo "ERROR: $metric never showed value=$expected"
      exit 1
    fi
  done
}

divider() { echo "================================================================="; }

divider
echo " VictoriaMetrics isPartial Correctness Bug"
echo " RF=3, 3 vmstorage nodes"
divider
echo ""

echo "Starting cluster..."
docker compose up -d
wait_vmselect

# Confirm end-to-end write path is working before the test begins
echo "         confirming end-to-end write path..."
PROBE_MS=$(( ($(date +%s) - 10) * 1000 ))
write_metric "vm_probe" 1.0 "$PROBE_MS" > /dev/null
wait_for_metric "vm_probe" "$PROBE_MS"
echo "         write path confirmed"
echo ""

# Use timestamps spaced 5 minutes apart so the query unambiguously
# returns the most recent value regardless of dedup or lookback windows
NOW_S=$(date +%s)
T1_MS=$(( (NOW_S - 300) * 1000 ))   # 5 minutes ago — value=1
T2_MS=$(( (NOW_S - 30) * 1000 ))    # 30 seconds ago — value=2

# ---------------------------------------------------------------
echo "[Step 1] Writing test_series=1 (all 3 nodes up)..."
write_metric "test_series" 1.0 "$T1_MS" > /dev/null
wait_for_metric "test_series" "$T1_MS"

result1=$(query_metric "test_series")
show_result "query 1 — all nodes up, value 1 written to all 3 nodes" "$result1"
echo ""

# ---------------------------------------------------------------
echo "[Step 2] Stopping vmstorage-2 and vmstorage-3..."
docker compose stop vmstorage-2 vmstorage-3
sleep 2
echo "         only vmstorage-1 is available"
echo ""

# ---------------------------------------------------------------
echo "[Step 3] Writing test_series=2 (only vmstorage-1 is up)..."
status=$(write_metric "test_series" 2.0 "$T2_MS")
echo "         vminsert HTTP status: $status  (accepted, RF not met, silently)"
echo "         waiting for value=2 to appear on vmstorage-1..."
wait_for_value "test_series" "2" "$T2_MS"
echo ""

# ---------------------------------------------------------------
echo "[Step 4] Querying test_series with only vmstorage-1 up (proves value=2 was written)..."
result_mid=$(query_metric "test_series")
show_result "query — only vmstorage-1 up, value=2 should be visible" "$result_mid"
echo ""

# ---------------------------------------------------------------
echo "[Step 5] Restarting vmstorage-2 and vmstorage-3, stopping vmstorage-1..."
docker compose start vmstorage-2 vmstorage-3
sleep 3  # wait for nodes to reconnect to vminsert/vmselect
docker compose stop vmstorage-1
sleep 2
echo "         vmstorage-1 down  — has test_series=1 AND test_series=2"
echo "         vmstorage-2 up    — has test_series=1 only"
echo "         vmstorage-3 up    — has test_series=1 only"
echo "         1 node down, 2/3 responding — below RF=3 failure threshold"
echo ""

# ---------------------------------------------------------------
result2=$(query_metric "test_series")

divider
echo " Results"
divider
echo ""
show_result "query 1 — all nodes up, after writing value=1" "$result1"
echo ""
show_result "query 2 — only vmstorage-1 up, after writing value=2 (proves write succeeded)" "$result_mid"
echo ""
show_result "query 3 — vmstorage-1 down, nodes 2+3 up (never received value=2)" "$result2"
echo ""

ip=$(is_partial "$result2")
val=$(metric_value "$result2")
# Use python for numeric comparison to handle "1" vs "1.0"
is_stale=$(echo "$result2" | python3 -c '
import sys, json
data = json.load(sys.stdin)
results = data.get("data", {}).get("result", [])
if not results:
    print("missing")
elif float(results[0]["value"][1]) != 2.0:
    print("stale")
else:
    print("correct")
')

divider
if [ "$ip" = "False" ] && [ "$is_stale" = "stale" ]; then
  echo " BUG CONFIRMED"
  echo ""
  echo "  query 2 proved value=2 was written and visible on vmstorage-1"
  echo "  query 3 returned value=$val  isPartial=False  (should be value=2)"
  echo ""
  echo "  vmselect sees 1 node down — below RF=3 — assumes all copies present."
  echo "  Nodes 2+3 only received the value=1 write. vmselect returns stale"
  echo "  data with no warning, no partial flag, no indication anything is wrong."
elif [ "$ip" = "False" ] && [ "$is_stale" = "missing" ]; then
  echo " BUG CONFIRMED (missing data variant)"
  echo ""
  echo "  query 2 returned no data with isPartial=false"
  echo "  The write was acknowledged but the data is silently missing."
else
  echo " Result: is_partial=$ip, value=$val, stale=$is_stale"
fi
divider

echo ""
echo "Cleaning up..."
docker compose down -v
