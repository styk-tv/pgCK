# syntax=docker/dockerfile:1.4
# 1.97 = rust-toolchain.toml's pin (its comment binds them: "Matches the
# builder image"). A mismatched base makes rustup re-download the pinned
# toolchain inside /work every build and runs the cargo-install layer under a
# different compiler than the package layer.
FROM docker.io/library/rust:1.97-bookworm AS builder
ARG PG_MAJOR=18
# NATS profile: embedded-nats (compose dev — pgCK hosts its own NATS) or
# nats-client (bundle/cluster — pgCK is a client of a separate nats-server,
# e.g. ck-allinone). Mutually exclusive; pick one. Default keeps compose intact.
ARG NATS_FEATURE=embedded-nats
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
# cargo-pgrx MUST equal the crate's RESOLVED pgrx version ("cargo-pgrx and
# pgrx library versions must be identical") — derived from Cargo.lock, per
# SPEC.RUST-BUILDER.CK.v3.11: the builder reads the resolved pgrx from the
# caller, never pins its own. The previous hardcoded ARG drifted (0.16 vs the
# crate's 0.19.2 after #45) and broke build-ext on main; a derived version
# cannot drift. Exact (=), not caret: a ^-installed newer CLI would mismatch
# the committed lock the same way.
COPY Cargo.lock /tmp/Cargo.lock
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    ver=$(awk '$0=="name = \"pgrx\"" {getline; sub(/version = "/,""); sub(/"$/,""); print; exit}' /tmp/Cargo.lock) && \
    cargo install cargo-pgrx --locked --version "=${ver}"
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    cargo pgrx init --pg${PG_MAJOR} "$(which pg_config)"
WORKDIR /work
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/work/target,sharing=locked \
    cargo pgrx package --no-default-features --features pg${PG_MAJOR},${NATS_FEATURE} \
      --pg-config "$(which pg_config)" && \
    mkdir -p /artifacts/lib /artifacts/share/extension && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/lib/postgresql/${PG_MAJOR}/lib/pgck.so /artifacts/lib/ && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/pgck.control /artifacts/share/extension/ && \
    cp /work/target/release/pgck-pg${PG_MAJOR}/usr/share/postgresql/${PG_MAJOR}/extension/*.sql /artifacts/share/extension/
FROM debian:bookworm-slim AS export
COPY --from=builder /artifacts/lib/pgck.so /out/lib/pgck.so
COPY --from=builder /artifacts/share/extension/ /out/share/extension/
CMD ["sh", "-c", "cp -r /out/* /export/ && ls -laR /export"]
