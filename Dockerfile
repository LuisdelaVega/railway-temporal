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

# Copy the server binary and its embedded config templates from the server image.
# The exact paths are stable across 1.2x releases; if a future upgrade moves
# them, you'll see the COPY fail at build time.
COPY --from=server /usr/local/bin/temporal-server /usr/local/bin/temporal-server
COPY --from=server /etc/temporal/config /etc/temporal/config

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