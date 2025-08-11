#!/bin/bash
set -euo pipefail

# Configuration
ROOT="/mnt/nfs/cs6450-labs"
LOG_ROOT="${ROOT}/logs"
SERVER_NODES=("node0" "node1")  # Edit as needed
CLIENT_NODES=("node2" "node3")  # Edit as needed

# Timestamped log directory
TS=$(date +"%Y%m%d-%H%M%S")
LOG_DIR="$LOG_ROOT/$TS"
mkdir -p "$LOG_DIR"
ln -sfn "$LOG_DIR" "$LOG_ROOT/latest"

echo "Logs will be in $LOG_DIR"

# Cleanup function
cleanup() {
    echo "Cleaning up processes on all nodes..."
    for node in "${SERVER_NODES[@]}" "${CLIENT_NODES[@]}"; do
        echo "Cleaning up processes on $node..."
        ssh $node "pkill -f 'kvs(server|client)' || true" 2>/dev/null || true
    done
    echo "Cleanup complete."
    echo
}

# Set trap for cleanup on script exit/interrupt
trap cleanup EXIT INT TERM

# Initial cleanup to ensure clean state
echo "Initial cluster cleanup..."
cleanup

echo "Building the project..."
make
echo

# Start servers
for node in "${SERVER_NODES[@]}"; do
    echo "Starting server on $node..."
    ssh $node "${ROOT}/bin/kvsserver > \"$LOG_DIR/kvsserver-$node.log\" 2>&1 &"
done

# Give servers time to start
sleep 2

# Start clients with a unique marker for identification
ARGS=""
for node in "${SERVER_NODES[@]}"; do
    ARGS+="-host $node:8080 "
done
CLIENT_PIDS=()
for node in "${CLIENT_NODES[@]}"; do
    echo "Starting client on $node..."
    # Use a marker in the command line to make it easier to identify and wait for
    CLIENT_MARKER="kvsclient-run-$TS-$node"
    ssh $node "exec -a '$CLIENT_MARKER' ${ROOT}/bin/kvsclient $ARGS > \"$LOG_DIR/kvsclient-$node.log\" 2>&1" &
    CLIENT_PIDS+=($!)
done

echo "Waiting for clients to finish..."
# Wait for all client SSH sessions to complete
for pid in "${CLIENT_PIDS[@]}"; do
    wait $pid 2>/dev/null || true
done

echo "All clients finished."

# Final cleanup will be handled by the trap
echo "Run complete. Logs in $LOG_DIR"
echo

# Calculate and display median ops/s from server logs
for node in "${SERVER_NODES[@]}"; do
    if [[ -f "$LOG_DIR/kvsserver-$node.log" ]]; then
        echo "Results for server on $node:"
        awk '/ops\/s / { a[NR] = $2 }
            END {
                if (NR == 0) { print "No ops/s data found"; exit }
                n = asort(a)
                if (n % 2)
                    print "median op/s " a[(n+1)/2]
                else
                    print "median op/s " (a[n/2] + a[n/2+1]) / 2
            }' < "$LOG_DIR/kvsserver-$node.log"
    fi
done

