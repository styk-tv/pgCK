# syntax=docker/dockerfile:1.4
FROM docker.io/library/rust:1.91-bookworm AS builder
ARG PG_MAJOR=17
ARG PGRX_VERSION=0.16
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg \
      lsb-release build-essential pkg-config libssl-dev libclang-dev && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      postgresql-server-dev-${PG_MAJOR} postgresql-${PG_MAJOR} sudo
ENV PGRX_HOME=/opt/pgrx
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    cargo install cargo-pgrx --locked --version "^${PGRX_VERSION}"
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    cargo pgrx init --pg${PG_MAJOR} "$(which pg_config)"
WORKDIR /work
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/work/target,sharing=locked \
    cargo pgrx package --no-default-features --features pg${PG_MAJOR},embedded-nats \
      --pg-config "$(which pg_config)" && \
    mkdir -p /artifacts/lib /artifacts/share/extension && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/lib/postgresql/${PG_MAJOR}/lib/pgck.so /artifacts/lib/ && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/pgck.control /artifacts/share/extension/ && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/*.sql /artifacts/share/extension/
FROM debian:bookworm-slim AS export
COPY --from=builder /artifacts/lib/pgck.so /out/lib/pgck.so
COPY --from=builder /artifacts/share/extension/ /out/share/extension/
CMD ["sh", "-c", "cp -r /out/* /export/ && ls -laR /export"]
