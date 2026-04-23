# Temporal server image for Railway.
#
# We base on temporalio/admin-tools (which has temporal-sql-tool, the `temporal`
# CLI, curl, nc, and a full shell) and copy the server binary in from
# temporalio/server. This lets a single container bootstrap the schema, create
# the namespace, and then run the server -- avoiding the docker-compose pattern
# of init containers, which Railway does not support cleanly.
#
# Keep the two ARG versions in lockstep; they should always match.

ARG TEMPORAL_VERSION=1.29.4

FROM temporalio/server:${TEMPORAL_VERSION} AS server

FROM temporalio/admin-tools:${TEMPORAL_VERSION}

# Copy the server binary, its embedded config template, and `dockerize`
# from the server image.
# - config_template.yaml (not docker.yaml) is what ships; the upstream
#   entrypoint renders it to docker.yaml at runtime via `dockerize`.
# - dockerize is a small Go binary that does Go-template substitution of
#   env vars. We need it because admin-tools doesn't include it.
COPY --from=server /usr/local/bin/temporal-server /usr/local/bin/temporal-server
COPY --from=server /usr/local/bin/dockerize /usr/local/bin/dockerize
COPY --from=server /etc/temporal/config /etc/temporal/config

# Admin-tools runs as UID 1000 (non-root). The COPY above lands files as root,
# so the runtime user can't write `docker.yaml` into /etc/temporal/config when
# dockerize renders the template. Give the temporal user ownership.
USER root
RUN chown -R 1000:1000 /etc/temporal/config
USER 1000

# Our production dynamic config.
COPY config/production.yaml /etc/temporal/config/dynamicconfig/production.yaml

# Bootstrap + run entrypoint.
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# The server resolves --env docker -> config/docker.yaml relative to cwd.
# The upstream server image sets its WORKDIR to /etc/temporal; admin-tools
# does not, so we set it here explicitly. Without this the server exits with
# "no config files found within config".
WORKDIR /etc/temporal

# Tell the server to use our dynamic config. Every other knob
# (DB, ES, visibility backend) is driven by env vars that the embedded
# docker.yaml template reads -- we set those in Railway, not here.
ENV DYNAMIC_CONFIG_FILE_PATH=config/dynamicconfig/production.yaml

EXPOSE 7233

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]