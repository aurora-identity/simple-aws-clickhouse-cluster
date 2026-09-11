# Deploying to AWS, step by step

Everything here runs from the root of the repository. You need the AWS CLI signed in as
an identity that can create IAM roles, and `kubectl`. Copy `.env.example` to `.env` and
set your region.

The Kubernetes API will accept connections only from the public address you run
`make aws-plan` from. If you will use `kubectl` from somewhere else too, set
`API_ALLOWED_CIDRS` in `.env` to the full list before you plan.

## 1. Build the cluster

```bash
make aws-plan
```

That first creates a small stack holding the IAM role CloudFormation will assume, then
produces a change set for the real stack and prints it. Read it and when you are happy:

```bash
make aws-apply
```

This takes ten to fifteen minutes, almost all of it EKS. When it returns you have a VPC,
three private subnets in three availability zones, a NAT gateway so the nodes can pull
images, an EKS cluster, two `m6i.large` nodes labelled `role=clickhouse` and three
`t3.medium` nodes labelled `role=keeper`.

## 2. Point kubectl at it

```bash
make aws-kube
```

This assumes the deployment role, because whoever created an EKS cluster is its first
administrator and the cluster was created by that role. It prints the nodes with their
role and zone, which is the first place to look if something later does not schedule: you
should see two zones among the ClickHouse nodes and three among the Keeper nodes.

## 3. Deploy, apply the schema, prove it

From here on it is the same three commands as on your laptop, because `kubectl` now
points at EKS and nothing in the manifest knows the difference.

```bash
make deploy
make schema
make test
```

`deploy` builds three ConfigMaps from `config/`, applies `kubernetes/clickhouse.yaml`,
and waits for both StatefulSets to roll out. `schema` runs `schema/apply.sh` as a Job
against replica 0 and prints its log; the statements are `ON CLUSTER`, so you will see
both replicas in it. `test` port-forwards both replicas and runs `tests/test-cluster.sh`;
ten green lines means a row written to either replica arrives on the other and both
replicas hold a Keeper session.

## Reaching it from your application

Inside the cluster, `clickhouse.clickhouse.svc.cluster.local` resolves to both replica
IPs and `clickhouse-0.clickhouse.clickhouse.svc.cluster.local` to one of them. Port 8123
is HTTP and 9000 is the native protocol. Writes can go to either replica; the table
replicates both ways.

From outside the cluster, there is nothing. No load balancer and no public endpoint are
created. `kubectl port-forward` is how you reach it from your machine.

## Looking around

```bash
kubectl get pods -n clickhouse -o wide
kubectl logs -n clickhouse clickhouse-0 -f
kubectl logs -n clickhouse keeper-0 -f
kubectl exec -n clickhouse clickhouse-0 -- clickhouse-client -q "SELECT * FROM system.replicas FORMAT Vertical"
kubectl exec -n clickhouse clickhouse-0 -- clickhouse-client -q "SELECT * FROM system.zookeeper_connection"
kubectl exec -n clickhouse keeper-0 -- sh -c 'echo mntr | nc localhost 9181'
```

The `mntr` line shows `zk_server_state` as `leader` on one Keeper and `follower` on the
other two. The `system.replicas` query shows `is_readonly` as 0 and `active_replicas` as
2 on a healthy table.

To get a shell on a node, use SSM rather than SSH; there is no SSH key and port 22 is not
open:

```bash
aws ssm start-session --region $AWS_REGION --target <instance-id>
```

## When a replica comes back empty

Storage is a directory on the node's own disk. If a node is replaced, the pod that lands on
its replacement starts with an empty directory and, because table metadata lives there too,
with no tables. Keeper still remembers the replica, so re-running the schema fails with
`REPLICA_ALREADY_EXISTS`. Tell Keeper to forget the old copy, then recreate:

```bash
kubectl exec -n clickhouse clickhouse-0 -- clickhouse-client -q \
  "SYSTEM DROP REPLICA 'clickhouse-1' FROM TABLE events"
make schema
```

The new table on `clickhouse-1` then fetches everything from `clickhouse-0`.

## Tearing it down

```bash
make aws-destroy
```

Kubernetes resources go first, then the stack, then the bootstrap role. The data on the
nodes goes with the nodes.
