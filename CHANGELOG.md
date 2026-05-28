# Changelog

All notable changes to `pgCK` are logged here.

## v0.1.3 - 2026-05-28

### Added

- Ontology modules `ontology/task.ttl` and `ontology/goal.ttl` ship `ckp:TaskShape` and `ckp:GoalShape` with SHACL `sh:minCount=1` constraints on the link predicates `ckp:part_of_goal` and `ckp:target_kernel`, and on `rdfs:label` for Goals. Verified against pgRDF 0.5.1's native SHACL validator.
- Draft SQL upgrade script `sql/v0.2-drafts/pgck--0.1.2--0.2.0.sql` lays the foundation for the upcoming binary-wire and seal-time SHACL gate work: `ckp.dictionary` table + `ckp.dict_intern` allocator (per-project IRI → uint32 handles, with `pg_notify('ckp_dict_v_bumped', …)` for the bgworker to pump onto NATS), `ckp.urn_normalise` canonicalisation helper, `ckp.import_module(module, project)` loader for the split ontology modules, and `ckp.shapes_self_test(project)` self-test that guards `ckp.seal()` against stale ontology mounts. The Rust hooks (seal-time projection + SHACL gate, bgworker LISTEN/NATS publish) are not in this drop; they ship in subsequent v0.1.x releases.

### Changed

- Consolidated `web_demo/` into `web/` as the single source of truth for the web layer. The legacy v0.1.0 tree (FastAPI `display.py` / `tasks.py` / static HTML) is removed; the dual-page Display/Board re-architecture moves in. Imports, tests, `Justfile`, GitHub Actions workflow paths, and the `web/Dockerfile.pgck-web` build context all rewritten. `tests/test_web_demo.py` renamed to `tests/test_web.py`.
- `web/protocol.py` exposes both short-form (`event.pgCK.Display`) and long-form (`event.kernel.pgCK.Display.broadcast`) NATS subjects in the browser config so the next v1.3-aligned CKClient drop can opt into either.
- Web layer aligned to the CK.Lib.Js `CKClient` ESM module: `web/static/display-app.js` is now constructed against `CKClient` from `/cklib/ck-client.js` (v1.2-compatible; v1.3 alignment lands in pgck-web/v0.2.2). `web/app.py` mounts `/cklib` from `PGCK_CKLIB_DIR` (dev) or the OCI-bundle layout (prod) and exposes `/assets` alongside `/static` so the assets survive the localhost Envoy `/static/` prefix_rewrite.

### Verification

- `pgrdf.parse_turtle` against `ontology/task.ttl` → 28 triples; `ontology/goal.ttl` → 11 triples.
- `pgrdf.validate(data_g, shapes_g)` against a bad Task (no link predicates) → `conforms: false` with two `sh:MinCountConstraintComponent` results; against a good Task → `conforms: true`.
- `ckp.dict_intern` idempotent (same IRI → same handle); `ckp.urn_normalise('FC-T-0001 ')` → `'fc-t-0001'`; `CALL ckp.import_module('task','probe')` populates the project board graph; `ckp.shapes_self_test('probe')` passes.
- Playwright smoke against `https://pgck.localhost/` (TLS via Envoy): CKClient status reads "Subscribed to event.pgCK.Display"; published broadcast (`nats pub event.pgCK.Display '{"kind":"theme",…}'`) repaints the page in real time.

## v0.1.2 - 2026-05-24

### Added

- Shipped the aggregated browser and board runtime surface: `web/`, `examples/goal-task-board.kernel.ttl`, and pytest coverage for board payloads, gateway behavior, service behavior, and HTTP/UI endpoints.
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
- `pytest -q tests/test_board.py tests/test_gateway.py tests/test_service.py tests/test_web.py tests/test_nats_wss_hardening.py`
- `just build-ext`
- `POSTGRES_PORT=55432 just smoke-s4`
- `POSTGRES_PORT=55432 just smoke-s3`
- `just smoke-nats-wss`

## v0.1.1 - 2026-05-16

- Shipped the pod harness and ontology-load substrate release: stock Postgres compose runtime, `just pgrdf-fetch`, `just build-ext`, `just smoke-s5`, `ckp.boot()`, and `ckp.load_kernel()`.

## v0.1.0 - 2026-05-16

- Initial public release with the repository, CI/release pipeline, MIT licensing, `SELECT pgck_version()`, bootstrap SQL, and the CKP core ontology.
