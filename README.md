# A simple ClickHouse cluster on AWS

A ClickHouse cluster on AWS that survives losing an availability zone: two replicas of
every table, a three-node ClickHouse Keeper quorum, and hot-to-warm storage tiering,
running on EKS with each replica and each Keeper pinned to its own zone. There is one
manifest, and it runs unchanged on a local cluster on your laptop and on EKS, so what you
test locally is what you deploy.

This is the database half of the
[Aurora Identity risk engine](https://github.com/aurora-identity/risk-engine), pulled out
so that it can be used on its own. It has been running in production there; this
repository is the setup with the application removed and an example table in its place.

![ClickHouse across three availability zones: your application, or a kubectl port-forward, writes to either of two ClickHouse replicas in zones a and b, each with a hot and a warm disk, and every replica keeps a session with all three Keeper nodes in zones a, b and c, which form the quorum](architecture.svg)

The two replicas hold every table and copy new parts to each other, so a client can
write to either. The dotted lines are the sessions each replica keeps with all three
Keepers, which agree among themselves over Raft on what the table contains. Losing any
one zone leaves one replica and two Keepers, which is enough to keep both reading and
writing.

## What you get

Two ClickHouse servers, `clickhouse-0` and `clickhouse-1`, forming one shard of a cluster
called `main`. A table created with `ENGINE = ReplicatedMergeTree` exists on both, and a
row written to either one appears on the other within a second or so. Reads and writes can
go to whichever replica is closer, and if one is down the other carries on.

Three ClickHouse Keeper nodes. Keeper is the coordination service that ReplicatedMergeTree
needs to agree on which parts exist and who inserted what. Three nodes is the smallest
number that can hold a quorum, which means the cluster keeps accepting writes while any
one of them is down. With one replica and one Keeper down at the same time it still
works; with two Keepers down it goes read-only until one comes back.

Two tiers of disk. Every table that uses the `hot_warm` storage policy starts on the hot
disk and, when its own TTL says so, is moved to the warm one and later deleted. The
example table moves after seven days and deletes after ninety.

One example table, `events`, in `schema/001-create-tables.sql`, that uses all of the
above. It is there to be replaced.

## How the pieces fit

`kubernetes/clickhouse.yaml` is the cluster: two StatefulSets, their headless Services,
and the storage they use. Each pod is pinned to a node labelled for it, `role=clickhouse`
or `role=keeper`, and an anti-affinity rule on the zone label keeps two replicas out of
the same zone and two Keepers likewise. Those labels are the contract between the
manifest and the cluster underneath it. On AWS, CloudFormation puts them on the nodes. On
your laptop, `kubernetes/kind.yaml` does.

`config/` holds the ClickHouse and Keeper configuration, and `make deploy` turns it into
ConfigMaps. Every hostname in those files is read from an environment variable that the
manifest sets, so the XML never mentions a cluster-specific name.

`schema/` holds numbered SQL files and `apply.sh`, which runs them in order against one
replica. The statements say `ON CLUSTER main`, so ClickHouse itself carries them to the
other replica through Keeper; you apply the schema once, not once per server.
`make schema` runs it as a Job.

`tests/test-cluster.sh` is the proof. It writes a row to replica 0 and waits for it on
replica 1, then the other way round, and checks that both replicas hold a Keeper session
and report the table as writable with two of two replicas active. It needs only `curl`.
`make test` runs it over two port-forwards, which is the same whether the cluster is on
your laptop or in AWS.

`aws/` is the part that exists only for AWS: CloudFormation for the network, the EKS
cluster and the two node groups, and `deploy.md` as the walkthrough.

The `Makefile` at the root ties it together. `make deploy`, `make schema` and `make test`
act on whatever cluster `kubectl` currently points at. `make local-up` and `make aws-kube`
are the two things that point it.

## Running it locally

You need Docker, `kubectl` and [kind](https://kind.sigs.k8s.io/), which runs a Kubernetes
cluster as a set of Docker containers, one per node. That matters here because it means
the local cluster can have six nodes carrying the same labels EKS gives them, and the
scheduler spreads the pods exactly as it would in AWS.

```bash
make local-up
make deploy
make schema
make test
```

`local-up` creates the cluster and prints its nodes with their role and zone. `deploy`
waits for both StatefulSets and lists the pods with the node each landed on. `schema`
prints the Job's log, in which you should see both replicas. `test` prints ten lines, and
they should all be green.

To look around, use `kubectl` or `k9s` as you would against any cluster:

```bash
kubectl get pods -n clickhouse -o wide
kubectl logs -n clickhouse clickhouse-0 -f
kubectl exec -n clickhouse clickhouse-0 -- clickhouse-client -q "SELECT * FROM system.replicas FORMAT Vertical"
kubectl exec -n clickhouse keeper-0 -- sh -c 'echo mntr | nc localhost 9181'
```

To watch the quorum do its job, take a Keeper away and keep writing:

```bash
kubectl delete pod -n clickhouse keeper-1
kubectl exec -n clickhouse clickhouse-1 -- clickhouse-client -q "INSERT INTO events (event_time, source, name) VALUES (now64(3), 'me', 'still-writing')"
kubectl exec -n clickhouse clickhouse-0 -- clickhouse-client -q "SELECT * FROM events WHERE source = 'me'"
```

The StatefulSet brings `keeper-1` back on its own. `make local-down` deletes the cluster
and its data.

## Deploying it to AWS

`aws/deploy.md` is the walkthrough and `aws/README.md` explains the shape of what it
builds. The short version is `make aws-plan`, `make aws-apply`, `make aws-kube`, and then
the same `make deploy`, `make schema` and `make test` you ran locally. The images are the
official ones from Docker Hub in both places; nothing is built or re-tagged.

The only account-specific values are the region and a stack name, both in `.env`.

## Using it for your own data

Add a new numbered file to `schema/` and never edit one that has already run somewhere.
A table needs three things to take part in the cluster: `ON CLUSTER main` on the
`CREATE`, `ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')`
so that both replicas agree on where in Keeper it lives, and
`SETTINGS storage_policy = 'hot_warm'` if you want the tiering. The example table shows
the TTL syntax that moves and then deletes. `make schema` runs anything new.

## Known gaps

**The `default` user has no password.** Anything that can reach port 8123 or 9000 can read
and write every table. That is fine for a laptop and for a cluster that runs nothing
else. The moment it is not, the "Hardening for your environment" section of
`aws/README.md` lists what to do, starting with that password. Those steps are left to
you on purpose, because each depends on what else lives next to the database.

**Storage on AWS is a directory on each node's own disk.** If a node is replaced, its
replica comes back empty and has to be told to refetch from the other one. The two
commands are in `aws/deploy.md`. The conventional alternative is the
[Amazon EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html),
which gives each pod its own EBS volume that follows it to a new node.

**The warm tier on AWS is on the same disk as the hot one.** The mechanism is real and the
parts do move, but nothing gets cheaper until you mount a second, slower volume at the
warm path.

**There are no backups and no monitoring.** Nothing ships to S3 and nothing alerts. The
`system.replicas` table and Keeper's `mntr` command are what you have.

**Nothing reaches the cluster from the internet.** You will need to
add a load balancer, TLS and client authentication before anything outside the VPC can
talk to it.

## Where this departs from the deployment it came from

This is an extraction, not a rewrite, but four things did change on the way:

The original mounted its volume at `/var/lib/clickhouse/default` and left
`/var/lib/clickhouse` itself, where ClickHouse keeps table metadata, on the container's
own filesystem. Here the whole of `/var/lib/clickhouse` is the persistent volume.

The original's hot and warm PersistentVolumes both pointed at the same `hostPath`, so the
two tiers were one directory with two names. Here they are two directories.

The original had nothing preventing both replicas from being scheduled onto the same
node. Here a pod anti-affinity rule on the zone makes the multi-zone claim a guarantee
rather than a likely outcome.

## Getting in touch

Questions, bugs and patches are welcome as
[issues](https://github.com/aurora-identity/simple-aws-clickhouse-cluster/issues) on this repository.

If you would like help running this, or adapting it to your own data, we are happy to
help: https://github.com/georgismitev.

## Licence

Apache 2.0. Full terms are in [LICENSE](LICENSE).
