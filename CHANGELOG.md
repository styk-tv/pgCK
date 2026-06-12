# Changelog

All notable changes to `pgCK` are logged here.

## v0.4.7 - 2026-06-12

**Tier 2 (3/3b) — governed query affordances (the §6.3 `concept.match` form).** A kernel can now
declare a parameterized SPARQL query through the **governance plane** and expose it as a verb; callers
bind typed parameters only and never see or alter the query text. This completes Tier 2 and makes the
previously-vestigial plan compiler load-bearing.

- **Declare + seal:** `kernel.propose_change` op `add_affordance` with `detail:{verb, query, params:[…]}`
  → `vote` → `apply`. The query text is sealed as a governance fact with a full proposal→applied proof chain.
- **`ckp.register_query_affordance`** (at `apply`): compiles the sealed query into `ckp.plans` keyed by
  `(kernel, verb, epoch)` — exactly §5.3's "compiled query templates" — and adds a `plane='query'`
  `affordance_registry` row. Verb + param **names** are gated at registration.
- **`ckp.run_query_affordance`** (at dispatch, `plane='query'`): validates the caller's param **values**
  (no quote/brace/backslash/`?`-var can pass) and binds them into the author's `$name$` placeholders, then
  runs the sealed query. The query text is never caller input; a stray `query` key in the payload is ignored.
- **Exit test `s41`** — govern-add a `demo.search` label query, dispatch it as a `ck_participant` with a
  bound term (returns the match), confirm different terms bind differently, an injection-shaped value is
  rejected (`invalid_param`), and a caller-supplied raw query is ignored (the sealed query still runs).

With this, **all of Tier 2 is shipped**: generic typed create (v0.4.5), governance shape-mutation (v0.4.5),
reach edge-materialization (v0.4.6), and governed query affordances (v0.4.7). Remaining v3.9 items are the
inherited F-A identity (snapshot authz) + F-C result routing, and the engine asks (derivation-chain trace,
incremental materialization).

## v0.4.6 - 2026-06-12

**Tier 2 (3/3a) — `instance.reach` traverses participant-created links.** `edge.create` sealed an Edge
*instance* (a row with source/predicate/target) but wrote no quad, so `instance.reach` — a property-path
SPARQL over the RDF graphs — returned `[]` for any link a participant actually created (the existing test
only passed by pre-seeding quads directly).

- **`ckp.materialize_edge`** writes the traversable quad `<source> <predicate> <target>` into a per-project
  edge graph (`urn:ckp:<project>/edges`) when `edge.create` seals. Injection-safe: source/predicate/target are
  IRI-gated before the Turtle is built; a non-IRI endpoint seals the Edge instance **without** a quad and the
  reply reports `reachable:false` (the link is recorded but honestly flagged not-traversable — never a silent
  drop). A short predicate is namespaced to its v3.7 IRI; a full-IRI predicate is used as-is.
- **`edge.create`** reply gains `reachable`.
- **Exit test `s40`** — through the dispatch door as a real `ck_participant`: `edge.create` A→B and B→C (both
  `reachable:true`), then `reach(from=A)` returns `{B, C}` transitively; a bare-id edge is `reachable:false`.

The governed `concept.match` form (author a QueryAffordance → seal via governance → compile → bind) is the
remaining Tier 2 item, tracked separately.

## v0.4.5 - 2026-06-12

**Tier 2 (2/3) — governance `apply` now mutates the kernel shape (`_graph_apply`).** The single biggest
honesty gap in the v3.9 epoch is closed: before this, a quorum-approved Proposal advanced the epoch and
sealed "applied" but **never changed the type**. Now `kernel.apply` translates the passed op into the kernel
graph before the epoch bump, so consensus actually evolves the type.

- **`ckp._op_to_ttl`** translates a passed Proposal op into SHACL: `add_property` →
  `[ a sh:NodeShape ; sh:targetClass <C> ; sh:property [ sh:path <P> ; sh:minCount n ] ]`, `add_class` →
  `<C> a owl:Class`. Every interpolated value is IRI/integer field-gated (no quote/space/newline can reach
  the Turtle). Ops without a shape projection yet are a documented no-op (still epoch-bump + applied seal).
- **`ckp.apply_shape_ttl`** stages the generated Turtle through the engine, applies the same meta-fence as
  `ckp.stage_ttl` (only rdf/rdfs/owl/sh predicates admitted), then `copy_graph`s it into
  `urn:ckp:<project>/kernel/ck` (the graph `ckp.seal` reads required props from) and materializes — one txn.
  The caller never authors raw Turtle; they author a typed op and pgCK builds it.
- **`ckp.apply`** runs the graph-apply at step 4a (before `bump_epoch`); its reply gains
  `applied:{graph_changed, applied_quads}`. A shape op that fails to stage/fence returns `graph_apply_failed`
  with no epoch change.
- **Exit test `s39`** — the definitive loop: create a Ship (seals, unshaped) → propose + vote + apply
  `add_property(crew_size, minCount 1)` (asserts `applied.graph_changed`, and the constraint is then a fact
  in the kernel graph) → the SAME create is now **REJECTED** → a Ship WITH `crew_size` seals. The type
  changed via consensus. Warm suite (s4…s39) + s34 fresh-install green.

This makes the v3.9 governance plane real end-to-end (process **and** effect). Remaining Tier 2: reach
edge-materialization + governed `concept.match`.

## v0.4.4 - 2026-06-12

**Tier 2 (1/3) — generic typed `instance.create`.** The adoption keystone (oci-germination + the CK.Lib.Js
wire-contract Q2): `instance.create` now accepts a uniform `{type:<class IRI>, …fields}` body and routes it
by `type` against the kernel's OWN declared SHACL shape — not only the Task/Goal payload-key concretion.

- **`ckp.create_typed`** maps each caller field to the type's declared property IRIs (read from the kernel
  graph's `sh:property`/`sh:path`), assembles the instance body, and seals it. The required-props gate is
  `ckp.seal`'s existing one (against `urn:ckp:<project>/kernel/ck`), so `validate ⟺ seal` now holds for ANY
  declared type, not just Task/Goal. A bare (non-IRI) `type` is rejected — it could never match a
  `sh:targetClass`, so a "typed" claim would be vacuous.
- **Dispatch routing**: a top-level `type` (with no `task` sub-object) selects the generic path; the legacy
  `{task:{…}}` / `{name:…}` forms still route to `task.create` / `kernel.create` (back-compat during the
  alias window — `name` is an ordinary property here, not a discriminator).
- **Exit test `s38`** — an *adopter* models a Ship with a required `crew_size`: a Ship WITH it seals +
  verifies and carries the declared property IRIs (number types preserved); a Ship MISSING it is REJECTED by
  the gate; `instance.validate` predicts the same; the legacy `{task}` form still works. Warm suite 28/28
  (s4…s38) + s34 fresh-install green.

Still Tier 2: governance `apply` mutating the kernel shape (`_graph_apply`), reach edge-materialization,
governed `concept.match` — plus F-A identity upstream.

## v0.4.3 - 2026-06-12

**Tier-1 of the CK.Lib.Js v1.5.0 npm-gate punch-list** — three verbs a real client observed broken on
the live bundle, each fixed to match what the substrate actually does (never a richer claim than the seal
enforces). Does **not** fully unblock npm — `reach`/`match`-traversal, generic typed create, and the F-A
identity items remain (Tier 2 / upstream); see the punch-list NOTIFY.

- **`instance.validate` — now handled** (was registered with no dispatch branch → "ungoverned in-kernel").
  It predicts the seal: runs the same required-props (`sh:minCount≥1`) gate `ckp.seal` enforces against the
  project's kernel graph, so `validate ok` ⟺ `seal accepts`. An unimported type is valid silence
  (conforms). Returns `{conforms, missing_required[]}`.
- **`instance.transition` — state-key reconciled.** The gate read v3.8 `core#lifecycle_state` while
  `task.create` writes v3.7 `lifecycle_state`, so every fresh task was `draft` to the gate (never
  transitionable). It now reads the task model's own field and writes both it and a bare `state`; the
  transition map covers the real `planned → in_progress → done` lifecycle (the draft/review/approved set
  kept for other instances). Test `s37`.
- **`concept.match` — finds real instances.** It searched `rdfs:label`, which Task/Goal instances don't
  carry (they use v3.7 `title`), so it always returned `[]`. Now derives the label from the actual
  label-bearing fields. Still the sealed, injection-safe, pgCK-authored query (the *governed* form is Tier 2).

### Also in 0.4.3

- **`instance.update` fixes** (CK.Lib.Js bug report `instance-update-patch-gaps`): the `task.update`
  handler was a hardcoded two-field allow-list (`lifecycle_state` + `priority`) that **silently dropped
  any other patched field** including `title` (their 2.1), and stored via `->>` so a numeric `priority:1`
  became the string `"1"` (their 2.2). Now applies the full closed task-field patch (title / priority /
  lifecycle_state / part_of_goal / target_kernel) **preserving JSON type** (`->`), and `task.create` +
  the `snapshot.board` projection preserve number types end-to-end too (a string priority from a
  string-sending client is likewise preserved as a string — true type fidelity, no SHACL datatype is
  pinned on these fields). Test `s36`. Their 2.3 (identity-per-session) noted for the F-A design.
- **`instance.retire` — the retraction seal** (the FINALIZED spec's last unbuilt verb, VISION §2.1):
  retiring seals a NEW fact (`retired:true` + required reason) — ledger grows, proof verifies, the
  original facts remain forever in the chain; `already_retired` / `unknown_instance` / `reason_required`
  typed errors. Registry-seeded, dispatch-routed. Test `s35`.
- **`ckp.validate_report` scratch graph by IRI** — removed the last fixed-numeric-graph-id pattern
  (`1100000000+pid`), the same collision class that bit `stage_ttl`; get-or-create by IRI.
- **web2 → `instance.*`**: all `task.create` / `task.update` / `kernel.create` call sites in `web/`
  (board, studio, tasks, tutorial, explorer) now dispatch canonical `instance.create` / `instance.update`
  (payload-key discrimination routes task-vs-kernel). `snapshot.board` intentionally stays during the
  alias window (`instance.snapshot` is grant-checked). This is pgCK's own side of the alias-retirement
  clock done.
- Verification: `smoke-s34` (fresh cluster) + warm suite `s4`–`s35` 25/25 green at `0.4.3`.

## v0.4.2 - 2026-06-11

**Install-from-zero completeness.** Answers the oci-germination install-cascade report (consumer
`ociger-ck-allinone` v0.7.14): on a **virgin cluster**, `CREATE EXTENSION pgck CASCADE` now yields a
working governed dispatch for a real `ck_participant` login with **zero manual steps** — previously the
seal-path tables, their ownership, the pgrdf floor grants, the ontology fixtures, and a hard-raising
self-test each demanded an undocumented consumer workaround. No new verbs; the v3.9 surface is unchanged.

### Fixed — the 5-step install cascade

- **Tables at install (asks 1+2):** `ckp.{instances,ledger,proof,outbox}` (+ index + outbox trigger) are
  created as top-level DDL in the install script, owned by `ck_substrate` from birth, and flagged
  `pg_extension_config_dump` so seal data survives `pg_dump`. `ckp.bootstrap_kernel()` remains
  (idempotent) for legacy callers — but is no longer required before dispatch works.
- **Virgin-DB seal path:** `ckp.shapes_self_test` no longer RAISEs when a project's board graph was never
  imported — an undeclared ontology is *valid silence* (VISION §2.1); the self-test arms itself the
  moment `ckp.import_module()` lands shapes, and the stale-mount assert is preserved verbatim for
  present graphs. This was the root cause that forced every consumer into the fixture hunt.
- **Ontology fixtures shipped (ask 3):** release artifacts (tarball + OCI) now include `ontology/*.ttl`;
  mount or copy the artifact's `ontology/` at `/ontology` (the documented default for `ckp.boot()` /
  `ckp.import_module()`), exactly like `lib/` + `share/`.
- **pgrdf floor re-assert (ask 4):** the migration re-grants + re-owns pgrdf storage to `ck_substrate`
  idempotently, LAST in the install script. `ck_participant` gets **nothing** on pgrdf — consumers who
  granted it as a workaround should revoke it (it breaches the v3.9 floor).
- **Closing floor pass (ask 5):** every `ckp` function is uniformly `SECURITY DEFINER`, owned by
  `ck_substrate`, `search_path`-pinned; procedures owner+path-pinned (kept INVOKER for `pg_read_file`);
  `ck_participant` re-pinned to exactly schema USAGE + EXECUTE on the dispatch door(s).

### Added

- **`smoke-s34` — the install-from-zero gate** (`scripts/smoke-s34-fresh-install.sh`): a throwaway
  virgin postgres-17 cluster + artifact mounts → `CREATE EXTENSION` → governed dispatch as a real
  `ck_participant` login → `ok:true`; boot + module import from the shipped `/ontology` layout; floor
  holds (participant reaches no table, no pgrdf). This is the consumer journey the warm-volume suite
  (`s4`–`s33`) structurally could not see.

### Docs / process (shipped with this tag)

- README "Status" refreshed to the shipped CKP v3.9 surface; PROVENANCE corrected to
  `attest-build-provenance@v2`; operator/home paths genericized; internal dev/planning docs moved to
  local-only `_WIP/`; `RELEASE_NOTES` redirected to this changelog as the single log.
- **PROVENANCE Rule 7:** every release MUST update `CHANGELOG.md` with *what changed* + *what tests
  passed*.
- `cargo fmt` relay-code fix (greens the `ci` fmt gate).

### Verification

`smoke-s34` (fresh cluster, zero manual steps, floor intact) + full warm suite `s4` / `s9` / `s11–s33`
green; both arches attestation-verified before `LATEST.md` advanced.

## v0.4.1 - 2026-06-11

**Clean canonical tag for the CKP v3.9 epoch.** Functionally identical to `v0.4.0` (the full Critical
Isolation surface, Tracks A–E) — re-released under a fresh, never-before-used tag because `v0.4.0`'s tag
carried a failed first build (a version/tag mismatch) before its successful re-cut. **Tag hygiene rule:
a tag that ever meant a broken build is burned and never reused; the next attempt takes the next number.**
Also folds in the `cargo fmt` relay-code fix (greens the `ci` fmt gate; `RELAY_OUT_PREFIX`/`async_nats::`
markers preserved). **Pin `v0.4.1`.**

### Verification

Smoke `s4` + `s9` + `s11–s33` green at `0.4.0` content; the version bump to `0.4.1` is a clean relabel
(no SQL change). Attestation confirmed before this entry was finalized.

## v0.4.0 - 2026-06-10

**CKP v3.9 "Critical Isolation" — ENFORCED.** The epoch is complete. An enumerable, typed read surface
closes the three-ring architecture: every read is typed + bounded, no caller SQL/SPARQL expression
position is reachable, and the entity-linking hot loop runs end-to-end with **no participant ever holding
more than `EXECUTE ckp.dispatch`**.

### Added — CKP v3.9 Track E (the typed read surface)

- **CI-E-5 — `instance.query`.** Typed query: closed operator enum, declared-property keys, bounded
  limit/offset; compiled from fixed per-operator templates (quote_literal values + enum operators, numeric
  guards). test `s29`.
- **CI-E-4 — `instance.reach`.** Bounded transitive traversal; `via` is a registry-checked predicate IRI
  (never parsed); `+` only; depth capped at `pgrdf.path_max_depth`. test `s30`.
- **CI-E-3 — `instance.transition` + authz'd snapshot.** `to_state` gated against the sealed transition
  map; `instance.snapshot` under a per-requester grant (closes F-E). test `s31`.
- **CI-E-2 — `concept.match` + `instance.explain`.** A sealed label-search exposed under a verb (callers
  bind the term only); `instance.explain` reports direct-vs-inferred via the engine `is_inferred` column
  (full derivation chain deferred — engine ask #1). test `s32`.
- **CI-E-1 — Track E flip / v0.4.0.** The hot loop runs end-to-end as `ck_participant` (propose → vote →
  apply → create → verify); the floor holds. test `s33`. Also: `stage_ttl` now get-or-creates its scratch
  graph by IRI (no fixed-graph-id collision across runs).

### The epoch (v0.3.0 → v0.4.0)

| Release | Track | Lands |
|---|---|---|
| `v0.3.0` | A | the Postgres role floor — `ckp.dispatch` is the only door |
| `v0.3.2` | B | the sealed registry as routing authority |
| `v0.3.3` | C | apply-time plan compiler + epoch invalidation (F-H gone) |
| `v0.3.4` | D | the governance type plane (propose → quorum → apply; fenced raw_ttl) |
| **`v0.4.0`** | **E** | **the enumerable typed read surface — Critical Isolation enforced** |

### Verification

Smoke `s4` + `s9` + `s11–s33` green. The entity-linking hot loop, the three governance verbs, the four
typed reads, and the role floor all proven through the single floored `ckp.dispatch` door.

## v0.3.4 - 2026-06-10

**CKP v3.9 Track D "The governance type plane"** — a SHACL-shape / type change lands ONLY via a sealed
proposal → quorum vote → apply cascade, with a complete proof chain. A direct attempt is structurally
impossible (Track A); a dispatch attempt on the instance plane is plane-rejected (Track B). The one
caller-Turtle path is fenced (Rust-parse → meta-fence). web2's instance surface is unchanged.

### Added — CKP v3.9 Track D (governance type plane)

- **CI-D-6 — governance ontology.** `ckp:Proposal`/`Vote`/`QuorumLevel`/`Grant`/`Transition` classes +
  properties + `ProposalShape`/`VoteShape`/`GrantShape`/`TransitionShape` in `core.ttl`. test `s24`.
- **CI-D-5 — `kernel.propose_change`.** Seals a `ckp:Proposal{pending}` from a closed op-set; injection-safe
  field gate (op enum, `about` IRI-pattern, quorum int) → `ProposalShape` → seal. test `s25`.
- **CI-D-4 — `kernel.vote` + quorum.** Seals a `ckp:Vote` about a pending Proposal; `quorum_met` =
  COUNT(approve) ≥ `requiresQuorum`. A human approval is a Vote sealed by a human identity. test `s26`.
- **CI-D-3 — `kernel.apply` cascade.** One txn: quorum gate → `bump_epoch` (recompile + cache clear — the
  shape version advances) → seal `applied`. Below-quorum / re-apply rejected. test `s27`.
- **CI-D-2 — fenced `raw_ttl` + materialization policy.** `ckp.stage_ttl`: the caller's TTL is Rust-parsed
  into a scratch graph (no SQL string-building) and meta-fenced (only rdf/rdfs/owl/sh predicates — no
  instance data or foreign triples). `ckp.set_materialize_policy` (trigger/profile). test `s28`.
- **CI-D-1 — Track D flip.** A shape change lands only via quorum, full proof chain; direct = structurally
  impossible (CI-A), instance-dispatch = plane-rejected (CI-B). Released as `v0.3.4`.

### Verification

Smoke `s4` + `s9` + `s11–s28` green. The dispatch governance branch routes propose/vote/apply; a
handler-less governance verb stays plane-rejected (`s19`); web2 instance surface unchanged (`s15`).

## v0.3.3 - 2026-06-10

**CKP v3.9 Track C "Plan compiler + epoch invalidation"** — affordance query templates compile from the
kernel's **sealed** declarations (never caller input) into parameterized statements; runtime binds caller
values positionally (`EXECUTE … USING`, never concatenates); a type change recompiles + bumps the compile
epoch atomically and clears the engine plan cache. **The F-H staleness root cause is eliminated.**

### Added — CKP v3.9 Track C (compiler + epoch)

- **CI-C-4 — `ckp.plans` table.** Derived compiled-plan state keyed `(kernel, verb, epoch)` — engine
  state, not graph facts (v3.9 §5.3). `sql/pgck--0.3.2--0.3.3.sql` · test `s21`.
- **CI-C-3 — apply-time compiler.** `ckp.compile_plans` stamps pgCK's sealed read templates into
  `ckp.plans` at the kernel epoch (idempotent); `ckp.plan_exec` resolves a plan and binds caller values
  via `EXECUTE … USING` — a SQL-injection param is bound as a literal, not interpolated (proven in `s22`).
- **CI-C-2 — epoch + atomic invalidation.** `ckp.kernel_epoch` holds the current epoch; `ckp.bump_epoch`
  advances it + recompiles + clears the pgRDF plan cache (`pgrdf.plan_cache_clear()`) in one txn; a missing
  plan recompiles-then-retries in-call. **Closes F-H.** test `s23`.
- **CI-C-1 — Track C flip.** Exit holds: a type change recompiles + bumps the epoch atomically; a
  deliberately staled client is corrected in-call. Released as `v0.3.3`.

### Verification

Smoke `s4` + `s9` + `s11–s23` green (build via colima/docker; compile → parameterized-bind + epoch
invalidation proven; `s15` guards web2 no-regression). The live web2 dispatch is unchanged — the plan
compiler is the typed-read substrate the registry routes into (wired into dispatch at CI-E).

## v0.3.2 - 2026-06-10

**Supersedes v0.3.1**, whose CI release failed on the arm64 SLSA attestation step
(`Failed to persist attestation: Requires authentication`). `actions/attest-build-provenance` bumped
`@v1`→`@v2` (Node-24) in `release.yml` + `publish-pgck-web.yml`; identical Track B extension content.

**CKP v3.9 Track B "Registry as routing authority"** — the sealed affordance registry is now the sole
router for `ckp.dispatch`. Verbs migrate to the `instance.*` surface (legacy names retained as aliases
for one minor — CK.Lib.Js confirmed the op→verb table); unknown verbs fail typed with zero payload
evaluation; governance-plane verbs never execute on the instance path. web2's `v0.3.0` verb surface is
unchanged (the alias window).

### Added — CKP v3.9 Track B (sealed registry + typed dispatch)

- **CI-B-5 — plane + epoch.** `ckp:plane` (instance|governance) + `ckp:epoch` on `ckp:Affordance`,
  enforced by `AffordanceShape` (optional + `sh:in`-constrained, so existing affordances don't break).
  `ontology/core.ttl` · test `s16`.
- **CI-B-4 — the exact-match registry.** `ckp.affordance_registry` keyed `(kernel, verb)`;
  `ckp.registry_refresh` indexes the sealed affordance facts; `ckp.registry_lookup` is parameterized
  equality only (no `LIKE`/dynamic eval). `ckp:delegate` is a sealed fact. `sql/pgck--0.3.0--0.3.1.sql`
  · test `s17`.
- **CI-B-3 — the ValidationReport gate.** `ckp.validate_report(ttl, shapes) → {conforms, violations[]}`
  surfaces field-level diagnostics via the Ring-1 `_validate` primitive (closes rc-07). test `s18`.
- **CI-B-2 — plane route + verb migration.** `ckp.verb_canon` (legacy→`instance.*`) + `ckp.verb_to_legacy`
  (`instance.*`→handler, routing `instance.create` by payload type) drive a non-breaking dispatch
  preamble; pgCK's core verb surface is seeded with planes. Governance-plane verbs → propose stub.
  test `s19`.
- **CI-B-1 — registry is the routing authority.** Every shipped verb resolves through the registry; an
  unregistered verb → `{ok:false, error:'unknown_affordance'}` (no fallthrough); a `delegate=true` row
  → `{delegate:true}` (a sealed delegation fact, not an absence). test `s20`.

### Verification

Smoke `s4` + `s9` + `s11–s20` green (build via colima/docker). The `instance.*` surface and the
registry gate are proven; `s15` guards web2 no-regression.

### Coordination

- CK.Lib.Js confirmed the `task.*`→`instance.*` op→verb mapping (one fix applied: `kernel.create` →
  `instance.create`; `instance.validate` registered) + the alias window + no transport change this step
  (`pgCK/_WIP/NOTIFIES.CK.Lib.Js.v1.5.0.trackb-instance-verb-migration*`).

## v0.3.0 - 2026-06-10

**CKP v3.9 "Critical Isolation Alpha"** — the database door is structurally real. The extension now
isolates the pgRDF engine behind a Postgres role floor: even an operator with DB credentials holds
exactly one capability, `ckp.dispatch`. Intermediary release so `web2/` development continues on the
new alignment; the typed four-tuple registry / governance plane (CI-B…CI-E) is the next thread.

### Added — CKP v3.9 Track A (role isolation)

- **CI-A-4 — the role floor.** Roles `ck_substrate` (non-login; sole pgrdf operator + ckp internals
  owner) and `ck_participant` (the only role connections/agents receive). `pgrdf.*` + the ckp internal
  tables REVOKEd from PUBLIC; `ck_substrate` **owns** pgrdf's storage (partition creation needs
  ownership, not just GRANT). `sql/pgck--0.2.2--0.2.3.sql` · test `s11`.
- **CI-A-3 — the frozen Ring-1 set.** Ten `SECURITY DEFINER` wrappers owned by `ck_substrate`
  (`_seal`/`_validate`/`_read_typed`/`_traverse`/`_verify`/`_materialize`/`_stage_parse`/
  `_graph_apply`/`_recompile`/`_ledger_read`) — the only paths that touch `pgrdf.*`.
  `sql/pgck--0.2.3--0.2.4.sql` · test `s12`.
- **CI-A-2 — the dispatch door.** `ckp.dispatch` is `SECURITY DEFINER` owned by `ck_substrate`,
  granted to `ck_participant` and nothing else. `sql/pgck--0.2.4--0.2.5.sql` · test `s13`.
- **CI-A-1 — Track A flip.** `ck_participant` LOGIN; a sidecar `psql` connecting *as* `ck_participant`
  proves a real connection holds exactly `ckp.dispatch`. `sql/pgck--0.2.5--0.2.6.sql` · test `s14`.
- **Alpha — web2 verbs under the floor.** `sql/dispatch.sql` (the web2 verb surface) is baked into the
  extension and floored: `ckp.dispatch(text,jsonb)` SECURITY DEFINER, granted to `ck_participant`, so
  web2 keeps working on the isolated substrate. `sql/pgck--0.2.6--0.3.0.sql` · test `s15`.

### Verification

- `just smoke-s4` green end-to-end: `s4` (seal), `s9` (participant), `s11`–`s14` (floor / Ring-1 /
  dispatch-only / sidecar), and `s15` — web2 reads (`snapshot.board`, `instances.count`, `kernels.list`)
  **and** a `task.create` seal (SHACL gate → ledger → proof) through the floored dispatch as
  `ck_participant`, while the floor still denies direct `pgrdf.*` / `ckp.instances`.

### Chore (separate concern — repo hygiene)

- Untracked a mistakenly-committed `.venv/` (1392 files); gitignored `SPEC*` (private design docs) and
  `.venv/`; relocated Playwright MCP screenshots out of the repo root to `tests/e2e/screenshots/`.

### Notes

- Builds + GHCR pushes run on GitHub Actions only (SLSA Build Provenance v1); `LATEST.md` advances
  through the attestation gate. This is the milestone **CK.Lib.Js** syncs toward (strip client RDF,
  keep JWT) and **oci-germination** bundles (run in-bundle clients as `ck_participant`, not superuser).

## pgck-web/v0.2.7 - 2026-05-29

Web release: **U1 — both HTML pages are now static** (no-FastAPI UI-increment journey, step 1; roadmap §20). FastAPI stops rendering HTML.

### Changed

- **`/` and `/tasks.html` are committed static files** (`web/static/index.html`, `web/static/tasks.html`), served by a root `StaticFiles(html=True)` mount ordered after `/api/*`. The `render_index` / `render_tasks_page` / `_render_nav_menu` templaters (and the unused `STATIC_ASSET_VERSION`) are removed from `web/protocol.py`; `app.py` drops the HTML routes + `HTMLResponse`/`web.protocol` imports.
- **Browser config is client-derived in the page** (`nats_ws_url` from `location.host`) instead of FastAPI-injected. Identity/session will arrive dynamically via the NATS envelope → `Participant` (U2), not baked into the page.

### Notes

- FastAPI still serves `/api/*` (board reads/writes) during the transition — retired at U5 when static-cklib (Go) serves everything and `app.py` is deleted.
- Presence model (U2) reuses `CSVC.Participant` / `CSVC.Session` — `participant.join` is the request; no invented `VisitorRequest` type.

### Verification

- Verified live via FastAPI `TestClient`: `/`→200 (static display shell), `/tasks.html`→200 (board shell), `/api/board`→200 (still routes before the `/` mount), `/protocol`→404, `/assets/protocol.json`→200, `/assets/display-app.js`→200.
- `tests/test_web.py` rewritten: `test_root_serves_static_display_shell` + `test_tasks_serves_static_board_shell` (the prior stale `test_root_serves_owner_board_shell` asserted board content at `/` and referenced a non-existent `/static/app.js`).

## pgck-web/v0.2.6 - 2026-05-29

Single-task web release: **CKD-3 — `/protocol` becomes a static asset** (first step of the web-layer Python removal; the display page no longer touches a Python-computed endpoint).

### Changed

- **`GET /protocol` FastAPI route removed.** The protocol document is now a committed static asset `web/static/protocol.json`, served by the existing `/assets` `StaticFiles` mount — no handler computes it. `web/protocol.py::protocol_document()` stays as the single source of truth; `scripts/gen_protocol_json.py` regenerates the file from it.
- **`display-app.js` and `board-app.js`** fetch `/assets/protocol.json` instead of `/protocol`.

### Notes

- The browser's **live** config is unchanged — it still arrives via the injected `window.PGCK_DISPLAY_CONFIG` global, so the static doc's `subject`/`nats_ws_url` are illustrative defaults only.
- Net effect: the **display page is now Python-free** end-to-end (it only loads static assets + talks NATS via CK.Lib.Js). The board page still uses `/api/*` (REST) until those become NATS affordances (CKA-3/CKA-4) — tracked for the Track D ship.

### Verification

- `tests/test_web.py::test_protocol_doc_is_static_asset` — asserts `/protocol` → 404 and `/assets/protocol.json` → 200 with the four command kinds intact.
- `scripts/gen_protocol_json.py` reproduces the committed file byte-for-byte.

## v0.2.2 - 2026-05-29

Extension release: **CKF-3 — participant identity in `ckp.seal()`** + a fix for a **v0.2.1 fresh-install regression** (the CKA-6 outbox/trigger DDL ordering).

### Added

- **CKF-3 — participant identity in `ckp.seal()`.** An optional `participant` claims object (`{sub, preferred_username, email}`) in the sealed body is resolved to the canonical IRI `urn:ckp:participant:<normalised-sub>` (via `ckp.urn_normalise`), or `urn:ckp:participant:anon:<nonce>` when absent/empty. Written into `ckp.instances.body` under `https://conceptkernel.org/ontology/v3.8/core#participant` **before** the body SHA, so `ckp.verify()`'s recompute stays consistent. `preferred_username`/`email` ride as non-authoritative `participant_display_name`/`participant_email` (only when an identified `sub` is supplied). Per `NOTIFIES.pgCK §D`.
- **`sql/test/s9_seal_participant.sql`** — covers identified-sub → `urn:ckp:participant:alice` (+ display fields + `verify()`), anonymous → `urn:ckp:participant:anon:<nonce>`, empty-sub → anon fallback, and non-trivial-sub normalisation (`'Alice Smith '` → `urn:ckp:participant:alice-smith`). Wired into the `smoke-s4` recipe.

### Fixed

- **Fresh `CREATE EXTENSION pgck` was broken in v0.2.1.** The CKA-6 `ckp.outbox` table (FK → `ckp.ledger`) and the `ckp_ledger_after_insert` trigger were emitted as install-time top-level DDL, but `ckp.ledger` is created lazily inside `ckp.bootstrap_kernel()` — so a fresh install failed with `relation "ckp.ledger" does not exist`. Both now live inside `bootstrap_kernel()` alongside `ckp.ledger`/`ckp.instances`/`ckp.proof`. The trigger *function* `ckp.ledger_to_outbox()` stays top-level (its body isn't resolved until the trigger fires). Idempotent for existing installs (`IF NOT EXISTS` / `DROP TRIGGER IF EXISTS`).

### Verification

- Fresh `CREATE EXTENSION pgck` (0.2.2) + `CALL ckp.boot()` succeeds; `pgck_version()` → `pgck 0.2.2 (rc3)`. The v0.2.1 regression is resolved.
- `sql/test/s9_seal_participant.sql` → `PASS` against a fresh-installed 0.2.2 extension (all four branches).
- Upgrade `sql/pgck--0.2.1--0.2.2.sql` `CREATE OR REPLACE`s `ckp.seal` + `ckp.bootstrap_kernel` — safe/idempotent on a live, bootstrapped 0.2.1 DB.

### Known issues (pre-existing harness rot, not a regression from this release)

- The full `smoke-s4` suite is red on `s4_validate` because the compose stack mounts a stale `pgrdf--0.5.0.sql` whose SHACL is `minCount`-permissive (see `_WIP/NOTIFIES.pgRDF.0.5.1.shacl-mincount-permissive`), and `/ontology/task.ttl` isn't mounted for board imports. Both are compose-mount staleness unrelated to CKF-3; tracked for a separate harness-refresh.

## pgck-web/v0.2.5 - 2026-05-29

Single-task release: **CKA-7 — long-form `event.kernel.pgCK.Display.<event-kind>` dual-emit alongside short-form `event.pgCK.Display`**. CKClient v1.3 dual-subscribes; consumers cut over gradually; the short-form alias is removed in the release window that ships CK.Lib.Js v2.0.

### Changed

- **`web/service.py::NatsEventPublisher`** — every `publish(payload)` call now emits to BOTH the v1.2.x short-form subject (`event.<Kernel>`, currently `event.pgCK.Display`) AND the CKP v3.8 long-form subject (`event.kernel.<Kernel>.<event-kind>`, e.g. `event.kernel.pgCK.Display.task_upsert`). Same payload bytes on both; one connect / two publishes / one flush / one close per call.
- **New env var `PGCK_BROWSER_NATS_SUBJECT_LONG`** — optional override for the long-form prefix; defaults to `event.kernel.<PGCK_DISPLAY_KERNEL>` (i.e. `event.kernel.pgCK.Display`).
- **`_derive_subjects(payload)` helper** extracted as a pure function — the long-form `<event-kind>` is the payload's `kind` field (`theme`, `audio`, `task_upsert`, `board_snapshot`, `broadcast` fallback if absent).

### Added

- **`tests/test_service.py::test_nats_publisher_derives_short_and_long_subjects`** — unit test on the subject derivation across all four payload kinds + missing/empty-kind fallback.
- **`tests/test_service.py::test_nats_publisher_publishes_to_both_subjects`** — integration test with `monkeypatch`-mocked `nats.connect` verifying both subjects receive the same payload bytes in a single `publish()` call.

### Notes for consumers

- **CKClient v1.3** can subscribe to either subject; new code should prefer the long form and pass it as an `extraSubject`. The browser config served at `/protocol.json` already advertises both (`nats_subject` short, `nats_subject_long` long).
- **No payload shape change.** Identical bytes on both subjects. CKA-5 (MessagePack codec on `event.kernel.*`) lands later and only affects the long-form path.
- **No change to the pgCK extension publish path.** The bgworker outbox drain (CKA-6, extension v0.2.1) emits `event.kernel.pgCK.<class>.sealed` on the long form already; this CKA-7 release wires the FastAPI display surface to do the same.

### Verification

- `python -m pytest tests/test_service.py` — 6 / 6 pass (4 pre-existing + 2 new).
- Attestation verifies for both arches at GHCR — see LATEST.md.

## pgck-web/v0.2.4 - 2026-05-29

**First SLSA-attested pgck-web release.** Bootstrap of the attestation gate on the pgck-web publish stream (per PROVENANCE.md Rule 4 bootstrap exception). pgck-web/v0.1.0–v0.2.3 predate the attestation wiring and stay unattested in their existing GHCR form; consumers wanting a provenance-verified pgck-web pin start here.

### Changed

- **`publish-pgck-web.yml`** trigger simplified — removed the `paths:` filter under `push.tags` that was preventing tag-only pushes from triggering the workflow when the head commit didn't touch `web/`. Added `workflow_dispatch:` for manual re-runs.

### Content

- Image content **identical to `pgck-web/v0.2.3`** — same FastAPI app code, same `web/static/display-app.js` CKClient v1.3 wiring, same `/cklib` + `/assets` mounts. The only thing that changes is provenance: this is the first build where `actions/attest-build-provenance@v1` runs as part of the pipeline, signing the digest via Sigstore keyless OIDC and pushing the attestation as an OCI referrer.

### Verification

- `gh attestation verify oci://ghcr.io/styk-tv/pgck-web:v0.2.4-amd64 --repo styk-tv/pgCK` and the `arm64` equivalent — both must return exit 0 before `LATEST.md` advertises this version.
- The `update-latest-md.yml` workflow's pgck-web side gate is the truth signal: only the side whose attestation verifies gets rendered into LATEST.md.

### Downstream / oci-germination handoff

This is the release that lets `oci-germination`'s `ck-allinone` bundle pin **both** pgCK extension (`v0.2.1-pg17-{amd64,arm64}` attested) **and** pgck-web (`v0.2.4-{amd64,arm64}` attested) so the all-in-one bundle achieves a verifiable full-chain provenance per `NOTIFIES.oci-germination.v0.6.all-in-one-web-pin-update`.

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
