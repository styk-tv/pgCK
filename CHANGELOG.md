# Changelog

All notable changes to `pgCK` are logged here.

## v0.1.2 - 2026-05-24

### Added

- Shipped the aggregated browser and board runtime surface: `web_demo/`, `examples/goal-task-board.kernel.ttl`, and pytest coverage for board payloads, gateway behavior, service behavior, and HTTP/UI endpoints.
- Added the local browser transport companion with `compose/compose.nats-wss.yml`, `compose/nats/nats-server.conf`, `scripts/generate-dev-certs.sh`, and the `just nats-wss-*` / `smoke-nats-wss` loop.
- Logged the release blockers in the internal `_WIP/` tracker and closed them as part of the release gate.

### Changed

- Consolidated the public runtime documentation surface into `README.md`, `RELEASE_NOTES.md`, and this changelog while retiring tracked draft material from the shipped repo surface.
- Landed the first split `ontology/*.ttl` modeling slices while keeping `ontology/core.ttl` as the runtime-authoritative ontology loaded by `ckp.boot()`.
- Pinned the web demo Python dependencies in `requirements.txt` and refreshed the verified-local release-prep date in the README.

### Fixed

- Issue 1: made the shipped proof surface honest and durable by aligning the ontology, SQL implementation, demo defaults, and tests on `hmac+sha256`, and by making `ckp.verify()` validate the durable proof and ledger state.
- Issue 2: made `ckp.validate()` concurrency-safe by replacing the shared random scratch graph pool with a backend-local scratch graph id.
- Issue 3: enforced the embedded NATS `max_payload` contract so oversized `PUB` frames are rejected before allocation, with server tests covering the limit behavior.
- Issue 4: aligned the demo runtime and README defaults on the shipped WSS/TCP ports and the documented Postgres port override.

### Verification

- `cargo test --no-default-features --features pg17,embedded-nats`
- `pytest -q tests/test_board.py tests/test_gateway.py tests/test_service.py tests/test_web_demo.py tests/test_nats_wss_hardening.py`
- `just build-ext`
- `POSTGRES_PORT=55432 just smoke-s4`
- `POSTGRES_PORT=55432 just smoke-s3`
- `just smoke-nats-wss`

## v0.1.1 - 2026-05-16

- Shipped the pod harness and ontology-load substrate release: stock Postgres compose runtime, `just pgrdf-fetch`, `just build-ext`, `just smoke-s5`, `ckp.boot()`, and `ckp.load_kernel()`.

## v0.1.0 - 2026-05-16

- Initial public release with the repository, CI/release pipeline, MIT licensing, `SELECT pgck_version()`, bootstrap SQL, and the CKP core ontology.
