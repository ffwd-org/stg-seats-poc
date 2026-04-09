#!/bin/bash
# test-failure-modes.sh — POC 5 Phase E: Centrifugo Failure Modes
# Run from loadgen node after 250K connections are established
# Usage: ./scripts/test-failure-modes.sh <centrifugo-ip>
set -uo pipefail

CENTRIFUGO_IP="${1:?Usage: $0 <centrifugo-ip>}"
RESULTS_DIR="results/failure-modes"
mkdir -p "$RESULTS_DIR"

echo "[$(date)] === Phase E: Failure Mode Testing ==="
echo "[$(date)] Centrifugo: $CENTRIFUGO_IP"

# Record baseline
echo "[$(date)] --- E1: Baseline (healthy) ---"
# Capture current connected count from conngen metrics
curl -sf "http://localhost:2113/metrics" | grep -E "^(connected|reconnects|disconnects)" > "$RESULTS_DIR/baseline.txt" 2>/dev/null || true
echo "[$(date)] Baseline recorded"

# Run baseline broadcasts (10/sec for 30s)
./bin/broadcaster --target="http://$CENTRIFUGO_IP:9000" --api-key=poc-api-key \
  --channel="events:event-1" --rate=10 --duration=30s \
  > "$RESULTS_DIR/e1-baseline-broadcast.log" 2>&1
echo "[$(date)] Baseline broadcast complete"

# Kill Centrifugo
echo "[$(date)] --- E2: Kill Centrifugo ---"
KILL_TIME=$(date +%s)
ssh -o StrictHostKeyChecking=no "$CENTRIFUGO_IP" "docker stop centrifugo" 2>/dev/null || true
echo "[$(date)] Centrifugo stopped"

# Monitor disconnection storm (30s)
echo "[$(date)] Monitoring disconnection storm for 30s..."
for i in $(seq 1 6); do
  sleep 5
  STATS=$(curl -sf "http://localhost:2113/metrics" 2>/dev/null | grep -E "^(connected|disconnects)" || echo "metrics unavailable")
  echo "[$(date)]   $STATS"
done

# Record post-kill state
curl -sf "http://localhost:2113/metrics" | grep -E "^(connected|reconnects|disconnects)" > "$RESULTS_DIR/post-kill.txt" 2>/dev/null || true

# Try broadcasting while down (should fail)
echo "[$(date)] --- E3: Broadcast while down ---"
./bin/broadcaster --target="http://$CENTRIFUGO_IP:9000" --api-key=poc-api-key \
  --channel="events:event-1" --rate=10 --duration=10s \
  > "$RESULTS_DIR/e3-broadcast-while-down.log" 2>&1 || true
echo "[$(date)] Broadcast-while-down complete"

# Restart Centrifugo
echo "[$(date)] --- E4: Restart Centrifugo ---"
RESTART_TIME=$(date +%s)
ssh -o StrictHostKeyChecking=no "$CENTRIFUGO_IP" "docker start centrifugo" 2>/dev/null || true
echo "[$(date)] Centrifugo restarted"

# Monitor reconnection storm (120s)
echo "[$(date)] Monitoring reconnection storm for 120s..."
for i in $(seq 1 24); do
  sleep 5
  STATS=$(curl -sf "http://localhost:2113/metrics" 2>/dev/null | grep -E "^(connected|reconnects)" || echo "metrics unavailable")
  echo "[$(date)]   $STATS"
done

# Record post-restart state
curl -sf "http://localhost:2113/metrics" | grep -E "^(connected|reconnects|disconnects)" > "$RESULTS_DIR/post-restart.txt" 2>/dev/null || true

# Broadcast after recovery
echo "[$(date)] --- E5: Broadcast after recovery ---"
./bin/broadcaster --target="http://$CENTRIFUGO_IP:9000" --api-key=poc-api-key \
  --channel="events:event-1" --rate=10 --duration=30s \
  > "$RESULTS_DIR/e5-post-recovery-broadcast.log" 2>&1
echo "[$(date)] Post-recovery broadcast complete"

# Summary
echo ""
echo "[$(date)] === Phase E Summary ==="
echo "Kill time: $KILL_TIME"
echo "Restart time: $RESTART_TIME"
RECOVERY_SECS=$((RESTART_TIME - KILL_TIME))
echo "Downtime: ${RECOVERY_SECS}s"
echo "Baseline:"
cat "$RESULTS_DIR/baseline.txt" 2>/dev/null
echo "Post-kill:"
cat "$RESULTS_DIR/post-kill.txt" 2>/dev/null
echo "Post-restart:"
cat "$RESULTS_DIR/post-restart.txt" 2>/dev/null
echo "[$(date)] === Phase E Complete ==="
