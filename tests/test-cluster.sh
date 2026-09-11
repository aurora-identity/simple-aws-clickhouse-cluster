#!/usr/bin/env bash
# Proves the cluster is really replicating. A row written to one replica has to show up on
# the other, in both directions, and both replicas have to report a working Keeper
# connection and a writable table. Needs only curl.
#
#   REPLICA_0   HTTP address of replica 0, default http://localhost:8123
#   REPLICA_1   HTTP address of replica 1, default http://localhost:8124
set -euo pipefail

REPLICA_0="${REPLICA_0:-http://localhost:8123}"
REPLICA_1="${REPLICA_1:-http://localhost:8124}"
RUN_ID="test-$(date +%s)-$RANDOM"
FAILED=0

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; FAILED=1; }

# query <replica-url> <sql>
query() {
  curl -sS --fail --max-time 10 "$1" --data-binary "$2"
}

check_ping() {
  if [[ "$(curl -s --max-time 5 "$1/ping")" == "Ok." ]]; then
    pass "$2 answers /ping"
  else
    fail "$2 does not answer /ping at $1"
  fi
}

check_keeper() {
  if [[ "$(query "$1" "SELECT count() FROM system.zookeeper_connection")" -ge 1 ]]; then
    pass "$2 is connected to Keeper"
  else
    fail "$2 has no Keeper connection"
  fi
}

check_replica() {
  local status
  status=$(query "$1" "SELECT is_readonly, active_replicas, total_replicas FROM system.replicas WHERE table = 'events' FORMAT TSV")
  if [[ "$status" == $'0\t2\t2' ]]; then
    pass "$2 sees events as writable with 2 of 2 replicas active"
  else
    fail "$2 reports is_readonly, active_replicas, total_replicas = ${status:-no such table}"
  fi
}

# insert <replica-url> <name>
insert() {
  query "$1" "INSERT INTO events (event_time, source, name, value, attributes)
              VALUES (now64(3), '$RUN_ID', '$2', 1, '{\"written_to\": \"$2\"}')"
}

# wait_for_row <replica-url> <name> <message>
wait_for_row() {
  for _ in $(seq 1 30); do
    if [[ "$(query "$1" "SELECT count() FROM events WHERE source = '$RUN_ID' AND name = '$2'")" == "1" ]]; then
      pass "$3"
      return
    fi
    sleep 1
  done
  fail "$3 (gave up after 30s)"
}

check_ping "$REPLICA_0" "replica 0"
check_ping "$REPLICA_1" "replica 1"
check_keeper "$REPLICA_0" "replica 0"
check_keeper "$REPLICA_1" "replica 1"
check_replica "$REPLICA_0" "replica 0"
check_replica "$REPLICA_1" "replica 1"

insert "$REPLICA_0" "replica-0"
wait_for_row "$REPLICA_1" "replica-0" "a row written to replica 0 arrived on replica 1"

insert "$REPLICA_1" "replica-1"
wait_for_row "$REPLICA_0" "replica-1" "a row written to replica 1 arrived on replica 0"

for replica in "$REPLICA_0" "$REPLICA_1"; do
  if [[ "$(query "$replica" "SELECT count() FROM events WHERE source = '$RUN_ID'")" == "2" ]]; then
    pass "$replica holds both rows from this run"
  else
    fail "$replica does not hold both rows from this run"
  fi
done

exit "$FAILED"
