# pgCK — the Concept Kernel runtime

> **Sovereign, semantic, multi-participant state — governed, provable, and reachable only through one typed door over NATS.** No REST. No query surface. The engine stays invisible; the meaning stays sovereign; the proof chain stays whole.

**pgCK** makes a database the living home of **concept kernels** — units of meaning whose *types are ontology*, whose every change is **shape-gated, sealed, and proof-chained**, and whose only interface to the world is a single typed verb carried over **NATS-WSS**.

- **Semantic, not tabular.** A kernel's types are RDF classes with SHACL shapes and OWL-RL rules — designed to ground into upper ontologies (the Basic Formal Ontology, BFO) and domain vocabularies, not hand-rolled columns. *Meaning is the schema.*
- **Strongly typed over pure NATS.** Participants — browsers, agents, services — reach a kernel through exactly one capability, `ckp.dispatch(verb, payload)`, over NATS-WSS. No REST endpoint, no SQL handle, no query engine is ever exposed. **The door is the whole surface.**
- **Multi-participant by design.** Many participants act on one kernel at once; every fact seals into the shared graph and emits to NATS, so they converge on a single governed truth — without anyone holding more than the door.
- **Provable by construction.** Every landing runs `validate → seal → HMAC-chained ledger → verifiable proof`, in one transaction. Nothing lands that violates its shape. Each change carries **PROV-O** provenance and a proof anyone can re-verify.
- **Self-governing.** A kernel changes its *own* types by consensus — `propose → vote → apply` — so the very next write is bound by a quorum-approved shape, with a proof chain from proposal to applied epoch.

This is the **Concept Kernel Protocol** (CKP v3.11). The root ontology is published at [conceptkernel.org/ontology/v3.11/core.ttl](https://conceptkernel.org/ontology/v3.11/core.ttl) and pinned by digest (`e5f7d1e5…` — verify with `shasum` against the published sidecar); coordination (`wave`) and learning (`lexicon`) vocabularies are governed **modules**, adopted per-kernel by a sealed, digest-pinned `ckp:Adoption` — never composed by proximity. Reference authority: [conceptkernel.org](https://conceptkernel.org).

## See it in 30 seconds — over the real wire

The shortest path from zero to sealed, governed, provable state — driven the way a browser or agent drives it: the **cklib client over NATS-WSS → relay → `ckp.dispatch`**. No SQL, no REST, only Docker.

```sh
# from the oci-germination repo — one script, only Docker required:
bash examples/hello-kernel/run.sh
```

```
① activate the kernel                CK.activate(kernel, { wssEndpoint })
② land sealed, proof-chained state   create(Project) → proof_digest, verified
③ read it back + re-verify the proof verify · query
④ PROVE enforcement is real          an incomplete create is REFUSED at the seal
⑤ relate + traverse                  link → reach
```

And here's what your app (or browser, or agent) actually writes — cklib over NATS-WSS, nothing else. Types are the v3.11 root's own (always full IRIs on the wire):

```js
import { CK } from 'cklib';
const k = await CK.activate('demo', { wssEndpoint: 'ws://host:9222' });

const Project = 'https://conceptkernel.org/ontology/v3.11/core#Project';
const p = await k.create(Project, { label: 'hello', projectKind: 'personal',
                                    ownedBy: 'urn:ckp:participant:you' });
//   → { ok: true, id, verified: true, proof_digest }   — sealed + proof-chained in one
//     transaction, stamped createdBy / producedBy / sealedAtEpoch / conformsToShape

await k.create(Project, { label: 'incomplete' });   // omit shape-required fields
//   → { ok: false }   — REFUSED at the seal, with every violated clause named;
//     you cannot land a fact that violates its shape

await k.verify(p.id);                          // independently re-checks the proof chain
await k.reach(p.id, '…/core#ownedBy');         // traverse the links you've sealed
```

Every step asserts. The client holds exactly one capability — `ckp.dispatch` — and **cannot** run SQL, reach the query engine, or land a fact that did not pass its shape gate and mint a proof. That is the point: the door is the only surface, the engine is invisible. *(Full runnable example: [oci-germination `hello-kernel`](https://github.com/sporaxis-com/oci-germination/tree/main/examples/hello-kernel).)*

## What a concept kernel is

Three aspects — the **[three loops](https://conceptkernel.org/v3.7/three-loops)** — of one sovereign entity, in a strict order, with a boundary enforced by **write authority, not convention**:

- **Identity** — its ontology: classes, SHACL shapes, the action catalogue. *What kinds of things exist.*
- **Capability** — the governed verbs + materialization rules that transform state. *How things relate and change.*
- **Knowledge** — the sealed instances, each a shaped, proof-chained fact. *What has actually happened.*

A participant (role `ck_participant`) holds **only** `EXECUTE ckp.dispatch` — it cannot read a table, reach `pgrdf.*`, or rewrite a shape. **Storing a fact can never change the ontology; running a verb can never rewrite the rules.** That separation — enforced by the database's own role authority — is what makes a kernel sovereign and self-governing, and what lets many kernels one day cooperate without surrendering autonomy.

## The substrate — the *how*, not the headline

pgCK is a PostgreSQL extension (Rust / `pgrx`) that **composes** [pgRDF](https://github.com/styk-tv/pgRDF): pgRDF holds the ontology and runs SHACL / SPARQL / OWL-RL; pgCK governs operations, owns the NATS bridge, and turns ontology into enforced, routable, provable behaviour — all inside **one transaction boundary**. The semantics live in the graph engine; the authority lives in Postgres roles; pgCK is where they meet. (Why an RDF engine *inside* Postgres rather than beside it: a kernel's meaning and the boundary that protects it have to be the *same* transaction.)

## Built & attested — honestly

Every release is multi-arch (`amd64` + `arm64`), **PostgreSQL 18 only** (glibc ≥ 2.38 base —
trixie/noble), with a SLSA build-provenance attestation, in two flavors: the plain extension
and the `-nats` build (in-process NATS relay + auth-callout). The current attested head lives
in [`LATEST.md`](LATEST.md) — auto-generated by CI after attestation verifies, never by hand.

```sh
gh attestation verify oci://ghcr.io/styk-tv/pgck:0.4.77-pg18-amd64 --owner styk-tv   # exit 0
```

**✅ Real today**

- **One governed door** — `ckp.dispatch` over a Postgres role floor; a sealed affordance registry is the only routing authority; epoch invalidation clears compiled plans on every kernel change; no caller SQL/SPARQL expression position is reachable.
- **Governed write + proof** — `validate → seal → HMAC-chained ledger → verifiable proof`, atomic, SHACL-gated against the kernel's own shape. `instance.verify` re-checks the chain independently; `instance.retire` is a retraction seal.
- **Kernel-derived typed surface** — generic typed `create` against the kernel's *declared* shape; `query` / `update` / `validate` over declared properties (full SHACL `ValidationReport`); per-kernel sealed transition maps; governed `concept.match`; declared-predicate `link` / `reach` that **traverses** participant links (by bare id or `@id`).
- **Self-changing types** — `propose → vote → apply` mutates the kernel shape by quorum; the next seal is bound by it, with a full proof chain from proposal to applied epoch.
- **Install-from-zero** — `CREATE EXTENSION pgck CASCADE` yields a working governed door for a real `ck_participant` login, floor intact, zero setup.
- **NATS bridge** — a `pgrx` background worker bridges the governed write path to NATS and drains sealed facts to the wire, so participants observe each other.

**⏭ The honest edge**

- **Verified identity is live in the `-nats` build** — pgCK itself answers the NATS
  auth-callout: an EdDSA (Ed25519) JWT is verified in-memory against a JWKS *document*
  delivered at container start (never a URL, no egress), the verified subject rides
  broker-enforced subjects into `ckp:createdBy`, and unattributed writes **refuse** rather
  than mint anonymous participants. Anonymous connections are admitted subscribe-only.
- **Module adoption is governed and pinned** — a module reaches a kernel's enforcement
  surface only through a sealed, digest-cited `ckp:Adoption`; the substrate pins each adopted
  graph (byte and structural planes) so later drift is detectable, and fresh installs carry
  the pin ledger out of the box (v0.4.77).
- **Upper-ontology grounding** (BFO and friends) and **cross-kernel federation** are the
  *trajectory* — captured as direction, built only when a real consumer needs them, never
  speculatively.
- `ed25519` will replace the shipped `hmac+sha256` proof method.

Per-version detail and the full capability boundary: [`CHANGELOG.md`](CHANGELOG.md).

## Build & run

The local loop is **Docker on the `colima` context**. `just` builds the Linux artifacts into `compose/extensions/` and runs the isolated stack.

```bash
just pgrdf-fetch     # fetch released pgRDF artifacts
just build-ext       # build pgck.so + control + sql
just compose-up      # bring up the stack
just smoke-s4        # warm governed suite (s4…s69)
just smoke-s34       # fresh-install gate (CREATE EXTENSION from zero)
just psql            # psql into the compose postgres — operator/debug only
```

A browser-facing NATS-WSS stack (`just nats-wss-up`, `just smoke-nats-wss`) is available for end-to-end WSS testing. Working drafts, planning notes, and helper material live in a local-only, **gitignored `_WIP/`** and are not part of the public repo surface.

> **Operator/debug aside (not the adopter surface).** You *can* reach the door directly:
> `SELECT ckp.dispatch('instance.create', '{"type":"urn:ckp:demo/type/Ship", …}'::jsonb)` as `ck_participant`.
> That bypasses the wire and exists for debugging only — the surface a real app or browser integrates against is **cklib over NATS-WSS**, exactly as `hello-kernel` runs it.

## License

MIT — see [`LICENSE`](LICENSE).
