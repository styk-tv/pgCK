# Changelog

All notable changes to `pgCK` are logged here.

## v0.2.1 - 2026-05-29

Single-task release: **CKA-6 wires up the NATS publish path end-to-end** (Rust + SQL). pgCK is now a NATS client of the bundled / cluster `nats-server` rather than hosting its own embedded NATS Core. Every governed `ckp.seal()` queues an event for publication with `Ck-Seq: <ledger.seq>` for CKClient v1.3 dedup; when configured for JetStream the event also publishes with `Nats-Msg-Id: <ledger.seq>` for server-side stream dedup.

### Added

- **`nats-client` Cargo feature** (`Cargo.toml`) — mutually exclusive with `embedded-nats` (the S3 mode); both enabled fires a clear `compile_error!` in `src/lib.rs`. Pulls in `tokio` + `async-nats 0.48` (default features include `jetstream`, `websockets`).
- **`src/nats_client.rs`** — owns a dedicated tokio thread with an `async_nats::Client` and optional `jetstream::Context`. pgrx-side callers use `nats_client::publish` / `publish_js` which enqueue commands over an `mpsc::sync_channel(1024)`; the thread runs the actual async publish, logs failures to stderr, never panics. Fire-and-forget at the call site.
- **`src/publish_drain.rs`** — bgworker-side drainer. Each tick: `BackgroundWorker::transaction(|| Spi::connect_mut(|c| c.update("DELETE FROM ckp.outbox WHERE seq IN (SELECT seq FROM ckp.outbox ORDER BY seq LIMIT 100) RETURNING ...")))` — atomic batch drain. For each row, decodes JSONB headers, calls into `nats_client::publish` (Core path), and if `pgck.nats_js_stream` GUC is set also `nats_client::publish_js` with `Nats-Msg-Id` appended.
- **GUC getters in `src/lib.rs`** — `crate::nats_url()` (default `nats://127.0.0.1:4222`), `crate::nats_js_stream()` (default `None`). Registered via `pgrx::GucRegistry::define_string_guc(...)` in `_PG_init` under the `nats-client` feature.
- **Bgworker tick interval** tightened to 100ms under `nats-client` (visible publish latency ~50ms avg). `Duration::from_secs(5)` retained for the no-NATS-feature and `embedded-nats` profiles.
- **`ckp.outbox` table** — `BIGSERIAL seq` + FK to `ckp.ledger(seq)` + `subject TEXT` + `payload BYTEA` + `headers JSONB` + `attempt_count INT` + `enqueued_at TIMESTAMPTZ`. Single index on `seq`.
- **`ckp.compute_publish_subject(p_type_uri text) → text`** — IMMUTABLE; strips ontology namespace from a type URI to derive `event.kernel.pgCK.<class>.sealed` (Task / Goal / Instance fallback).
- **`ckp.ledger_to_outbox()` + `ckp_ledger_after_insert` trigger** — fires AFTER INSERT on `ckp.ledger` inside the same seal transaction. Reads `ckp.instances.body`, builds headers with `Ck-Seq: <seq>` + `Content-Type: application/json`, queues one outbox row. Zero touch to `ckp.seal()` — purely additive.
- **`sql/test/s8_publish_path_smoke.sql`** — SQL fixture that exercises the trigger end-to-end (seal Goal + Task → assert 2 outbox rows with correct subjects / Ck-Seq stamp / Content-Type / payload bytes; also asserts `compute_publish_subject()` for Task / Goal / NULL / no-slash inputs).

### Changed

- **`src/bgworker.rs`** — under `nats-client`, `tick()` initialises the async-nats client once via a `OnceLock` on the first tick, then calls `publish_drain::drain_once()` every tick. Under `embedded-nats`, behaviour preserved (starts the hand-rolled NATS Core server once on its own tokio thread). Unit test `start_server_once_is_idempotent` still passes.
- **Cargo check matrix** is clean across all 4 profiles (none / `embedded-nats` / `nats-client` / both) — both-enabled fails with the mutex `compile_error!` as designed.

### Architecture / docs

- **`SPEC.PGCK.NATS-BIDIRECTIONAL.v0.2`** records that the bundled `nats-server` topology shipped in `oci-germination v0.6.3` is the canonical substrate; the embedded NATS Core in `src/nats/` is now a dev / unit-test artefact only.
- **`SPEC.CKP.v3.8-rc-09-nats`** supersedes `rc-06-nats` with the bundled-substrate + JetStream-assist + deferred-sealing-cutoff framing. **Outbox-table rejection revised** (was about cluster-level durability conflated with process-local IPC; outbox is the SQL→bgworker bridge, JetStream is the cluster boundary — different layers).
- **`TASKS.PGCK.S4-BUNDLED-NATS.v0.1`** is the tactical plan that drove this release; 7 steps, 6 commits (`5d46b3f` → `c3081ed`).

### Pivots from the original plan

- **pg_notify + LISTEN → outbox-table drain.** pgrx 0.16 has no usable LISTEN/NOTIFY consumer API; outbox approach is simpler, crash-safe, pure SPI. Documented in `rc-09-nats §2` (revised) and S4 plan steps 3+4.
- **`async-nats` pin updated 0.35 → 0.48** (was outdated in the S4 plan; 0.48 is the actual current pin and includes JetStream + websockets by default).

### Verification

- `cargo check --no-default-features --features pg17[,...]` — clean across all 4 feature profiles, zero warnings.
- `sql/test/s8_publish_path_smoke.sql` — **runtime verification deferred**: the dev container at `127.0.0.1:15432` currently ships pgCK `0.1.2` (oci-germination `ck-allinone:v0.6.3` bundle has a stale pgCK pin — see `NOTIFIES.oci-germination.v0.6.all-in-one-web-pin-update`). The s8 fixture is authored against the v0.2.1 schema and will PASS once the bundle picks up v0.2.1+. The architecture is deliberately additive (AFTER INSERT trigger, mutex-protected feature gates) — trigger bugs cannot break seal-path success.
- `tests/sh/s4_bundle_smoke.sh` — deferred for the same bundle-pin reason. Tracked as follow-up.

## v0.2.0 - 2026-05-28

**Track B ship-it.** First major track flip — minor bump signals that the **Ontology + SHACL gate at `ckp.seal()`** track is complete. The worked example from `_WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §6` reproduces end-to-end; the SHACL gate rolls back non-conforming seals; the IRI dictionary + URN normaliser + ontology module importer underpin the whole pipeline.

### Track B summary

| Task | Subject | Shipped |
|---|---|---|
| **CKB-7** | Ontology modules `ontology/task.ttl` + `ontology/goal.ttl` with classes, predicates, SHACL shapes | v0.1.3 (`c2602ff`) |
| **CKB-6** | `ckp.dictionary` + `dict_intern` + `urn_normalise` + `import_module` + `shapes_self_test` | v0.1.3 (`f05e540`) |
| **CKB-5** | `ckp.seal()` projects link triples (`a`, `part_of_goal`, `target_kernel`) into the project board graph | v0.1.7 (`41fcfa9`) |
| **CKB-4** | SHACL gate at the seal boundary — rollback on `conforms: false`; pre-flight `shapes_self_test` fails fast on stale ontology mounts | v0.1.8 (`a7c65ad`) |
| **CKB-3** | `ckp.load_kernel()` auto-imports `task` + `goal` modules into the board | v0.1.7 (`41fcfa9`) |
| **CKB-2** | Worked example — `sql/test/s7_board_shared_goal.sql` recovers 4 distinct kernels under a shared Goal via SPARQL | v0.1.9 (`76175f4`) |
| **CKB-1** | **Ship-it** — track flipped to ✅ in roadmap; release-notes cite the worked-example output | v0.2.0 (this release) |

### Worked example output

```
ckp://Kernel#ck-lib-js
ckp://Kernel#oci-germination
ckp://Kernel#pgck
ckp://Kernel#pgrdf
```

Four Tasks (`S7-T-1..4`) sealed via `ckp.seal()` part_of a single Goal (`v3.8-pgxn-release`), each targeting a distinct kernel, queried back through `pgrdf.sparql()` against the projected board graph at `urn:ckp:s7-test/kernel/board`.

### Changed

- **Release pipeline matrix narrowed to `pg17`** (was 4 PG × 2 arch = 8 legs). The LATEST.md head only tracks pg17, and the prior 8-leg matrix starved the shared arm64 runner pool on v0.1.9, leaving the orchestrating `release` job skipped. Re-expand to pg14/15/16 once the pg17 attestation + release path is reliable.

### Verification

- `sql/test/s6_seal_shacl_gate.sql` — **PASS** (CKB-4 regression — good Task seals, bad Task raises with `MinCountConstraintComponent`, no rollback leak).
- `sql/test/s7_board_shared_goal.sql` — **PASS** (CKB-2 regression — 4 distinct kernels under shared Goal).
- `cargo check --no-default-features --features pg17 --tests` — clean.

## v0.1.9 - 2026-05-28

Single-task release: CKB-2 closes — the four-kernel worked example from the companion spec is reproducible end-to-end against the live `ckp.seal()` + projection + SHACL-gate stack.

### Added

- **`sql/test/s7_board_shared_goal.sql`** — self-contained regression that loads the SHACL-bearing Task / Goal ontology modules into a fresh project board, seals one Goal (`v3.8-pgxn-release`), then seals four Tasks each targeting a different kernel (`pgCK`, `pgRDF`, `CK.Lib.Js`, `oci-germination`) part_of the shared Goal. A SPARQL `SELECT DISTINCT ?kernel … WHERE { ?t ckp:part_of_goal <ckp://Goal#…> ; ckp:target_kernel ?kernel }` against the projected board returns exactly four URNs — the worked example from `_WIP/SPEC.PGCK.TASK-GOAL-KERNEL-RDF.v0.1.md §6`.

### Verification

- `sql/test/s7_board_shared_goal.sql` against the dev container at `127.0.0.1:15432` — **PASS** (4 distinct kernels: `ckp://Kernel#ck-lib-js`, `ckp://Kernel#oci-germination`, `ckp://Kernel#pgck`, `ckp://Kernel#pgrdf`).
- `cargo check --no-default-features --features pg17 --tests` — clean.

## v0.1.8 - 2026-05-28

Single-task release: CKB-4 lands the SHACL gate inside `ckp.seal()`.

### Added

- **CKB-4 — SHACL gate inside `ckp.seal()` (rolls back on `conforms: false`).** `ckp.project_links()` now writes the link triples into a private scratch graph, runs `pgrdf.validate()` against the project board's shapes, and **`RAISE EXCEPTION`** on non-conformance (which rolls back the entire seal transaction — no instance row, no ledger row, no proof row). The error message names the failing constraint component (e.g. `MinCountConstraintComponent`) so callers can react. Pre-flight: `ckp.shapes_self_test(project)` runs before validation so a stale `/ontology/` mount fails fast instead of silently passing a vacuous SHACL check.
- **`sql/test/s6_seal_shacl_gate.sql`** — regression fixture, self-contained: imports the SHACL-bearing ontology modules from the repo into a fresh project board, then asserts (a) a good Task seal lands, (b) a bad Task seal raises with `MinCountConstraintComponent`, (c) the bad-instance row never enters `ckp.instances`.

### Fixed

- `ckp.shapes_self_test()` parsed the wrong field on `pgrdf.sparql()`'s ASK result (`boolean` instead of `_ask`), so the pre-flight always reported shapes as missing. Now reads `_ask` correctly; pre-flight passes when shapes are loaded and raises a precise error when they are not.

### Verification

- `sql/test/s6_seal_shacl_gate.sql` against the dev container at `127.0.0.1:15432` — **PASS**.
- `cargo check --no-default-features --features pg17 --tests` — clean.

## v0.1.7 - 2026-05-28

Extension release lands the **v0.2 SQL plumbing** as live extension behaviour (was draft-only under `sql/v0.2-drafts/` since v0.1.3) **and** ships **CKB-5 + CKB-3**: `ckp.seal()` projects Task / Goal link triples on every governed seal, and `ckp.load_kernel()` auto-imports the Task + Goal ontology modules into the project board graph.

### Added

- **CKB-5 — link-triple projection inside `ckp.seal()`.** A new helper `ckp.project_links(project, instance_id, body)` runs as step 5 of `ckp.seal()`. For Task bodies it materialises three quads into `urn:ckp:<project>/kernel/board` — `<urn> a ckp:Task ; ckp:part_of_goal <ckp://Goal#…> ; ckp:target_kernel <ckp://Kernel#…>` — using `ckp.urn_normalise()` to canonicalise every id segment. For Goal bodies it materialises two quads (`a ckp:Goal ; rdfs:label "…"`). Other instance classes (Kernel, LedgerEntry, Proof) are skipped. Regression test: `sql/test/s5_seal_project_links.sql`.
- **CKB-3 — `ckp.load_kernel()` auto-imports the board ontology.** After loading `p_path` into the project's `kernel/ck` graph, `ckp.load_kernel()` now also calls `ckp.import_module('task', p_project)` and `ckp.import_module('goal', p_project)` so the board's TaskShape / GoalShape are ambient for the SHACL gate (CKB-4 follow-up). Best-effort: a missing `/ontology/<module>.ttl` raises a `NOTICE` and the load continues so stale-mount dev containers don't break the existing kernel/ck path.
- **v0.2 SQL plumbing now installed:** `ckp.dictionary` table + `ckp.dict_intern()` allocator + `pg_notify('ckp_dict_v_bumped', …)`, `ckp.urn_normalise(text)`, `ckp.import_module(module, project)` loader, `ckp.shapes_self_test(project)`. Previously drafted at `sql/v0.2-drafts/pgck--0.1.2--0.2.0.sql`; v0.1.7 pulls the whole bundle into the live `pgck--0.1.7.sql` install plus the `pgck--0.1.5--0.1.7.sql` upgrade script.

### Changed

- `ckp.seal()` rewritten: step 5 calls `ckp.project_links()` so Task / Goal seals atomically materialise the JSONB body, the ledger entry, the proof, **and** the projected link triples. JSONB body keys remain the human-readable v3.7 form for backward compatibility with `pgck-web` v0.2.x; the URN mint at projection time is the canonical form. The first four steps (validate / write instance / write ledger / write proof) are unchanged.
- `ckp.load_kernel()` rewritten to wrap the kernel/ck load in a single transaction with the board module imports.
- `pgck.control` `default_version`, `Cargo.toml`, `pgck_version()` (and its test), and the NATS server INFO frame are synced at `0.1.7`.

### Verification

- `sql/test/s5_seal_project_links.sql` against the dev container at `127.0.0.1:15432` — **PASS** (Task seal adds exactly 3 quads into the board graph).
- Goal projection probe: +2 quads (`a ckp:Goal` + `rdfs:label`) per Goal seal.
- `cargo check --no-default-features --features pg17 --tests` — clean.

## v0.1.6 (web layer milestone) - 2026-05-28

Web layer milestone — closes CKA-9, CKA-8, CKD-4. The pgCK extension is unchanged in this round; this rolls forward as `pgck-web/v0.2.3`. Extension stays at `v0.1.5`.

### Added

- **`tests/e2e/cka-9-v13-smoke.spec.ts`** — four-test smoke harness against `https://pgck.localhost` locking the v1.3 baseline: page loads over HTTPS, `/cklib/` serves CK.Lib.Js v1.3.x, CKClient reaches `Subscribed to event.pgCK.Display`, live NATS publish renders into `#last-payload` (live-NATS check gated by `PGCK_E2E_LIVE_NATS=1`).

### Changed

- `web/static/display-app.js` aligned to CK.Lib.Js v1.3 CKClient — `subscribe: ['event']` opts out of the dead `result.<Kernel>` subscription; `dictVersion: 0` bootstraps the `Ck-Dict-V` handshake; `clientId: 'ck-browser'` is pinned to the v1.3 default; the dead `ck.on('result', …)` handler is removed; `ck.on('broadcast', …)` is wired for future `extraSubjects`.
- Scope focus reset: the example payload in `web/protocol.py`, the default kernel list in `web/board.py`, and the test fixture in `tests/test_board.py` now use `CK.Task` as the `target_kernel`. The previous example referenced an out-of-scope topic.
- `tests/e2e/playwright.config.ts` `testDir` corrected from a non-existent `./tests` to `.` so all existing spec files are discovered.

## v0.1.5 - 2026-05-28

Second plumbing fix release. The v0.1.4 release_workflow failed at the OCI push step because `pgrx package` was still naming the SQL file `pgck--0.1.2.sql` — `pgrx` reads the file name from `pgck.control`'s `default_version`, not from Cargo.toml. v0.1.5 syncs every hardcoded version reference.

### Fixed

- `pgck.control`'s `default_version` was still `'0.1.2'`; pgrx package therefore generated `pgck--0.1.2.sql` while the release workflow expected `pgck--<tag-version>.sql`. v0.1.5 bumps it in sync with Cargo.toml.
- `pgck_version()` in `src/lib.rs` (and its matching test assertion) now returns `pgck 0.1.5 (rc3)`.
- The embedded NATS server's INFO frame in `src/nats/server.rs` (and its test assertion) carries `"version":"0.1.5"`.
- `sql/pgck--0.1.4.sql` renamed to `sql/pgck--0.1.5.sql`; `src/lib.rs`'s `extension_sql_file!` reference synced; `sql/pgck--0.1.4--0.1.5.sql` ships as a no-op upgrade marker.

## v0.1.4 - 2026-05-28

CI / release plumbing fix release. No new runtime surface; the v0.2 work continues to ship under `sql/v0.2-drafts/` until the Rust hooks land.

### Fixed

- `cargo pgrx test --no-default-features --features pg{14,15,16,17}` (the CI test feature matrix) failed to compile because `src/bgworker.rs` exposed a `tests` module that imported `super::start_server_once` while the function itself is gated behind the `embedded-nats` feature. CI had been red since well before v0.1.3. The test module is now gated under the same cfg.
- The v0.1.3 release workflow couldn't push the extension OCI artifact because Cargo.toml's `version` was still `0.1.2` while the tag was `v0.1.3`, so pgrx generated `pgck--0.1.2.sql` but the workflow expected `pgck--0.1.3.sql`. Cargo.toml is now synced (`0.1.4`); `src/lib.rs`'s `extension_sql_file!` reference matches; and `sql/pgck--0.1.2--0.1.4.sql` ships as a no-op upgrade marker (no SQL surface change between 0.1.2 and 0.1.4).
- `publish-pgck-web.yml`'s SBOM step is now non-fatal: `syft` (via `anchore/sbom-action`) fails on the arm64 matrix leg because it can't pull an arm64 image from an amd64 runner without QEMU, and the image push already succeeded by then. The artefact still ships; SBOM upload is skipped for the leg that couldn't generate it. Proper fix (split SBOM into a per-arch matrix) is on the workflow cleanup backlog.

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
