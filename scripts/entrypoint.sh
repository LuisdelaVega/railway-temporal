#!/bin/sh
# Entrypoint for the Temporal server on Railway.
#
# On every boot we (idempotently):
#   1. wait for Postgres, run schema create/setup/update
#   2. wait for Elasticsearch, create the visibility index template + index
#   3. start the Temporal server in the background
#   4. wait for it to pass a health check, then create the default namespace
#   5. foreground the server so Railway sees the real process
#
# All steps are idempotent, so restarts and redeploys are safe.

set -eu
# pipefail isn't POSIX but admin-tools ships bash/dash with it; we rely on it
# so a failing command inside a pipe actually aborts the script.
# shellcheck disable=SC3040
(set -o pipefail 2>/dev/null) && set -o pipefail

# ---- Required env (fail loudly if missing) -----------------------------------
: "${POSTGRES_SEEDS:?POSTGRES_SEEDS is required (Postgres host)}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PWD:?POSTGRES_PWD is required}"
: "${ES_SEEDS:?ES_SEEDS is required (Elasticsearch host)}"
: "${TEMPORAL_NAMESPACE:?TEMPORAL_NAMESPACE is required}"

# ---- Defaults ----------------------------------------------------------------
DB_PORT="${DB_PORT:-5432}"
DBNAME="${DBNAME:-temporal}"
VISIBILITY_DBNAME="${VISIBILITY_DBNAME:-temporal_visibility}"

ES_SCHEME="${ES_SCHEME:-http}"
ES_PORT="${ES_PORT:-9200}"
ES_VERSION="${ES_VERSION:-v7}"
ES_VIS_INDEX="${ES_VIS_INDEX:-temporal_visibility_v1_prod}"
# Optional ES basic auth
ES_USER="${ES_USER:-}"
ES_PWD="${ES_PWD:-}"

TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-127.0.0.1:7233}"
NAMESPACE_RETENTION="${NAMESPACE_RETENTION:-30d}"

SCHEMA_DIR=/etc/temporal/schema/postgresql/v12
ES_TEMPLATE_FILE="/etc/temporal/schema/elasticsearch/visibility/index_template_${ES_VERSION}.json"

# ---- Small helpers -----------------------------------------------------------
log() { echo "[entrypoint] $*"; }

wait_for_tcp() {
  host="$1"; port="$2"; name="$3"
  log "Waiting for ${name} at ${host}:${port}..."
  i=0
  until nc -z -w 3 "${host}" "${port}" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "${i}" -ge 60 ]; then
      log "ERROR: ${name} not reachable at ${host}:${port} after 60 attempts"
      exit 1
    fi
    sleep 2
  done
  log "${name} is reachable"
}

es_curl() {
  # Adds auth flag only if ES_USER is set. $@ is the rest of the curl args.
  if [ -n "${ES_USER}" ]; then
    curl -sS -u "${ES_USER}:${ES_PWD}" "$@"
  else
    curl -sS "$@"
  fi
}

# ---- 1. Postgres: create DBs + run migrations --------------------------------
# Idempotency strategy: use `temporal-sql-tool ping` against each target DB.
# It exits 0 if the DB exists and is reachable, non-zero otherwise. This
# avoids depending on psql being installed.
pg_db_exists() {
  db="$1"
  temporal-sql-tool \
    --plugin postgres12 \
    --ep "${POSTGRES_SEEDS}" -p "${DB_PORT}" \
    -u "${POSTGRES_USER}" \
    --db "${db}" \
    ping >/dev/null 2>&1
}

setup_postgres() {
  wait_for_tcp "${POSTGRES_SEEDS}" "${DB_PORT}" "Postgres"

  # temporal-sql-tool reads the password from SQL_PASSWORD.
  export SQL_PASSWORD="${POSTGRES_PWD}"

  for db in "${DBNAME}" "${VISIBILITY_DBNAME}"; do
    if pg_db_exists "${db}"; then
      log "Database '${db}' already exists"
    else
      log "Creating database '${db}'..."
      # The database name is passed via the parent --db flag. The
      # `create-database` subcommand itself takes only --defaultdb (the
      # admin DB to connect to while issuing CREATE DATABASE).
      temporal-sql-tool \
        --plugin postgres12 \
        --ep "${POSTGRES_SEEDS}" -p "${DB_PORT}" \
        -u "${POSTGRES_USER}" \
        --db "${db}" \
        create-database

      log "Setting up initial schema version in '${db}'..."
      temporal-sql-tool \
        --plugin postgres12 \
        --ep "${POSTGRES_SEEDS}" -p "${DB_PORT}" \
        -u "${POSTGRES_USER}" \
        --db "${db}" \
        setup-schema -v 0.0
    fi
  done

  log "Running main schema migrations..."
  temporal-sql-tool \
    --plugin postgres12 \
    --ep "${POSTGRES_SEEDS}" -p "${DB_PORT}" \
    -u "${POSTGRES_USER}" \
    --db "${DBNAME}" \
    update-schema -d "${SCHEMA_DIR}/temporal/versioned"

  log "Running visibility schema migrations..."
  temporal-sql-tool \
    --plugin postgres12 \
    --ep "${POSTGRES_SEEDS}" -p "${DB_PORT}" \
    -u "${POSTGRES_USER}" \
    --db "${VISIBILITY_DBNAME}" \
    update-schema -d "${SCHEMA_DIR}/visibility/versioned"
}

# ---- 2. Elasticsearch: template + index --------------------------------------
setup_elasticsearch() {
  wait_for_tcp "${ES_SEEDS}" "${ES_PORT}" "Elasticsearch"

  log "Waiting for ES cluster health (yellow)..."
  i=0
  until es_curl -f "${ES_SCHEME}://${ES_SEEDS}:${ES_PORT}/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "${i}" -ge 60 ]; then
      log "ERROR: ES cluster never reached yellow"
      exit 1
    fi
    sleep 2
  done
  log "ES cluster is yellow/green"

  if [ ! -f "${ES_TEMPLATE_FILE}" ]; then
    log "ERROR: ES template file not found at ${ES_TEMPLATE_FILE}"
    exit 1
  fi

  log "Applying visibility index template..."
  es_curl -X PUT --fail \
    "${ES_SCHEME}://${ES_SEEDS}:${ES_PORT}/_template/temporal_visibility_v1_template" \
    -H 'Content-Type: application/json' \
    --data-binary "@${ES_TEMPLATE_FILE}" > /dev/null
  echo

  log "Ensuring index '${ES_VIS_INDEX}' exists..."
  if es_curl --head --fail "${ES_SCHEME}://${ES_SEEDS}:${ES_PORT}/${ES_VIS_INDEX}" >/dev/null 2>&1; then
    log "Index already exists, skipping creation"
  else
    es_curl -X PUT --fail "${ES_SCHEME}://${ES_SEEDS}:${ES_PORT}/${ES_VIS_INDEX}" > /dev/null
    echo
    log "Index created"
  fi
}

# ---- 3. Start Temporal server in the background -----------------------------
start_server() {
  log "Starting Temporal server..."
  # The upstream server image's default CMD is `temporal-server --env docker start`
  # which uses the embedded template driven by the env vars we're setting in
  # the Dockerfile. We invoke it directly here.
  temporal-server --env docker start &
  SERVER_PID=$!
  log "Server PID: ${SERVER_PID}"
}

# ---- 4. Wait for server health, then create namespace ------------------------
create_namespace() {
  log "Waiting for Temporal server to be healthy..."
  i=0
  until temporal operator cluster health --address "${TEMPORAL_ADDRESS}" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "${i}" -ge 60 ]; then
      log "ERROR: Temporal server never became healthy"
      kill "${SERVER_PID}" 2>/dev/null || true
      exit 1
    fi
    sleep 2
  done
  log "Server is healthy"

  if temporal operator namespace describe \
       --namespace "${TEMPORAL_NAMESPACE}" \
       --address "${TEMPORAL_ADDRESS}" >/dev/null 2>&1; then
    log "Namespace '${TEMPORAL_NAMESPACE}' already exists"
  else
    log "Creating namespace '${TEMPORAL_NAMESPACE}' with retention ${NAMESPACE_RETENTION}..."
    temporal operator namespace create \
      --namespace "${TEMPORAL_NAMESPACE}" \
      --retention "${NAMESPACE_RETENTION}" \
      --address "${TEMPORAL_ADDRESS}"
  fi
}

# ---- Main --------------------------------------------------------------------
setup_postgres
setup_elasticsearch
start_server
create_namespace

log "Bootstrap complete; tailing Temporal server (PID ${SERVER_PID})"
# Forward signals to the server and preserve its exit code.
trap 'kill -TERM "${SERVER_PID}" 2>/dev/null' TERM INT
wait "${SERVER_PID}"