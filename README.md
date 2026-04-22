# temporal-railway

Temporal server image designed to run as a single service on Railway.

## What this repo is

A thin wrapper around `temporalio/server` that folds the bootstrap work
(Postgres schema migrations, Elasticsearch index creation, default-namespace
creation) into the server's own entrypoint. The upstream docker-compose setup
uses separate init containers for these steps, which doesn't map onto
Railway's service model — hence this image.

## Architecture: why each file exists

- **`Dockerfile`** — Bases on `temporalio/admin-tools` (which has
  `temporal-sql-tool`, the `temporal` CLI, `curl`, and `nc`) and copies the
  `temporal-server` binary in from `temporalio/server`. Both images are pinned
  to the same `TEMPORAL_VERSION` build arg; keep them in lockstep.

- **`scripts/entrypoint.sh`** — On every boot, idempotently: waits for
  Postgres, runs schema create + migrate for the `temporal` and
  `temporal_visibility` databases, waits for Elasticsearch, applies the
  visibility index template and index, starts the server in the background,
  waits for it to go healthy, creates the default namespace if missing, then
  foregrounds the server. Restarts and redeploys are safe.

- **`config/production.yaml`** — Dynamic config baked into the image. Contains
  only `limit.maxIDLength: 255`. Intentionally does NOT include
  `system.forceSearchAttributesCacheRefreshOnRead`, which the upstream
  `development-sql.yaml` enables and which is explicitly marked dev-only.

## Required environment variables on Railway

Use Railway variable references (`${{ServiceName.VAR}}`) wherever possible so
rotations propagate automatically.

### Postgres (managed)

| Var                 | Set to                          |
| ------------------- | ------------------------------- |
| `POSTGRES_SEEDS`    | `${{Postgres.PGHOST}}`          |
| `DB_PORT`           | `${{Postgres.PGPORT}}`          |
| `POSTGRES_USER`     | `${{Postgres.PGUSER}}`          |
| `POSTGRES_PWD`      | `${{Postgres.PGPASSWORD}}`      |
| `SQL_TLS_ENABLED`   | `true`                          |
| `DBNAME`            | `temporal` (default, can omit)  |
| `VISIBILITY_DBNAME` | `temporal_visibility` (default) |

> Railway's managed Postgres requires TLS. The embedded docker config reads
> `SQL_TLS_ENABLED` and wires it through to both persistence and visibility.

### Elasticsearch (your existing service)

Created using:

| Var            | Set to                                      |
| -------------- | ------------------------------------------- |
| `ENABLE_ES`    | `true`                                      |
| `ES_SEEDS`     | `${{Elasticsearch.RAILWAY_PRIVATE_DOMAIN}}` |
| `ES_PORT`      | `9200`                                      |
| `ES_SCHEME`    | `http`                                      |
| `ES_VERSION`   | `v7` (Elasticsearch 7.x) or `v8` (ES 8.x)   |
| `ES_VIS_INDEX` | `temporal_visibility_v1_prod`               |
| `ES_USER`      | _(optional)_ elastic user for writes        |
| `ES_PWD`       | _(optional)_ password                       |

> The `anonymous_role` in the ES image grants `monitor` only — enough for
> health checks, not for writes. You must provide a user with write access
> on the visibility index (a dedicated `temporal_writer` role is ideal) or
> broaden the anonymous role. See the ES deployment notes.

### Namespace / server

| Var                          | Set to                                 |
| ---------------------------- | -------------------------------------- |
| `TEMPORAL_NAMESPACE`         | e.g. `default` or your app's namespace |
| `NAMESPACE_RETENTION`        | e.g. `30d` (default)                   |
| `BIND_ON_IP`                 | `0.0.0.0`                              |
| `TEMPORAL_BROADCAST_ADDRESS` | `${{RAILWAY_PRIVATE_DOMAIN}}`          |

## Building locally

```sh
docker build -t temporal-railway .

# Override server version at build time:
docker build --build-arg TEMPORAL_VERSION=1.29.4 -t temporal-railway .
```

## Version upgrades

Bump `ARG TEMPORAL_VERSION` in the `Dockerfile`. The admin-tools and server
images publish matching tags for every release, so a single arg updates both.
Before upgrading across minor/major versions, consult the upstream release
notes at https://github.com/temporalio/temporal/releases — schema changes
often require running the migration on a staged environment first.
