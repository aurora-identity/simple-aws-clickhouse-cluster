# The AWS deployment

This directory holds the CloudFormation for the cluster and its networking, the
Kubernetes manifests for ClickHouse, and `deploy.md` as the step-by-step. Read `deploy.md`
to do it; this file describes the shape of what you end up with.

## What gets built

CloudFormation creates a VPC with three private subnets, one per availability zone, and
an EKS cluster whose nodes live in them. The nodes have no public addresses. One small
public subnet holds a NAT gateway, and that is the nodes' only route out; they use it to
join the cluster and to pull the official ClickHouse images from Docker Hub, the same
tags docker-compose runs. The NAT gateway sits in one zone, so if that zone goes down the
nodes elsewhere cannot pull an image until it is back. A running cluster does not notice,
because the images are already on the nodes; a pod that has to start on a fresh node
during that window would wait.

Two managed node groups. `role=clickhouse` is two `m6i.large` instances with a 200 GB
disk each, tainted so that only ClickHouse lands on them. `role=keeper` is three
`t3.medium` instances with 20 GB each, not tainted, so that CoreDNS and the schema Job
have somewhere to run. EKS spreads each group across the three zones.

Kubernetes then runs two StatefulSets in the `clickhouse` namespace. `clickhouse` is one
shard with two replicas, and `keeper` is three nodes, the smallest number that holds a
quorum. Both carry a pod anti-affinity rule on the zone, so two replicas can never share a
zone and neither can two Keepers. If the node group did not manage to spread across
zones, the pod stays Pending rather than quietly landing next to its twin; `make kube`
prints the zones so you can see this before it bites.

The configuration the pods read is the `config/` directory at the root of this
repository, turned into ConfigMaps by `make deploy`. The same files run under
docker-compose. The only thing that differs between the two is the hostnames, and those
are environment variables set in the manifest.

## Storage and retention

Storage is deliberately not dynamic. The `node-local` StorageClass has no provisioner, and
the PersistentVolumes in `kubernetes/clickhouse.yaml` are declared by hand: a `hostPath`
on each node, pinned to nodes with the right `role` label. A ClickHouse pod mounts
`/var/lib/clickhouse` for hot data and metadata, and `/var/lib/clickhouse-warm` for warm
data. Both directories are on the node's single EBS root volume, so on this deployment the
warm tier shows the mechanism rather than saving money. Attaching a cheaper second volume
and mounting it at the warm path is the change that would make it pay.

The consequence of node-local storage is that a replaced node comes back empty. That is
survivable, because the other replica has everything and ClickHouse copies it back, but it
needs a hand; `deploy.md` has the two commands. If you would rather not, the EBS CSI driver
with dynamically provisioned volumes is the conventional alternative, and it is not in
this repository.

Retention is on the table, not the cluster. The example table moves parts to the warm
volume after seven days and deletes them after ninety; both numbers are in
`schema/001-create-tables.sql` and changing them is an `ALTER TABLE`.

## Access

`config/server/users.d/users.xml` defines two users. `admin` can manage access and is
reachable only from `127.0.0.1` inside its own pod. `default` is what clients use, has no
password, and is reachable from anything that can connect to the pod. There is no
NetworkPolicy in these manifests, so anything running in the cluster can read and write
every table. In a cluster that runs only this that may be acceptable; if it is not, a
NetworkPolicy on the namespace and a password on `default` are the two things to add, and
a password belongs in a Secret rather than in this ConfigMap.

## What is not here

No backups. Nothing ships parts to S3, and the ClickHouse `BACKUP` command is not wired to
anything.

No monitoring. There are no Prometheus rules, and nothing alerts on replication lag, disk
usage or a Keeper losing quorum. `system.replicas` and Keeper's `mntr` command, both shown
in `deploy.md`, are what you have.

No way in from the internet. The cluster is reachable by `kubectl port-forward` and by
workloads inside it. A load balancer, TLS and authentication for outside clients are all
yours to add.
