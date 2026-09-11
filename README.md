# ClickHouse across three availability zones

A ClickHouse cluster that survives losing a zone: two replicas of every table, a
three-node ClickHouse Keeper quorum, and hot-to-warm storage tiering, running on EKS with
each replica and each Keeper pinned to its own availability zone. The same five
containers run on your laptop under docker-compose, with the same configuration files,
so what you test locally is what you deploy.

This is the database half of the
[Aurora Identity risk engine](https://github.com/aurora-identity/risk-engine), pulled out
so that it can be used on its own. It has been running in production there; this
repository is the setup with the application removed and an example table in its place.

## What you get

Two ClickHouse servers, `clickhouse-0` and `clickhouse-1`, forming one shard of a cluster
called `main`. A table created with `ENGINE = ReplicatedMergeTree` exists on both, and a
row written to either one appears on the other within a second or so. Reads and writes can
go to whichever replica is closer, and if one is down the other carries on.

Three ClickHouse Keeper nodes. Keeper is the coordination service that ReplicatedMergeTree
needs to agree on which parts exist and who inserted what. Three nodes is the smallest
number that can hold a quorum, which means the cluster keeps accepting writes while any
one of them is down. With one replica and one Keeper down at the same time it still
works; with two Keepers down it goes read-only until one comes back, and that is the
right behaviour, because a Keeper that cannot form a majority must not pretend to know
the truth.

Two tiers of disk. Every table that uses the `hot_warm` storage policy starts on the hot
disk and, when its own TTL says so, is moved to the warm one and later deleted. The
example table moves after seven days and deletes after ninety.

One example table, `events`, in `schema/001-create-tables.sql`, that uses all of the
above. It is there to be replaced.

## How the pieces fit

`config/` holds the ClickHouse and Keeper configuration, and there is only one copy of it.
Every hostname in those files is read from an environment variable, so under docker-compose
the replicas are called `clickhouse-0` and `clickhouse-1` and on Kubernetes they are
`clickhouse-0.clickhouse.clickhouse.svc.cluster.local` and so on, with the XML unchanged.
A server refuses to start if one of those variables is missing, which is better than
starting with the wrong neighbours.

`schema/` holds numbered SQL files and `apply.sh`, which runs them in order against one
replica. The statements say `ON CLUSTER main`, so ClickHouse itself carries them to the
other replica through Keeper; you apply the schema once, not once per server. Under
docker-compose a one-shot `schema` container does this after both replicas answer. On
Kubernetes a Job does the same.

`tests/test-cluster.sh` is the proof. It writes a row to replica 0 and waits for it on
replica 1, then the other way round, and checks that both replicas hold a Keeper session
and report the table as writable with two of two replicas active. It needs only `curl`.

`aws/` is the deployment: CloudFormation for the network, the EKS cluster and the two node
groups, a Kubernetes manifest for the two StatefulSets, a Makefile that ties the steps
together, and `deploy.md` as the walkthrough.

## Running it locally

You need Docker.

```bash
docker compose up -d
```

That starts three Keepers, two replicas and the schema job, and the schema job exits when
the table exists on both. Replica 0 is on `localhost:8123` (HTTP) and `9000` (native),
replica 1 on `8124` and `9001`. Then:

```bash
tests/test-cluster.sh
```

Ten green lines means the cluster is doing what it claims. To see what is going on
underneath:

```bash
docker compose exec clickhouse-0 clickhouse-client -q "SELECT * FROM system.replicas FORMAT Vertical"
docker compose exec clickhouse-0 clickhouse-client -q "SELECT * FROM system.clusters WHERE cluster = 'main'"
docker compose exec keeper-0 sh -c 'echo mntr | nc localhost 9181'
```

ClickHouse also serves a small SQL console at `http://localhost:8123/play`.

To watch the quorum do its job, stop one Keeper and keep writing:

```bash
docker compose stop keeper-1
docker compose exec clickhouse-1 clickhouse-client -q "INSERT INTO events (event_time, source, name) VALUES (now64(3), 'me', 'still-writing')"
docker compose exec clickhouse-0 clickhouse-client -q "SELECT * FROM events WHERE source = 'me'"
docker compose start keeper-1
```

`docker compose down -v` throws the data away; without `-v` it survives.

## Deploying it to AWS

`aws/deploy.md` is the walkthrough and `aws/README.md` explains the shape of what it
builds. The short version is `make plan`, `make apply`, `make kube`, `make deploy`,
`make schema`, `make test`, each from the `aws/` directory. The last one runs the same
test script over two port-forwards. The images on AWS are the same official ones from
Docker Hub that docker-compose runs; nothing is built or re-tagged.

The only account-specific values are the region and a stack name, both in `aws/.env`.

## Using it for your own data

Add a new numbered file to `schema/` and never edit one that has already run somewhere.
A table needs three things to take part in the cluster: `ON CLUSTER main` on the
`CREATE`, `ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')`
so that both replicas agree on where in Keeper it lives, and
`SETTINGS storage_policy = 'hot_warm'` if you want the tiering. The example table shows
the TTL syntax that moves and then deletes.

Locally, `docker compose up schema` runs anything new. On Kubernetes it is `make schema`.

## Known gaps

**The `default` user has no password.** Anything that can reach port 8123 or 9000 can read
and write every table. That is fine for a laptop and for a cluster that runs nothing
else. `aws/README.md` says what to add when it is not.

**Storage on AWS is a directory on each node's own disk.** If a node is replaced, its
replica comes back empty and has to be told to refetch from the other one. The two
commands are in `aws/deploy.md`. The EBS CSI driver is the conventional alternative and is
not in this repository.

**The warm tier on AWS is on the same disk as the hot one.** The mechanism is real and the
parts do move, but nothing gets cheaper until you mount a second, slower volume at the
warm path.

**There are no backups and no monitoring.** Nothing ships to S3 and nothing alerts. The
`system.replicas` table and Keeper's `mntr` command are what you have.

**Nothing reaches the cluster from the internet.** That is deliberate. A load balancer,
TLS and client authentication are yours to add.

## Where this departs from the deployment it came from

This is an extraction, not a rewrite, but four things did change on the way, and they are
worth knowing about if you are comparing the two.

The original mounted its volume at `/var/lib/clickhouse/default` and left
`/var/lib/clickhouse` itself, where ClickHouse keeps table metadata, on the container's
own filesystem. Here the whole of `/var/lib/clickhouse` is the persistent volume.

The original's hot and warm PersistentVolumes both pointed at the same `hostPath`, so the
two tiers were one directory with two names. Here they are two directories.

The original had nothing preventing both replicas from being scheduled onto the same
node. Here a pod anti-affinity rule on the zone makes the multi-zone claim a guarantee
rather than a likely outcome.

The original baked the schema into a custom ClickHouse image and ran it from the image's
init hook. Here the images are the unmodified official ones and the schema is applied by
a small script, which is the same script in both environments.

## Getting in touch

Questions, bugs and patches are welcome as
[issues](https://github.com/aurora-identity/clickhouse-cluster/issues) on this repository.

If you would like help running this, or adapting it to your own data, we are happy to
help: https://github.com/georgismitev.

## Licence

Apache 2.0. Full terms are in [LICENSE](LICENSE).
