# v312-tdd — the RED suite for the v3.12 line

Executable form of the v3.12 obligations. Written **after** pgRDF's `lib-tdd` proved the
protocol and **before** the emissions it tests; cases are expected to fail — the point is
that they fail **for the stated reason**, and flip GREEN only when the mechanism actually
lands. The RED ledger below is the measure of progress toward the v3.12 final release.

## Three-state semantics (their M1, adopted verbatim)

| Exit | State | Meaning |
|---|---|---|
| 0 | **GREEN** | the target behaviour is met |
| 44 | **RED** | fails today *exactly as predicted* — documents the unimplemented mechanism. A RED is a suite PASS. |
| other | **BROKEN** | fails for an **unstated** reason — the substrate moved, or the prediction was wrong. The only failing state. |

`run.sh` exits non-zero **iff any case is BROKEN**. RED→GREEN = a mechanism landed (move
the ledger row). GREEN→RED or anything→BROKEN = a regression: stop and look.

## Running

```
tests/v312-tdd/run.sh              # all cases (container-exec default: the smoke stack's
                                   # pgck-postgres — the DISPOSABLE bench; never a shared one)
tests/v312-tdd/run.sh 04           # one case by prefix
PGCK_TDD_PSQL="psql …" run.sh      # any bench via full psql command — but writes seal
                                   # FOREVER; only point this at a bench you may write
```

Cases only write throwaway artifacts (`urn:tdd:*` names, probe seals) and are safe to
re-run: the smoke stack drops and recreates both extensions every `smoke-s4`.

## The measured ledger — 2026-08-27, smoke stack (pgck 0.4.83-devel / pgrdf 0.6.34, v3.12-FINAL-booted)

**30 cases · green 15 · red-as-predicted 14 · BROKEN 0 · ~5s wall.** Cases 29/30 (the
refusal envelope) were added RED on cklib PASS-2's ISSUE-6/7 and flipped GREEN the same
day the refusal registry + door normalizer landed (0.4.83) — the suite working as
intended. Layered: core planes first (01–21), modules proven on top (22–30). The
mechanical audit is ONE instrument (`audit/ontology-audit.sh`, structured output,
methods named) consumed by cases 18/22 and run by authors before any ontology commit.

| 01 | engine floor | e0-floor | ✅ | refusals typed: `0A000`, construct named in prose |
| 02 | engine floor | tnull-floor | ✅ | absent graph refuses `42704`; the sha256('') era is over |
| 03 | digests | fd1-agreement | ✅ | `ckp._structural_digest` == engine fd1 byte-for-byte — B1 delegation safe |
| 04 | capability | affordance-seals | 🔴 | 0 sealed Affordances (#56) |
| 05 | capability | executor-sparqlbody | 🔴 | no generic executor — module verbs `unknown_affordance` |
| 06 | governance | quorum-projectkind | 🔴 | apply clears at quorum 1 on a project declared `shared` — `projectKind` read by nothing |
| 07 | governance | apply-honours-about | 🔴 | apply ok while the about-target kernel stays untouched — silent redirection (F-A) |
| 08 | epochs | adoption-epoch | 🔴 | adoption recomposes with NO Materialization; fabricated sourceDigest seals unverified |
| 09 | acts | run-sealed | 🔴 | 0 `ckp:Run` ever — outcomes without happenings |
| 10 | retirement | retirement-emitted | ✅ | retirement markers reach the read plane — the widening stopped being decorative |
| 11 | root | v312-root-boots | ✅ | v3.12 FINAL loads: 30 = 27+3, predicted-then-counted |
| 12 | judgement | signal-gated | ✅ | bogus `signalPolarity` refused naming the path |
| 12b | law | constants-gated | ✅ | sign gate + `sh:lessThan` band refuse; lawful values fire nothing |
| 13 | score plane | score-verbs | 🔴 | `score.top` → `unknown_affordance` |
| 14 | envelope | reply-envelope-stamps | 🔴 | stamps stored but null in the reply (P3) |
| 15 | envelope | completeness-verdict | 🔴 | no verdict on read replies (B2) |
| 16 | vacuity | projection-namespace | 🔴 | `project_links` types `core#Task` (declared nowhere) — zero-focus gate, a silent second pass |
| 17 | seals | first-seal-134 | ✅* | warm-project seal works; *the authoritative #134 gate is the full smoke-s4 run (fails deterministically at s19)* |
| 18 | mechanics | ontology-audit | ✅ | ONE audit: digest pinned, 30 shapes, 94/94 reach, namespace line, delta complete |
| 21 | root | boot-default-v312 | ✅ | installed `boot()` defaults to v3.12 FINAL |
| 22 | modules | module-audits | 🔴 | wave+recon CLEAN; **lexicon: 11 unreached properties incl. `lex:symptom`** — ungated law, ours |
| 23 | admission | unadopted-refuses | ✅ | unadopted `wave:Finding` refused — proximity is not adoption |
| 24 | vacuity | wave-verbs-honest | 🔴 | `wave.signals` answers vacuously where unadopted — ghost-read trap stands |
| 25 | spore | recon-roundtrip | ✅ | place → adopt → Chunk gated by module shape → negative control names the clause |
| 26 | proofs | proof-plane | 🔴 | door path total; legacy fixture paths (edge/match) seal proofless — every-write-appends-evidence owed |
| 27 | judgement | four-stamps-readback | ✅ | M1–M4 read individually; M2 names the addressed kernel's law |
| 28 | capability | govern-then-listed | 🔴 | the #56 LOOP: add_affordance applies ok + verb CALLABLE + absent from derived[] + 0 sealed — what was governed in does not show in its own list |
| 29 | envelope | refusal-envelope | ✅ | ONE law: every registry refusal ships `refused:true` + typed `sqlstate` from every site (B7) |
| 30 | envelope | refusal-teaches-key | ✅ | `invalid_about` teaches `{about: <proposal_iri>}` — refusals name the KEY, not just the value |

**The 14 REDs are the v3.12 build queue, re-runnable anytime.** A RED→GREEN flip is a
mechanism landing; anything→BROKEN is a regression or a stale prediction — stop and look.

## The rule this suite holds

A prediction is part of the check. A case that fails for a *different* reason than its
header states is BROKEN even if it fails — because the suite's value is the ledger, and
a ledger entry nobody re-derived is prose with an exit code.
