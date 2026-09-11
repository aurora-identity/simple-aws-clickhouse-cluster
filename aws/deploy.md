# Deploying to AWS, step by step

Everything here runs from the `aws/` directory. You need the AWS CLI signed in as an
identity that can create IAM roles, `kubectl`, and Docker. Copy `.env.example` to `.env`
and fill in your region and account id.

## 1. Build the cluster

```bash
make plan
```

That first creates a small stack holding the IAM role CloudFormation will assume, then
produces a change set for the real stack and prints it. Read it. Nothing has been built
yet. When you are happy:

```bash
make apply
```

This takes ten to fifteen minutes, almost all of it EKS. When it returns you have a VPC,
three private subnets in three availability zones, a NAT gateway so the nodes can pull
images, an EKS cluster, two `m6i.large` nodes labelled `role=clickhouse` and three
`t3.medium` nodes labelled `role=keeper`.

## 2. Point kubectl at it

```bash
make kube
```

This assumes the deployment role, because whoever created an EKS cluster is its first
administrator and the cluster was created by that role. It prints the nodes with their
role and zone, which is the first place to look if something later does not schedule: you
should see two zones among the ClickHouse nodes and three among the Keeper nodes.

## 3. Deploy ClickHouse

```bash
make deploy
```

This builds three ConfigMaps from the `config/` directory at the root of the repository,
applies `kubernetes/clickhouse.yaml`, and waits for both StatefulSets to roll out. The
images are `clickhouse/clickhouse-server:25.10` and `clickhouse/clickhouse-keeper:25.10-alpine`
straight from Docker Hub, the same ones docker-compose runs. The end of the output lists
the pods with the node each landed on.

## 4. Apply the schema

```bash
make schema
```

This builds a ConfigMap from `schema/`, runs `schema/apply.sh` as a Job against replica 0,
and prints the Job's log. The statements are `ON CLUSTER`, so you will see both replicas
in the output.

## 5. Prove it

```bash
make test
```

This port-forwards both replicas to your machine and runs `tests/test-cluster.sh`, the
same script you ran against docker-compose. Ten green lines means a row written to either
replica arrives on the other and both replicas hold a Keeper session.

## Reaching it from your application

Inside the cluster, `clickhouse.clickhouse.svc.cluster.local` resolves to both replica
IPs and `clickhouse-0.clickhouse.clickhouse.svc.cluster.local` to one of them. Port 8123
is HTTP and 9000 is the native protocol. Writes can go to either replica; the table
replicates both ways.

From outside the cluster, there is nothing. No load balancer and no public endpoint are
created, on purpose. `kubectl port-forward` is how you reach it from your desk, and
whatever you put in front of it for real traffic is yours to add.

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

The new table on `clickhouse-1` then fetches everything from `clickhouse-0`. This is the
cost of the node-local storage choice and `README.md` in this directory says more about it.

## Tearing it down

```bash
make destroy
```

Kubernetes resources go first, then the stack, then the bootstrap role. The data on the
nodes goes with the nodes.
