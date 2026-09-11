# ClickHouse cluster — working notes

Notes for anyone, human or otherwise, changing files in this repository.

## Pinned versions

ClickHouse is 25.10, for both the server and Keeper, always the official images from
Docker Hub. It does not move without a deliberate decision, because `docker-compose.yml`
and the Kubernetes manifests both name it.

## Configuration

There is one copy of the ClickHouse and Keeper configuration, in `config/`, and both
docker-compose and Kubernetes read it. Do not add a second copy for one environment. If
something has to differ between the two, make it an environment variable read with
`from_env`, the way the hostnames already are.

## Schema

Never edit a SQL file that has run somewhere. Add a new numbered file. Every `CREATE` is
`ON CLUSTER main` and every table that should replicate is `ReplicatedMergeTree`.

## Tests

`tests/test-cluster.sh` must keep working against both docker-compose and a port-forwarded
Kubernetes cluster, which means it takes its addresses from the environment and depends on
nothing but `curl` and `bash`.

Do not swallow errors in the test. If something breaks we want to see it fail loudly.

## Makefiles

Use tab-indented lines, so that the default `make` on any machine can read them.
