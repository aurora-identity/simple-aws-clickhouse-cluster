# ClickHouse cluster — working notes

Notes for anyone, human or otherwise, changing files in this repository.

## Pinned versions

ClickHouse is 25.10, for both the server and Keeper, always the official images from
Docker Hub. It does not move without a deliberate decision, because the manifests name it.

## One manifest

`kubernetes/clickhouse.yaml` runs on kind and on EKS without change, and that is the point
of the repository. Do not add anything to it that only one of the two needs. What differs
between the two lives in the cluster underneath: the node labels and taints, which
`kubernetes/kind.yaml` sets locally and CloudFormation sets on AWS. If the manifest needs
something new from the nodes, add it to both of those.

## Configuration

There is one copy of the ClickHouse and Keeper configuration, in `config/`. If something
has to vary between clusters, make it an environment variable read with `from_env`, set
from the manifest, the way the hostnames already are.

## Schema

Never edit a SQL file that has run somewhere. Add a new numbered file. Every `CREATE` is
`ON CLUSTER main` and every table that should replicate is `ReplicatedMergeTree`.

## Tests

`tests/test-cluster.sh` takes its addresses from the environment and depends on nothing
but `curl` and `bash`, so that `make test` is the same command locally and on AWS.

Do not swallow errors in the test. If something breaks we want to see it fail loudly.

## Makefile

Use tab-indented lines, so that the default `make` on any machine can read them. Targets
that act on a cluster act on whatever `kubectl` points at; only `local-up` and `aws-kube`
change that.
