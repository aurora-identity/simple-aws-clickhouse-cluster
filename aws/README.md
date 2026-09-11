# The AWS deployment

This directory holds the CloudFormation for the cluster and its networking, and
`deploy.md` as the step-by-step. The Kubernetes manifest is not here, because it is not
AWS-specific; it is in `kubernetes/` at the root and runs unchanged on kind. Read
`deploy.md` to do it; this file describes the shape of the AWS part.

## What gets built

CloudFormation creates a VPC with three private subnets, one per availability zone, and
an EKS cluster whose nodes live in them. The nodes have no public addresses. One small
public subnet holds a NAT gateway, and that is the nodes' only route out; they use it to
join the cluster and to pull the official ClickHouse images from Docker Hub. The NAT
gateway sits in one zone, so if that zone goes down the nodes elsewhere cannot pull an
image until it is back. A running cluster does not notice,
because the images are already on the nodes; a pod that has to start on a fresh node
during that window would wait.

Two managed node groups. `role=clickhouse` is two `m6i.large` instances with a 200 GB
disk each, tainted so that only ClickHouse lands on them. `role=keeper` is three
`t3.medium` instances with 20 GB each, not tainted, so that CoreDNS and the schema Job
have somewhere to run. EKS spreads each group across the three zones. Every disk is
encrypted, and the instance metadata service is set so that only the node itself can
reach it, not the pods on it.

The Kubernetes API has a public endpoint, because that is how `kubectl` and `make test`
reach the cluster from your desk, but it answers only to the addresses you allow. `make
aws-plan` passes the public address you are running it from; set `API_ALLOWED_CIDRS` in
`.env` if you work from more than one place. IAM still authenticates every request on
top of that.

Kubernetes then runs two StatefulSets in the `clickhouse` namespace. `clickhouse` is one
shard with two replicas, and `keeper` is three nodes, the smallest number that holds a
quorum. Both carry a pod anti-affinity rule on the zone, so two replicas can never share a
zone and neither can two Keepers. If the node group did not manage to spread across
zones, the pod stays Pending and `make aws-kube` prints the zones so you can see this.

The configuration the pods read is the `config/` directory at the root of this
repository, turned into ConfigMaps by `make deploy`, exactly as on the local cluster.

## Storage and retention

Storage is not dynamic. The `node-local` StorageClass has no provisioner, and
the PersistentVolumes in `kubernetes/clickhouse.yaml` at the root are declared by hand: a
`hostPath` on each node, pinned to nodes with the right `role` label. A ClickHouse pod mounts
`/var/lib/clickhouse` for hot data and metadata, and `/var/lib/clickhouse-warm` for warm
data. Both directories are on the node's single EBS root volume, so on this deployment the
warm tier shows the mechanism. Attaching a cheaper second volume and mounting it at the warm
path is the change that would also save money.

The consequence of node-local storage is that a replaced node comes back empty. That is
survivable, because the other replica has everything and ClickHouse copies it back, but it
needs a hand; `deploy.md` has the two commands. If you would rather not, the EBS CSI driver
with dynamically provisioned volumes is a conventional alternative.

Retention is on the table, not the cluster. The example table moves parts to the warm
volume after seven days and deletes them after ninety; both numbers are in
`schema/001-create-tables.sql` and changing them requires an `ALTER TABLE`.

## Hardening for your environment

This repository assumes the cluster and its VPC run nothing but ClickHouse and
the things that talk to it. When more people need to use it, consider the following:

**Put a password on `default`.** `config/server/users.d/users.xml` defines two users.
`admin` can manage access and is reachable only from `127.0.0.1` inside its own pod. `default`
is what clients use, and it has no password, so anything that can open a connection to
port 8123 or 9000 can read and write every table and run any query. Give it a
`password_sha256_hex` read with `from_env`, the way the hostnames already are, and set
that variable from a Kubernetes Secret rather than a ConfigMap, because ConfigMaps are
readable by anyone who can read the namespace. The `admin` hash in the repository is for
the password `change-me` and should move to the same Secret.

**Close the ports you are not using.** `ClickhouseSecurityGroup` opens 8123, 9000, 9009,
9181 and 9234 to the whole VPC. Every one of those is also covered by the rule that lets
the nodes talk to each other, and `kubectl port-forward` arrives through the kubelet, not
through them, so on this deployment they have no user. They exist for the case where an
application in another subnet needs to reach ClickHouse. If that is not happening, delete
them.

**Add a NetworkPolicy.** Nothing in these manifests limits which pods may talk to the
ClickHouse pods. On a cluster that runs other workloads, a policy on the `clickhouse`
namespace that admits only the namespaces that need the database is the standard behavior.
Note that the VPC CNI on EKS enforces NetworkPolicy only when that feature is switched on
for the cluster.

**Give the replicas a shared secret.** Replicas fetch data parts from each other over port
9009 and, by default, do not authenticate. `interserver_http_credentials` in the server
config, again from a Secret, means only a server holding the secret can make requests.

**Tighten the pods.** The containers start as root so that the ClickHouse entrypoint can
take ownership of the `hostPath` directories, and then drop to the `clickhouse` user. The
manifest sets no `securityContext`, so nothing drops capabilities or forbids privilege
escalation, and the service-account token is mounted into pods that never use it. Setting
`automountServiceAccountToken: false` and dropping capabilities costs nothing; running
non-root from the start needs an init container to do the chown first.

**Turn on the logs.** EKS control-plane logging, including the audit log, is off. Turning
it on is a property on the cluster resource and a CloudWatch bill.

## What is not here

No backups. Nothing ships parts to S3, and the ClickHouse `BACKUP` command is not wired to
anything.

No monitoring. There are no Prometheus rules, and nothing alerts on replication lag, disk
usage or a Keeper losing quorum. `system.replicas` and Keeper's `mntr` command, both shown
in `deploy.md`, are what you have.

No way in from the internet. The cluster is reachable by `kubectl port-forward` and by
workloads inside it.
