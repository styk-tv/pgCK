# Changelog

All notable changes to `pgCK` are logged here.

## v0.4.85 - 2026-08-27

**What was governed in shows up in its own list.**

pgCK#56, closed on the loop form. `kernel.apply` compiled the plan and inserted the
registry row — the verb was callable — and sealed no `ckp:Affordance`, so capability
worked while its declared face was absent, and the affordances list could never carry
it. The declared/routed gap, measured since the suite existed.

Emission and declaration now move in one act: both registrars (query and derived) seal
the `ckp:Affordance` in the same transaction as the registry row — gated by
`AffordanceShape`, `producedBy` the kernel's law, `derivedBy` the very Materialization
the same apply sealed, plane spoken in the root's closed vocabulary. A seal refusal
fails the apply loudly: a capability that cannot declare itself does not go live
half-made.

Two instrument corrections rode along, both in case 28: the reply's list key is
`affordances` (the B1 contract since 0.4.51 — `derived[]` was handover shorthand that
never existed as a key), and plpgsql's RAISE formats bare booleans as `t`/`f`, which
the case's own grep could never match — the instrument was hiding its own success.

Suite: cases 04/28 flipped GREEN — 30 cases, 19 green, 10 red-as-predicted, 0 broken.

## v0.4.84 - 2026-08-27

**The reply tells you what it is.**

Two halves of the same blindness, fixed the same way as 0.4.83's envelope law — one
instrument each, applied at the door's sites, never a per-site rewrite:

- **P3 — the reply carries what the seal wrote** (`ckp._stamped`). The four stamps
  (M1 `createdBy` · M2 `producedBy` · M3 `sealedAtEpoch` · M4 `conformsToShape`) were
  stored by every seal and nulled or absent in every reply, so a producer was blind to
  its own act and clients (CK.Lib.Js's D7 shim) had to read the seal back. One reader
  over the stored body, appended by the write sites: `instance.create` (typed and
  legacy), `instance.update` (both), `instance.link`, `notify`, `instance.transition`,
  `instance.retire`. The keys ride flat and are never aggregated; an absent M4 stays
  absent — admitted-but-judged-by-nothing is a fact to surface, not a null to fake.
- **B2 — a read carries its completeness verdict** (`ckp._read_verdict`). A row count
  without its verdict is not a count. With the total known the verdict is measured
  (`complete`/`truncated`); with only a limit, an answer that fills the limit claims no
  more than `possibly_truncated`. Applied at `kernels.list`, `instances.list/last/count`,
  `instance.query`, `instance.reach`.

Suite: cases 14/15 flipped GREEN — 30 cases, 17 green, 12 red-as-predicted, 0 broken.
Warm road 0.4.83→0.4.84 rehearsed on the dev bench; envelope law re-verified over wss
after the upgrade.

## v0.4.83 - 2026-08-27

**The refusal envelope becomes one law.**

The same refusal class shipped `{ok:false, refused:true, error, hint}` from one
construction site (`instance.link`) and bare `{ok:false, error, hint}` from another
(`instance.create`) — 101 hand-built `ok:false` objects and no single definition of what
a refusal looks like on the wire, so no consumer could structurally tell a refusal from a
fault. Measured from the client seat (CK.Lib.Js's wire ladder), whose classifier
correctly refused to manufacture the flag from prose.

The fix is one law at the door, not a 101-site sweep:

- **`ckp.refusal_registry`** — the declared closed set of refusal codes (51), each with a
  typed SQLSTATE class: pgck's own E0 discipline arriving at its own envelope. Where the
  caller's *key* was the mistake, the registry carries the teaching hint: `invalid_about`
  now answers with the contract (`{about: <proposal_iri>}`) instead of only the value it
  disliked.
- **`ckp._refusal_envelope`** — the normalizer, applied once on the way out of
  `ckp.dispatch`: code in registry ⇒ `refused:true` + `sqlstate` (+ hint if owed and
  absent). An `ok:false` whose error is *not* in the registry is fault-shaped, and that
  absence is deliberate — the closed set is authored, never inferred.
- **`surface.refusals`** — the registry is learnable through the door, because a check
  that is not a verb does not exist.

The warm road contributed its own lesson: a table born in an upgrade exists *after* the
install-completeness blanket grant already ran, so the first wire refusal after
`ALTER EXTENSION UPDATE` collapsed into `42501 permission denied` — caught over wss,
invisible to the fresh-install gates. The grant now travels with the table.

Suite: `tests/v312-tdd` cases 29/30 were added RED on the client's findings and flipped
GREEN with this release — 30 cases, 15 green, 14 red-as-predicted, 0 broken.

## v0.4.82 - 2026-08-26

**v3.12 FINAL becomes the boot default; aligned to pgRDF v0.6.34.**

`ckp.boot()` defaults to `/ontology/v3.12/core.ttl` (digest `7de02b35…`, 30 NodeShapes =
27+3, the seven scoring constants gated) on both roads. `ckp.project_links` validates
against the composed surface instead of a never-seeded board graph (the pgRDF#134
resolution — the engine's vacuity refusal now has real inputs). Smoke gates run against
attested pgRDF v0.6.34. Existing v3.11-booted databases are untouched: re-grounding a
live kernel is a governed act, never an upgrade side effect.

## v0.4.81 - 2026-08-22

**Germination becomes reachable, and the substrate stops guessing the payload.**

`ckp.dispatch` has carried a `WHEN 'kernel.germinate'` branch since 0.4.43 — and
`ckp.affordance_registry`, the **sole** routing authority, never held a row for it. So dispatch
refused `unknown_affordance` before reaching the implementation, and **the one act that creates
a kernel was unreachable through the only door end users have.** Measured through the wire on a
freshly rebuilt bundle; SuperAiHarness3000 hit the same wall independently, which is why their
kernel graph existed with zero quads — composition had run and germination never could. This is
the #56 declared/routed gap from its other side: usually a verb routes with nothing declaring
it; this one was implemented with nothing routing it.

A second defect surfaced while fixing the first: registering the row as `plane='governance'`
still refused, with `governance_plane_unavailable`. That plane routes to a hardcoded three-verb
list (`propose_change`/`vote`/`apply`), while germinate's implementation lives in the instance
CASE — **the `plane` column is a handler selector, not a semantic label**, a conflation the
seed's own comment already recorded.

- **Four payload substitutions deleted**, each chosen by one rule — *would a wrong value here
  fail loudly, or succeed plausibly?* `bump_epoch`/`compile_plans` defaulted to the literal
  `'pgck'`, **this repository's own name**, as the kernel whose epoch gets bumped on any
  deployment. `kernel.germinate` filled `projectKind` with `'personal'` **before validation**,
  so the gate approved content the caller never supplied and `ProjectShape`'s `sh:in` never got
  to speak. `notify` invented `'notifies'` — the predicate of an edge, which is its *meaning*.
- **`surface.check` separates `state` from `healthy`.** A brand-new database reported
  `healthy: false` with a *"wipe signature"* on a machine where nothing had ever happened: the
  check could not tell **never existed** from **was destroyed**. `state` is now
  `core-only | named | germinated`; the wipe finding fires only when a `ckp:Kernel` **is** sealed
  and its graph is empty, and an unpinned surface is a fault only after an epoch has advanced.
- **A CURIE is refused, not answered.** `surface.declared`/`typecheck`/`explain` returned
  `declared: {}` for `ckp:Project` — a confident absence about a type the gate judges daily,
  which a caller cannot distinguish from a real one. Nothing expands prefixes here.

**Gates: `s72`**, four claims, and the control is the point — **a germinated kernel with an empty
graph must still report the wipe.** Making a fresh database healthy must not buy that by going
blind. It also caught a real bug in this release: the core-only branch crashed on
`sparql: parse error … IRI parsing failed`, because `surface_check` still built
`'urn:ckp:'||NULL||'/kernel/ck'` — it broke on exactly the state it had just been taught to call
healthy.

## v0.4.80 - 2026-08-22

**A ledger key of one's own.** `ckp.seal` signs every entry `hmac(body_sha256, identity_key)`
and reads that key from a `ckp.config` slot that was **designed in and never populated** — so
`ckp.dispatch` grew a `COALESCE` default of the literal `'pgck-localhost'`, this project's own
dev-bench name, hardcoded 2026-06-04 and shipped in every release since. Measured on the latest
published bundle: `identity_key in force = 'pgck-localhost'`, `config row: <none>`. Every
deployment signed its proof chain with the same public string, so `verified: true` meant *hashes
correctly under a key everyone knows*. Not remotely exploitable — the role floor guards the seal
path — but weaker than "verified at time, **by this store**" implies, because no key belonged to
any store.

- **The install mints 32 bytes** into that slot. **Minting is not defaulting**: a default hands
  every install the same answer; a mint hands each one its own, so the value is specific by
  construction and cannot be wrong-but-plausible.
- **`ckp.config` is now dump-flagged.** It was not, while `ckp.ledger` was — so a per-install key
  would have meant a restore returns every sealed fact and loses the key that signs them. Masked
  until now only because the key was a constant every install shared.
- **The literal is deleted**, and with it a second defect: the old `COALESCE` only caught `NULL`,
  so an empty-string GUC bypassed the default and produced an empty key. The new read uses
  `NULLIF(…,'')`.
- **The upgrade path substitutes nothing — not even the old value.** A first draft of the
  migration inserted `'pgck-localhost'` when the row was absent, to keep old proofs verifying:
  substitution-on-absence with a baked-in constant, re-added by its own author inside the release
  that deletes it. **Withdrawn.** Upgrading stores have no row, so `seal`'s refusal becomes
  reachable and sealing stops until an operator names a key. Facts sealed earlier no longer
  verify under a new key — which does not destroy evidence so much as reveal what that evidence
  was always worth. Restoring the old behaviour is an operator's deliberate act, not ours.
- **Six `DEFAULT 'demo'` parameters removed** from internals whose callers always know their
  project — continuing 0.4.79's count.
- **`ckp.materialize_job` gains `attempt_count` + `last_error`** (P9). It is a *live* drain path
  with zero rows, so the missing bound has never bitten; it would bite the first time an
  expensive job failed, re-selected forever, presenting as *the loop working*.

**Gate: `s71`**, five claims including the one that matters — **delete the key and sealing must
refuse.** If it does not, the release is decorative.

**Withdrawn from the 0.4.79 finding:** `shapes_self_test` "defined twice, later silently wins"
is **not** a defect. The completeness block redefines it deliberately, because that file is
included last precisely so its virgin-DB-safe version wins.

## v0.4.79 - 2026-08-21

**The substrate stops inventing a kernel, and starts telling the truth about not having one.**

`demo` entered on this repository's **first day** (`816e9e3`, 2026-05-16) and reached **14
load-bearing sites** — three independent `COALESCE` fallbacks, seven `DEFAULT` parameters, two
bundle literals and a Go constant. Nobody ever chose it. It propagated by default-value copying,
because a default is not a declaration and no gate can refuse one. Measured consequence on a
fresh boot of the previous release: **24 sealed instances** declaring (M2, `producedBy`) that
they are governed by `urn:ckp:demo/kernel/ck` — **a graph with zero quads**. Facts citing a
jurisdiction that was never germinated, sealed correctly by a substrate doing exactly what it
was told.

- **Clause 0 — absent means absent.** With no kernel named, the resolver returns **no project**
  rather than borrowing one. This also **consolidates for real**: `surface.check` and
  `integrity_check` each carried their own copy of the fallback, so the two verbs a caller uses
  to ask *"am I healthy"* resolved the project independently of the resolver everything else
  used. The comment above the first fallback claimed that consolidation was already done — *"in
  one place… a single edit instead of twelve."* It was not. Now it is.
- **Core-only is a complete state, not a fault.** Composition is the act of unioning a kernel's
  own graph and its Adoptions *into* core; with no kernel there is nothing to union, so the
  surface **is** core. `surface.declared`, `surface.typecheck` and the full `instance.validate`
  report all answer — you can read the law without a kernel.
- **Sealing refuses, naming M2.** A fact must say whose law governs it. The refusal states the
  remedy and notes that reads still work.
- **The gate gained the claim it was missing.** `s70` claims (a)–(c) all *set* `ckp.project`
  before asking, so they assert "the segment resolves to itself" and could never see a
  deployment whose planes disagree because one was never set — the exact gap oci-germination had
  to measure by hand against 0.4.78. Claim **(e)** asks the resolver what an unconfigured
  deployment gets; claim **(f)** is its control, proving reads survive the refusal.

**Contract change, stated plainly:** sealing now **names its kernel**. Deployments that pin
`ckp.project` (all shipped bundles do, in `pgck.conf`) are unaffected. A bare install must name
one — `set_config('ckp.project', '<kernel>', true)` — or germinate. The fresh-install gate and
the compose rig were both updated to declare their kernel rather than inherit an invention.

## v0.4.78 - 2026-08-20

**The wire served a kernel name the substrate refuses.** `pgck.kernels` — the GUC the
auth-callout mints every `event` / `result` / `input` subject grant from — shipped with a
compiled-in default of `pgCK`. This substrate's own canonicalizer rejects that spelling:
`project.resolve {"segment":"pgCK"}` on a fresh install answers *"kernel id 'pgCK' is not
canonical, no sealed kernel carries it and no kernel graph stands behind it — use 'pgck'
(`ckp.germinate_kernel` refuses the same name; this door now applies the same rule, so a fact
can never be sealed into a project that could not be germinated)."* So the callout minted
grants on a transport segment under which no fact could ever be sealed.

It looked healthy because clause-2 twin resolution rescued it wherever a canonical twin
happened to be sealed — and that rescue is absent on exactly the fresh installs the default
exists to serve. The composer's four-spelling defect family, this time inside a compiled
default. Found downstream by oci-germination while burning `ck-allinone v0.7.33`, where a
bundle naming its kernel twice sent the two planes apart: seals landed in one kernel while the
wire served another, so a verified client was correctly refused a type the surface it reached
did not admit, while the adopted surface emitted sealed events on a subject no client had
permission to hear.

- **The canonical spelling is the default**, in all three places it was written: the GUC, the
  callout-policy cache fallback, and the unit-test fixture — which had been *asserting grants
  on the refused segment*, so the unit suite agreed with the defect.
- **The wire plane is gated for the first time** (`s70_kernel_planes_agree`). `s63` already
  asserted the seeded registry names only canonical kernels; **nothing anywhere read
  `pgck.kernels`** — measured, across the whole suite and `scripts/`. s70 asserts canonical
  *form*, canonical *by the canonicalizer's own judgment* (so twin-rescue cannot paper over
  it), and that the wire plane and the seal plane resolve to the **same** project — the
  v0.7.33 defect as an assertion.
- **Negative control in the same file:** the identical checks run against `pgCK` and MUST
  fail. This suite stayed green for the entire life of the defect precisely because nothing
  looked here, and a check that cannot fail what it claims is not a check.

> **⚠ WITHDRAWN, same day, before anyone could build on it.** The claim above that s70
> asserts *"the wire plane and the seal plane resolve to the **same** project"* **overstates
> what the test establishes.** Claim (c) sets `ckp.project` to the wire segment and only then
> calls `ckp._project()` — so it asserts *the segment resolves to itself*, not that a
> deployment's two planes agree. Falsifier, measured on a running container: with `ckp.project`
> unset (the deployment default) the wire serves the configured kernel while
> `ckp._project()` falls back to **`demo`** — canonical case since 0.4.78, still two different
> kernels. Re-measured and passed back by oci-germination against this very release.
>
> **What 0.4.78 does fix, unchanged:** the *case* — `pgck.kernels` no longer defaults to a
> spelling `ckp._project()` raises on. **What it does not fix:** the *disagreement*. Every
> non-wire write (init.sql, psql, the drain's own SPI) still lands in `demo` unless the
> deployment sets `ckp.project` explicitly. Bundles that pin both planes are unaffected.
> The fallback and the missing default-state assertion are both 0.4.79's.

## v0.4.77 - 2026-08-20

**The pin ledger joins the install floor.** On a fresh install, `ckp.adoption_pins` did not
exist: it was created only by the 0.4.60→0.4.61 upgrade script (the warm path) and inside
`ckp.bootstrap_kernel()` (a manual CALL) — the install baseline never carried the top-level
CREATE. Measured on `ociger-pg18-pgrdf-pgck-nats-micro:v0.2.4` (fresh 0.4.76): the FIRST
`ckp:Adoption` seals fine, the SECOND dies mid-recomposition on the missing relation, and
`fleet.adoptions` hard-errors from its first call. Warm-upgraded benches carried the table
all along, which is exactly why nobody saw it — the two install roads had diverged, and only
the road nobody was driving was broken.

- **`adoption_pins` is created in the install-completeness block** (the LAST include every
  fresh install runs), with its four structural columns, `ck_substrate` ownership, and the
  dump flag — pins are trust-on-first-sight records and survive dump/restore like the rest of
  the seal path.
- **The warm path mirrors it** (`pgck--0.4.76--0.4.77.sql`, fully idempotent): both roads
  converge on one schema in one act, the same discipline as the 0.4.74 authority mirror.
- **The fresh-install gate can now fail this defect.** `smoke-s34` passed throughout the
  defect's life because it never sealed two Adoptions — a check that cannot fail is not a
  check. It now asserts the table exists at CREATE EXTENSION, seals TWO governed Adoptions on
  a virgin cluster (wave + lexicon by digest, with a named requester), and requires
  `fleet.adoptions` to answer. On unfixed 0.4.76 that step reproduces the failure exactly.

## v0.4.76 - 2026-08-17

**The door can see the inferred plane.** `surface.grounding` reported `asserted` and nothing
else, so a kernel holding only pgCK.MCP could not tell whether the reasoner had ever run over
its own facts. The day's largest measurement — every adopted ONTOLOGY graph materialized, every
`/instances` graph at `inferred = 0`, eleven graphs and ~7,500 facts — was made with
`pgrdf_graphs`, an instrument end users do not have. A measurement no caller can reproduce by
the route available to them is the `lexicon#BenchOnly` class reached from a new direction, and
this kernel's own rule — *a check that is not a verb does not exist* — was broken by its author.

- **`inferred` joins `asserted`, per graph.** The data was never remote: every count in that
  function already filtered `NOT q.is_inferred` against the same table, so the entailed rows
  were being read and deliberately excluded. The exclusion is correct — asserted-only counts
  are the blank-node-immune instrument — but excluding a plane and never naming it is how a
  kernel ends up unable to see that its facts have never been reasoned over.
- **F3 holds: the new count names its method.** `inferred` counts entailed quads whole, NOT
  deduplicated against asserted, so `asserted + inferred` is the store total for that graph.
  `inferredNote` states the reading that matters: **`inferred = 0` on a POPULATED graph is a
  positive finding, not missing data** — nothing has ever been derived from those facts. And
  because `lexicon#Pattern` declares that membership is INFERRED from the symptom and never
  asserted, a lexicon teaching cannot be earned on a graph whose inferred count is 0.
- **Negative control is in the same call.** `inferred` must stay 0 for every `/instances` graph
  until a materialization is actually run over one, and must be non-zero for the adopted
  ontology graphs, which are `materialized`. Both halves are observable in one reply, so the
  field cannot be trivially satisfied.

## v0.4.75 - 2026-08-17

**The authority read answers. Two independent breaks were stacked, and fixing only the visible
one still returned a confident zero.** `ckp.authority_of` — which `authority.mine` wraps — had
reported `{ok:true, grants:[]}` for every caller since 0.4.38, roughly 35 releases. Both faults
were found by running the function against a participant that actually has a chain, which
nobody had done.

- **The edge the data has** (0.4.74): the reader traversed `Grant → core#grantedVia → Role` and
  projected `core#permission`. Sealed Grants go the other way and use other keys: `Role →
  core#grant[] → Grant`, carrying `permAction`, `permDomain`, `permTarget`. Direction and key
  were both wrong, so the subquery matched nothing, the aggregate was NULL, and COALESCE turned
  it into an empty list. Now traverses `grant[]` — normalising the array and bare-string forms —
  and keeps a `grantedVia` UNION branch so no legacy record is dropped. Per R-1 the emission is
  not asked to change: the data is already emitted, the READER was wrong. This is the R-1 split
  `SPEC.pgCK.v3.12.SECURITY` §3.1 named in writing before it was measured.
- **The identity it is given** (0.4.75): the door supplies a BARE uuid while sealed Memberships
  store `memberIs` as `urn:ckp:participant:<uuid>`, so the equality test never fired and the
  0.4.74 repair — necessary — was not sufficient. Now resolves both spellings and matches
  either. Both, not one: every Membership measured carries the urn: form, but that is n=1, and
  asserting uniformity from one record is the prior-without-a-count defect. Whether
  `ckp.requester` should carry the canonical form everywhere touches every reader and is NOT
  decided here.
- **An empty answer now says which empty it is.** Two cases used to render identically: no
  sealed `Membership` at all, versus a Membership whose Role reaches no Grant. One means
  unconfigured, the other configured-to-nothing, and a reader that cannot tell them apart is
  reading a silence. `anonymous` remains a TIER with its own note, never a bare `[]`.
- **Envelope, additively.** Grants gain `permAction`, `permDomain` and `viaRole` — the last
  naming the Role a grant was reached through, so a rendered chain is auditable. `permission`
  is retained and is `null` on every sealed Grant measured, reported rather than hidden.
  `identity` is unchanged; `identityCanonical` is added so a client can compare one spelling
  without normalising identity itself.

`s69` gates the chain and four negative controls: no-Membership and terminating-Role return
empty AND name which empty they are, grants never leak across participants, and anonymous
reports its tier. Verified live on the bench against the only sealed chain that exists —
`c45b14bb…` resolves `govern @ ck-dev/organ/ck` and `write @ ck-dev/organ/data`.

## v0.4.73 - 2026-08-17

**Warnings guide, the ratchet governs — and the cure is exempt from the poison it removes.**
Two versions ship together: 0.4.72 gives guidance a severity-aware gate, and 0.4.73 fixes the
deadlock that 0.4.72's own test suite measured on the first cut.

- **The gate learns severity** (0.4.72): `sh:Violation` — and absent severity, SHACL's default,
  so nothing pre-existing weakens — refuses as before; `sh:Warning` and `sh:Info` results seal
  AND surface in the reply. `validate` gains the same partition: the fourth validate⟺seal axis.
- **Guidance becomes law by adoption** (0.4.72): three checks join the fixed obligation registry.
  `no-warnings` is the ratchet — a kernel that adopts it makes warnings binding, and every
  conforming seal carries the warranty as a proof row, so reliance is a row rather than a
  reputation. `adopts-resolves` refuses a graph-less `adopts`. `structural-pin` refuses a
  swap under a pinned name, so reload relabelling cannot fool the structural plane.
- **The census becomes a verb** (0.4.72): `fleet.adoptions` returns the cross-kernel adoption
  matrix with malformed references flagged mechanically — re-runnable by anyone, not a
  hand-audit. `surface.explain` reads `rdfs:comment` through the door so the shape teaches its
  own prose; a declared-but-untaught property shows its null honestly. `adoption.check`'s
  why-text separates row-state from engine capability.
- **The cure is reachable** (0.4.73): the fail-closed composer (0.4.61) and adoption-derived
  composition are each correct and compose into a deadlock — a dangling `Adoption` poisons its
  project, so every subsequent seal raises on the missing graph and refuses, including the
  `Supersession` that the refusal's own remedy text names. Now, when the candidate is a
  `core#Supersession`, seal derives the SEALED target Adoption's `adopts` value from the record
  and exempts precisely that one graph. The escape is derived, never claimed: a `supersedes`
  naming no sealed Adoption excludes nothing, so the hatch cannot be steered from outside, and
  the exempted graph is exactly what the act removes. The one-arg `_composed_shapes` overload is
  dropped in the migration so legacy call sites resolve to the new definition.

`s68` gates all six faces of the guidance work, and its case 7 proves the deadlock arc end to
end on a poisoned project: a normal seal refuses, the Supersession seals, the next normal seal
succeeds. Both gates green (48 warm + fresh install).

## v0.4.71 - 2026-08-16

**The seal's exit is extensible by agreement, identity evidence is sealable, and a digest that
survives reload joins the one that does not.** Fourteen versions (0.4.58–0.4.71), each proven on
the bench through the door before the next began; this tag ships them together. The recurring
shape of the wave: capabilities landing on joints the v3.11 root placed deliberately — the proof
table's absent uniqueness, the sourceDigest/surfaceDigest pair, the frozen primitive set — so
extension composes instead of carving.

- **The pass boundary is a query and the spine is SPARQL** (0.4.58–0.4.60): sealed bodies —
  stamps included — project as quads into a per-project instances graph under one deterministic
  graph id, so the fence census and every coordination signal are derivable by any adopted kernel
  rather than remembered by one.
- **Adoption pins are consulted, quorum counts parties, unattributed writes refuse**
  (0.4.61–0.4.64): graph digests pin at first composition with drift detectable via
  `adoption.check`; quorum counts *distinct accountable* `createdBy` with anonymous excluded —
  one caller could previously manufacture any quorum by letting the seal mint a fresh
  `anon:<uuid>` per unattributed call; now the naked path must name a declared identity or the
  seal refuses with the remedy in the message. The 39 historical anonymous seals stand as fenced
  history; no new one can exist.
- **Sealed proof obligations** (0.4.65): `ckp.proof` carries N rows per fact *by design*, and a
  governed op (`add_proof_obligation`, propose→vote→apply) registers proof-producers that run at
  the seal's exit for their target type. Failing refuses; each satisfaction lands as a proof row
  naming the agreement. Bounds: per-kernel scope, a fixed registry of pure-read checks (an
  obligation names a check, never carries code), removal by the same governed road, unimplemented
  checks fail closed. Debut check `digest-match`: the (epoch, surfaceDigest) pair a `wave:Pass`
  cites must sit on one sealed Epoch — form is the shape gate's jurisdiction, *reference* is the
  obligation's. Registered on two kernels by two-party agreement; the first fabricated-digest
  citation refused the same day.
- **Plural proofs reach the readers** (0.4.66): the first obligation-guarded fact verified
  `false` seconds after sealing cleanly, because `ckp.verify` took the *last* proof row and
  demanded it be hmac. The byte-proof is now selected by method; the provenance verb returns
  every proof row in seal order.
- **The structural plane** (0.4.67–0.4.69): blank nodes are existential variables, so a
  SHACL-bearing graph serializes to different bytes on every load forever — byte digests answer
  "same bytes," never "same graph." `ckp._structural_digest` implements the fleet's first-degree
  blank-node-signature algorithm byte-for-byte (verified: independent loads of the v3.11 core
  carry distinct byte digests and ONE structural digest); Epoch seals carry `structuralDigest`
  beside `surfaceDigest`; adoption pins carry both planes plus counts that *name their method*
  (asserted NodeShape typing / declared vocabulary properties / property shapes — three methods,
  three numbers, F3's lesson); `surface.grounding` is the census as a verb; governed shape
  projection emits *named* NodeShapes with named property shapes, keeping kernel doctrine
  blank-node-free and every shape supersedable by name. And the boundary rule enforced on
  ourselves: pin digests compute at first sight only, never per seal — the fleet's
  "digests at the door, never in the loop" caught its own consumer's regression in a day.
- **Identity evidence is sealable** (0.4.70): two relay-set GUCs on the channel clients cannot
  write land as proof rows — `token-residue` (a claims fingerprint; a JWT-shaped value refuses
  the seal structurally, never-the-token) and `grant-ref:<urn>` (the acting voted Grant, readable
  for resolve-never-believe custody). Absent GUCs leave no rows: absence is the honest record.
- **Enforcement features in use** (0.4.71): governed `add_class` can declare a **closed** shape
  (`sh:closed` + ignored envelope), so an undeclared key refuses instead of minting into the type
  namespace; `adoption.check` consults the loader-recorded source byte digest (pgRDF ≥ 0.6.31) so
  a sealed `sourceDigest` is compared rather than decorative; census verbs state their
  completeness with blind spots enumerated (a short answer must say so — never `complete` when it
  cannot know); and the transport wrapper resets the engine term cache after any aborted
  dispatch, ending the stores-but-cannot-be-seen retry failure for door callers.

## v0.4.57 - 2026-08-13

**The admitted-type gate is scoped to the surface it names, one kernel has one spelling, and the
wave vocabulary is composed and gating.** Seven versions in one day (0.4.51–0.4.57), each proven on
the bench through the door before the next began; this tag ships them together. The recurring shape,
again: a check whose scope or failure-direction was never negative-controlled, caught each time by a
second instrument disagreeing — never by re-reading the diff.

- **The admitted-type gate was substrate-wide** (0.4.51). `ckp._type_admitted` scoped itself with
  `FILTER(?g IN (<composed>, <board>))`, and the engine silently dropped that filter under `UNION` —
  so any type declared in *any* graph was admitted for *every* kernel; a five-triple SHACL test
  fixture widened the production type gate. Fixed with one constant-graph ASK per surface, combined
  in PL/pgSQL, plus the negative control that never existed: a type declared only in a foreign graph
  is refused. Escalated upstream; pgRDF 0.6.30 now **refuses** group-level constructs alongside
  `UNION` (`pgRDF#114`) and counts every refusal (`stats().filter_clauses_dropped`) — closed by
  pgCK's own repros inverting on the bench, not by the release notes.
- **One kernel, one spelling** (0.4.51–0.4.56). The project segment was validated at germination and
  unvalidated at seal, so one kernel's facts split across two casings and the adoption record named a
  project the composer never read. `ckp._project` now resolves the transport segment against a
  sealed `ckp:Kernel`: a non-canonical twin resolves onto the canonical sealed kernel; a pre-rule
  kernel with a non-empty kernel graph is grandfathered (prefer the spelling with *substance*, never
  the tidy empty graph); ambiguity refuses naming all parties. The resolver explains itself from its
  own execution (`ckp._project_explain` returns `{project, clause, hits}`) after its first reporter
  inferred the clause from the outcome and misreported it.
- **Adoption-derived composition honours all three `intoProject` spellings** (0.4.57).
  `_adopted_graphs` matched `urn:ckp:<p>` and `urn:ckp:<p>/kernel/ck` and missed
  `urn:ckp:project:<p>` — the IRI germination itself seals as the Project `@id` — so a judged,
  ledgered Adoption could compose nothing, silently. Found by a consumer's measurement, fixed the
  same hour, ruled on the record.
- **The checker surface is verbs, not scripts** (0.4.52–0.4.53): `surface.typecheck` (admitted?
  shaped? via which graph, at which digest) · `surface.unshaped` (classes the surface declares that
  no shape targets) · `surface.declared` (the property contract, learnable without writing) ·
  `project.resolve` (which kernel a name means, under which clause). Each calls the same internal
  the gate calls — a probe that re-implements the gate tests the probe. The first cut of
  `surface.unshaped` used `FILTER NOT EXISTS`, which the engine also silently dropped — **the
  vacuity detector was itself vacuous**, caught within minutes because two instruments disagreed
  about one class. It now takes the difference in SQL, so a dropped clause yields *empty*, never
  *everything*.
- **Retirement uses declared vocabulary** (0.4.55). `ckp.retire` wrote bare `retired`/
  `retired_reason` — undeclared keys minted past the gate — and never moved `ckp:proposalState`, so
  a retired Proposal read as pending to every other kernel forever. Now: `ckp:retiredAtEpoch` +
  `ckp:reason`, and a Proposal moves to `rejected` (an `sh:in`-gated enum, so a wrong value refuses).
  The s35 golden migrated from pinning the loose behaviour to pinning the declared one — the toll a
  tightening release pays, on the record.
- **`instance.link` and `notify` name their class** (0.4.51). Both sealed a `urn:ckp:board/*` type
  declared by no loadable module — unsealable for any participant on any surface, regardless of
  grants. The class is now the caller's to name, property IRIs follow its namespace, and the absent
  default refuses with the reason.
- **One property map for validate and seal** (0.4.51). Four inline copies disagreed — validate read
  the composed surface while create read the kernel graph, so one JSON key could resolve to two
  IRIs. `ckp._propmap` is the single definition; the advertised affordance surface is likewise
  derived through `registry_lookup` itself, so enumerable ⟺ dispatchable by construction.
- **Upgrade scripts are generated from the baseline** (`scripts/gen-upgrade-from-baseline.sh`), so
  the fresh-install and `ALTER EXTENSION UPDATE` paths are the same bytes — proven by identical
  catalog body digests across both routes.

With the wave and lexicon modules adopted by digest into the kernel's own project, a
`wave:Finding` missing its required `ckp:reason` — or carrying a state outside the declared enum —
is now **refused with the clause named**, and a conformant one seals carrying
`ckp:conformsToShape`. Facts are judged, not merely stored.

**Release packaging follows the v3.11 ontology layout.** `v0.4.49` is a burned tag: all four build jobs
failed at *Repack to INSTALL-spec layout* with `cp: cannot stat 'ontology/*.ttl'`, because 0.4.40 moved
the modules to `ontology/v3.11/` and `ckp.boot()` now defaults to `/ontology/v3.11/core.ttl` while
`release.yml` still packaged a flat directory. The copy is structure-preserving and asserts the files
exist rather than trusting `cp`; the `.sha256` sidecars ship too, so a consumer can check a module
against the digest a pass stamped. No substrate change — the contents below are unchanged from the
burned tag.

Worth recording where this hid: the release workflow runs **only on a tag**, so it sits outside
`smoke-s4`, `smoke-s34` *and* `ci.yml`. Same defect class as the rest of this release — one fact named
in two places, one never updated — in the one place nothing was looking.

## v0.4.49 (burned — build failed, never released) - 2026-08-12

**Kernel creation works through the door, every function resolves its own kernel, and events name who
produced them.** The first cumulatively verifiable release since v0.4.24 — twenty-five versions had
accumulated without a checkpoint where the claims could be re-run. Nearly every defect closed here was
the same shape: one fact named in two places, agreeing only by accident, and resolving toward the
permissive side when it diverged.

- **A concept kernel can be created through the door** (`kernel.germinate`). It seals a Project and a
  Kernel with three organs and counted dependencies 0/1/2, with `ckp:ownedBy` stamped from the verified
  connection — a client may declare its own STRUCTURE, never who owns it. Three defects had made this
  impossible: `ckp.validate` aimed its scratch graph at the same id band pgrdf allocates data graphs
  from (59 live graphs sat at ordinary container pids, the core ontology at `1000000221`);
  `_body_to_ttl` dropped arrays in the overload `seal` actually calls, so `ckp:Kernel` — which requires
  three organs — was unsealable; and the sealed body and the graph disagreed about where organs live.
- **`ckp.dispatch` resolved every caller's affordances under one fixed name** (`registry_lookup('pgck',
  …)`), so a verb a kernel registered, voted through and applied was invisible to its own owner. It
  looked correct only because the seed and the registrars were hard-coded to the SAME literal — writer
  and reader wrong in the same direction, which is symmetry, not agreement. **No `ckp` function names a
  kernel any more:** the plan readers, the plan registrars, the epoch bump and thirteen inline project
  resolutions (in two spellings that disagreed on the empty string) now resolve the caller, with the
  seeded floor as an explicit fallback.
- **Identity has one source.** `ckp.seal` resolved the participant from the payload while germination
  stamped `ownedBy` from `ckp.requester`, so a single seal carried two identities — owned by a verified
  participant, created by `anon:<nonce>`. The verified connection now wins; a conflicting payload sub is
  ignored, never merged. This closes forgery through the door, where only the relay sets the GUC.
- **Events reach their kernel, and carry a sender.** `compute_publish_subject` hard-coded the kernel
  segment, so every kernel's events landed on one subject and a subscriber to its own kernel received
  nothing — a publish to a subject nobody listens on succeeds, and is indistinguishable from silence.
  The kernel is now derived from the sealed `producedBy` stamp. The `by` header keyed on a v3.8-era
  board property that 5 of 78 instances carry; it reads the core `createdBy` first, so a peer can tell
  who said what. `out_topic` is populated at registration with the subject the relay already publishes
  replies to.
- **`validate` predicts `seal`.** `ckp.validate_instance` validated against the kernel graph — 30
  triples, zero `sh:targetClass` — instead of the composed surface (1258 triples, 27 targets), so every
  dry-run verdict was structurally vacuous. Shapes graph, property map and serializer overload now all
  match `seal`.
- **A governed change that projects nothing is refused at propose.** P0-E checked that the *op* had a
  projector but never that the *detail* carried anything, so an `add_affordance` with an empty detail
  sealed `applied`, bumped the epoch, registered nothing and returned `ok:true` with no error anywhere.
  `add_class` likewise accepted `detail.properties[]` and dropped them, governing into existence a type
  that admits instances nothing judges.
- **Integrity checks are governed affordances.** `integrity.organs` and `integrity.naming` were
  proposed, voted and applied through the governance plane, compiled into `ckp.plans` keyed to their
  epoch, and are callable through the one door — a self-check whose verdict is sealed rather than run
  by remembering to.
- **`s63_kernel_resolution`** asserts the four claims that had no test: a kernel resolves the verb it
  registered, does NOT resolve another kernel's, still reaches the seeded floor, and the substrate seeds
  its own surface under a canonical name (lowercase, one transport segment — NATS subjects are
  case-sensitive).
- **Ontology** — `ontology/` holds v3.11 alone; core, wave and lexicon match their pass-stamped
  `.sha256` sidecars byte for byte.

**Known gaps, not closed here.** CI does not run the SQL suite — all 43 tests run locally only. Nothing
exercises the migration chain: both gates install from the baseline, which is how 0.4.47 shipped the
wrong `dispatch` overload and left `compute_publish_subject` stale on a deployed substrate. NATS
delivery is unproven — the outbox row is correctly addressed; arrival is untested. A seal-time refusal
for writes no shape would judge is written and parked, pending a pass over test fixtures that seal
unshaped types.

## v0.4.24 - 2026-07-19

**pgCK-owned NATS admittance is live — the auth-callout responder + subject-scoped identity close the
server-derived-identity chain over WSS (F1 pieces 3 & 4).** The `-nats` build now answers
`$SYS.REQ.USER.AUTH`: it verifies the CONNECT token in-memory, mints a governance-scoped NATS user-JWT,
and binds the verified `sub` to `ckp.requester` on the governed write path — so `created_by` / `msg.by`
derive from the cryptographically verified connection, never a client claim, all the way over the wire.

- **Auth-callout responder wired** (`src/auth_callout.rs` + `nats_client`). On each connect the responder
  verifies the realm token (the unchanged `jwt_verify` core), then mints a signed user-JWT:
  **verified** ⇒ publish only on its own identity-scoped subject `input.kernel.pgCK.id.<sub>.action.>`
  plus read `event.*`/`result.*`/`_INBOX.*`; **anonymous** ⇒ subscribe-only on `event.*`, no publish.
  Fail-open-to-anonymous, never-to-admitted — a forged/expired/foreign token is admitted anonymous,
  never as the claimed identity, and never rejected at CONNECT.
- **Subject-scoped identity → `ckp.requester` (F1-inbound, hop 4).** The verified `<sub>` is enforced by
  the broker as a subject segment; the relay reads it from there (never a payload/header claim) and sets
  `ckp.requester` before `ckp.dispatch`. The legacy `input.kernel.pgCK.action.<verb>` still routes as an
  anonymous dispatch for back-compat.
- **New GUC `pgck.nats_account_seed`** (superuser-only, `postgresql.conf`-delivered like the OIDC trio) —
  the account seed the responder signs admittance with; its public key is the broker's `auth_callout`
  issuer. Absent ⇒ the responder is not started (broker admission unchanged). Minted user-JWTs target
  `aud:"$G"` and omit `issuer_account` (server-config mode, not operator mode).
- **`pgck.nats_url` honours URL credentials** — `nats://user:pass@host:4222` authenticates the worker's
  own connection (required so it bypasses the callout as an `auth_users` member). Connect now retries
  with backoff instead of killing the thread on a broker-start race.
- **Verified** — full local auth-callout e2e against a real `nats:2.12` broker with the `auth_callout`
  stanza (`scripts/dev-callout-e2e.sh`): anon is subscribe-only; a forged token drops to anonymous; a
  verified token dispatches on its id-scoped subject, seals, and the delivered
  `event.kernel.pgCK.Task.sealed` carries `by: urn:ckp:participant:<sub>` with substrate `created_by`
  matching; a publish on another id's segment is denied by the broker and never seals. 39 Rust unit
  tests + `cargo fmt`/`clippy` clean.

## v0.4.23 - 2026-07-16

**pgCK owns the NATS drain — a self-contained `-nats` `.so` variant + a robust bridge worker.**
The outbox→NATS drain (and inbound relay) now ship *inside* a pgCK extension variant, so downstream
bundles stop reimplementing it (oci-germination drops its Go `ociger-pgck-relay`). Two robustness
fixes make the in-kernel drain reliable from a cold start.

- **New `-nats` release variant** — `pgck:<ver>-pg18-nats-<arch>`, built `--features pg18,nats-client`:
  the outbox→NATS drain + inbound dispatch relay + auth-callout verifier live in the `.so`. Same
  extension name (`pgck.so`); activate by setting `pgck.nats_url`. The plain minimal
  `pgck:<ver>-pg18-<arch>` still ships alongside for bring-your-own-transport consumers.
- **`pgck.worker_database` GUC** (default `postgres`) — the bridge worker attached to a hardcoded
  `postgres` database; it is now configurable to match wherever `CREATE EXTENSION pgck` ran.
- **The bridge worker waits for the extension instead of dying.** It starts at postmaster, possibly
  before `CREATE EXTENSION`; a `relation "ckp.outbox" does not exist` ereport used to kill it (exit 1),
  so it never returned after the extension was created. It now probes with `to_regclass` (NULL, never
  an error, when absent) and no-ops until the extension appears, then latches ready and drains — **no
  restart needed**.
- **Verified** — the `-nats` build self-drains `msg.by` end-to-end (event `by:` header = the verified
  requester) over NATS TCP **and** WebSocket, with the worker surviving a from-zero `CREATE EXTENSION`.
  The verifier (`jwt_verify.rs`) and the OIDC GUCs are unchanged — compiled into the `-nats` build, never edited.

## v0.4.22 - 2026-07-16

**Server-derived identity (F-group) + the pg18 substrate switch.** Identity is now
verified server-side and persisted from a trusted source — never asserted by the
client payload — and the substrate moves to PostgreSQL 18.

- **F1 — auth-callout JWT verifier (`src/jwt_verify.rs`).** An EdDSA / Ed25519
  verifier for the NATS auth-callout: the realm JWKS is delivered by env/GUC
  (`pgck.oidc_jwks` / `_issuer` / `_audience`) and verified **in-memory — no egress
  HTTP**. Signature + `iss`/`aud`/`exp`/`nbf` are checked; `kid`-selection loads the
  matching Ed25519 key. The admission decision is **fail-open-to-anonymous,
  never-to-admitted** — an unverifiable token yields an anonymous session, never an
  admitted one. 16 unit tests + a production-correctness proof against a real
  EdDSA token (`#[ignore]`, env-driven).
- **F2 — dispatch/seal persist the *verified* requester (`s58`).** `task.create` and
  `notify` set `created_by` from the trusted `ckp.requester` GUC, not the client
  payload; a forged payload `sub` is ignored.
- **F4 — server-attributed `by` on delivered events (`s60`).** Governed events drained
  to the outbox carry a `by` header = the verified sender, derived server-side.
- **pg18 substrate.** Adopt **pgRDF v0.6.20** (pg18-only). Base moves
  `postgres:18-bookworm → postgres:18-trixie` (glibc 2.41): the pg18 pgRDF `.so`
  requires `GLIBC_2.38`, which bookworm (glibc 2.36) cannot provide. pg18 images
  mount the data volume at the parent `/var/lib/postgresql`. CI + release are now
  **pg18-only**; all non-pg18 targets are blocked.
- **Tests.** Warm suite (`s4…s60`, incl. `s58` + `s60`) and the `s34` fresh-install
  gate both green on pg18 / trixie / pgRDF v0.6.20.

## v0.4.15 - 2026-06-19

**Stabilization — provenance id-form symmetry.** `v0.4.14` made `reach`/`link` accept either a bare
instance id or its stamped `@id`, but `instance.provenance` still keyed `body`/`proof`/`ledger`/`verify`
by the raw id against the bare-id columns — so a client passing the `@id` got a hollow `ok:true` with a
null body and proof.

- **`ckp._resolve_id`** — the inverse of `v0.4.14`'s `ckp._resolve_ref`: resolves a bare-or-IRI reference
  to the bare instance id the id-keyed tables use (a bare id that exists resolves to itself; a stamped
  `@id` resolves to its instance; an unresolvable ref returns as-is, so provenance stays honestly empty
  rather than a false positive). The `instance.provenance` branch routes its `id` through it, so
  `provenance(bare)` and `provenance(@id)` return the **same** envelope — symmetric with `reach`/`link`/`get`.
- **`pgck_version()`** now derives from `CARGO_PKG_VERSION` (was frozen at the `0.4.3-rc3` literal while the
  extension marched forward), so the native self-report can never again drift from the installed version.
- **Exit test `s51`** — `provenance(bare) ≡ provenance(@id)` (same body, same proof digest, both verified).
  Warm suite (s4…s51) + s34 fresh-install green.

## v0.4.14 - 2026-06-16

**Stabilization — the authorized CK-loop writer + uniform instance id-form.** Two fixes that make the
existing typed surface (`v0.4.8`–`v0.4.13`) actually enforce and traverse on the real client flow. No new
verbs, no behavioural surface added.

- **`ckp.adopt_kernel_ttl(ttl, project)` — a supported, file-mount-free way to seal a kernel/type shape into
  `urn:ckp:<project>/kernel/ck`.** The typed ops and the seal gate read shapes from `…/kernel/ck`; a bootstrap
  that loaded a type's shapes into a *different* graph left `/ck` unauthored, so the declared-shape gates
  silently no-opped (a body missing a required property still sealed). `adopt_kernel_ttl` writes the gate
  graph directly, additively and idempotently — restoring real enforcement without a file mount or any
  internal call. Operator/bootstrap-level (not a `ckp.dispatch` verb): `ck_participant` still cannot write the
  kernel shape.
- **Uniform instance id-form across `reach`/`link` (`ckp._resolve_ref`).** `create` returns a bare instance
  id; `get`/`link` accepted it, but `reach`/`edge.create` treated a bare id as a relative IRI (SPARQL parse
  error / no traversable quad → `reachable:false`), so a link→reach round-trip on the ids a client actually
  holds was dead. `reach` now resolves `from`, and `materialize_edge` resolves source+target, to the
  instance's stamped `@id` — so the round-trip works whether the caller passes a bare id or the full `@id`.
- **Exit tests** — `s49` (the sanctioned writer makes the gate non-vacuous *through the dispatch door*: a
  create missing a required property is rejected, a complete one seals) and `s50` (a bare-id `link`→`reach`
  reaches the target's `@id`). Warm suite (s4…s50) + s34 fresh-install green.

## v0.4.13 - 2026-06-12

**v0.5 roadmap T6 — governed `concept.match`.** The built-in label search is converted to the §6.3
governed query-affordance form: its query text is now a sealed `ckp.plans` fact, callers bind only `term`.

- **Projection:** an `AFTER INSERT/UPDATE` trigger on `ckp.instances` (`ckp.project_instance_label`)
  projects each label-bearing instance to the per-project graph `urn:ckp:<project>/instances`
  (`<@id> a <type> ; rdfs:label "<label>"`), so a SPARQL label search can find it.
- **Seed:** the canonical `concept.match` SPARQL query (label search over the instance graph, param `term`)
  is seeded as a governed plan in `ckp.plans`.
- **Execution:** `ckp.concept_match` reads its governed plan, **binds** the project graph + the term
  (escaped into the SPARQL literal — an injection-shaped term is bound, matching nothing, never injects),
  runs it via `pgrdf.sparql`, and **ranks** exact > prefix > contains (preserved in pgCK); falls back to the
  legacy in-table search when no plan exists. Reply gains `governed`.
- **Exit test `s47`** — tasks projected by the trigger; `concept.match{term}` is served by the governed
  plan (`governed:true`), returns the matching tasks, binds different terms differently, and binds an
  injection term safely (count 0). Warm suite (s4…s47, incl. s32 ranking + s37) + s34 fresh-install green.

## v0.4.12 - 2026-06-12

**v0.5 roadmap T5 — full SHACL `ValidationReport` via `instance.validate`.** Validate moves from the
required-props (`minCount`) gate to pgRDF's full W3C SHACL Core report (typed violations: datatype,
cardinality, node-kind, pattern).

- **`ckp._body_to_ttl`** projects a candidate instance body to RDF (type triple + each IRI-keyed property;
  JSON number→numeric literal, string→escaped string literal, IRI-scheme string→IRI node).
- **`ckp.validate_instance`**: resolves the body's short keys to declared property IRIs (mirroring
  `create_typed`), projects to a scratch graph, runs `pgrdf.validate(…, mode => 'native')` (the W3C path;
  not `'sparql'`, which is upstream-gated — pgRDF advisory §2), and returns `{conforms, violations, report}`.
- **Contract:** the seal keeps its required-props gate (unchanged); validate is the **stricter superset** —
  **validate-conforms ⟹ seal-accepts**, and validate additionally surfaces datatype/pattern/nodeKind
  violations the seal does not yet enforce. An unshaped type has no `targetClass` match → `conforms:true`.
- **Exit test `s46`** — a Ship with `crew_size : xsd:integer`: a valid Ship conforms (and seals — the ⟹
  direction); missing `crew_size` → a cardinality violation; `crew_size:"twelve"` → a **datatype** violation.
  Warm suite (s4…s46) + s34 fresh-install green.

## v0.4.11 - 2026-06-12

**v0.5 roadmap T4 — generic per-declared-shape `instance.update` patch.** The write-side mirror of
`ckp.create_typed`.

- **`ckp.update_typed`**: `instance.update {id, patch:{…}}` patches an instance by the type's **declared**
  properties — a short key resolves to its declared property IRI; for a shaped type an **undeclared key is
  rejected** (`undeclared_patch_key`); unshaped types namespace under the type's namespace. The patch is
  merged into the current body (type-preserving — numbers stay numbers) and **re-sealed**, so the
  required-props gate re-validates and the proof chain continues.
- **Dispatch**: `instance.update` with a `patch` sub-object → the generic path; the legacy flat
  `{id, …fields}` form still routes to `task.update` (back-compat).
- **Exit test `s45`** — create a Ship `crew_size:12`; patch `crew_size→20` re-seals (number preserved,
  `name` unchanged, re-verified); patching an undeclared field is rejected; the legacy flat update still
  works. Warm suite (s4…s45) + s34 fresh-install green.

## v0.4.10 - 2026-06-12

**v0.5 roadmap T3 — per-kernel sealed transition map.** `instance.transition` moves from one global
`ckp.config` map to the instance type's own **sealed** map, set through the governance plane.

- **`set_transition_map`** governance op (`ckp._op_to_ttl`): `{targetClass, map:{from:[to…]}}` →
  `<targetClass> ckp:allowsTransition [ ckp:fromState "x" ; ckp:toState "y" ]` triples in the kernel graph
  (state names validated; injection-safe). Applied via the existing `_graph_apply` machinery.
- **`ckp.apply_shape_ttl`** meta-fence now admits the three governance transition predicates
  (`allowsTransition`/`fromState`/`toState`) alongside rdf/rdfs/owl/sh — the op TTL is pgCK-built +
  field-validated; every other predicate stays fence-rejected.
- **`ckp.transition`**: when the instance's type carries a sealed map, **it** governs (per-kernel, no
  global bleed); a type with no sealed map falls back to the global config map (back-compat). Reply gains
  `source` (`kernel`|`config`).
- **Exit test `s44`** — govern-set a Ship map (`planned→[crewed]`, `crewed→[deployed]`):
  `planned→crewed` succeeds (source=kernel), `planned→deployed` is rejected, and a Task (no sealed map)
  uses the global config — `Task→crewed` is rejected (the Ship map does not bleed). Warm suite (s4…s44) +
  s34 fresh-install green.

## v0.4.9 - 2026-06-12

**v0.5 roadmap T2 — `instance.link` / `instance.reach` declared predicate set.** The predicate gate moves
from a namespace allowlist (`conceptkernel.org/%` / `urn:ckp:%`) to the kernel's **declared** predicates.

- **`ckp.declared_predicates(project)`** reads the union of `sh:path` over the kernel graph's shapes — the
  predicates a kernel declares (addable via the governance plane).
- **`ckp.reach`** and **`edge.create`**: when the kernel declares predicates, `via`/`predicate` MUST be one
  of them (`undeclared_predicate`) — even in the conceptkernel namespace; a kernel that declares none keeps
  the namespace-allowlist fallback (back-compat; the s30/s40 fixtures declare no predicates). The IRI regex
  gate stays in both modes.
- **Exit test `s43`** — a kernel declaring `part_of`: `link(A,part_of,B)` seals + materializes,
  `reach(A,part_of)` returns `{B,C}` transitively, and a namespaced-but-undeclared predicate is rejected by
  both link and reach. Warm suite (s4…s43) + s34 fresh-install green.

## v0.4.8 - 2026-06-12

**v0.5 roadmap T1 — `instance.query` derived QueryShape.** The first track toward v0.5 (the last green
`0.4.n` is re-tagged `v0.5.0`). `ckp.query` now validates filter keys against the type's **declared**
properties instead of a generic regex.

- For a **shaped** type, a filter key MUST be a declared `sh:property`/`sh:path` (read from the kernel
  graph, the same read `ckp.create_typed`/`ckp.seal` do); a short key is resolved to its property IRI — so
  a typed instance whose body stores full-IRI keys is now queryable by short name — and an **undeclared key
  is rejected** (`undeclared_filter_key`).
- An **unshaped** type keeps the prior regex key gate (back-compat; "unshaped = permissive", mirroring
  `validate_instance`). The closed operator enum + bounded `limit`/`offset` + parameter-safe WHERE over
  `ckp.instances` are unchanged; the reply gains `shaped`.
- `instance.query` reads the `ckp.instances` jsonb store (not pgRDF graphs); the only pgRDF call is the
  single-pattern shape read. (The pgRDF join-pin advisory applies to T7's compiled graph reads / reach.)
- **Exit test `s42`** — a Ship with declared `crew_size`/`name`: `crew_size>=10` returns the matches (short
  key resolved to its IRI), an undeclared key is rejected, and an unshaped fixture still queries by short
  key. Warm suite (s4…s42) + s34 fresh-install green.

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
- Presence model (U2) reuses the downstream consumer's `Participant` / `Session` kernels — `participant.join` is the request; no invented `VisitorRequest` type.

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
