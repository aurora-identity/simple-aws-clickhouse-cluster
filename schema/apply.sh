#!/bin/sh
# Runs every .sql file in this directory, in name order, against one replica.
# The statements are ON CLUSTER, so one replica is enough to reach all of them.
#
#   CLICKHOUSE_HOST   the replica to send the statements to, default clickhouse-0
set -eu

HOST="${CLICKHOUSE_HOST:-clickhouse-0}"
DIR="$(cd "$(dirname "$0")" && pwd)"

for file in "$DIR"/*.sql; do
  echo "applying $(basename "$file") on $HOST"
  clickhouse-client --host "$HOST" --queries-file "$file"
done

echo "schema applied"
