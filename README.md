# pgCK — the Concept Kernel runtime

> **Sovereign, semantic, multi-participant state — governed, provable, and reachable only through one typed door over NATS.** No REST. No query surface. The engine stays invisible; the meaning stays sovereign; the proof chain stays whole.

**pgCK** makes a database the living home of **concept kernels** — units of meaning whose *types are ontology*, whose every change is **shape-gated, sealed, and proof-chained**, and whose only interface to the world is a single typed verb carried over **NATS-WSS**.

- **Semantic, not tabular.** A kernel's types are RDF classes with SHACL shapes and OWL-RL rules — designed to ground into upper ontologies (the Basic Formal Ontology, BFO) and domain vocabularies, not hand-rolled columns. *Meaning is the schema.*
- **Strongly typed over pure NATS.** Participants — browsers, agents, services — reach a kernel through exactly one capability, `ckp.dispatch(verb, payload)`, over NATS-WSS. No REST endpoint, no SQL handle, no query engine is ever exposed. **The door is the whole surface.**
- **Multi-participant by design.** Many participants act on one kernel at once; every fact seals into the shared graph and emits to NATS, so they converge on a single governed truth — without anyone holding more than the door.
- **Provable by construction.** Every landing runs `validate → seal → HMAC-chained ledger → verifiable proof`, in one transaction. Nothing lands that violates its shape. Each change carries **PROV-O** provenance and a proof anyone can re-verify.
- **Self-governing.** A kernel changes its *own* types by consensus — `propose → vote → apply` — so the very next write is bound by a quorum-approved shape, with a proof chain from proposal to applied epoch.

This is the **Concept Kernel Protocol** (CKP v3.11). The root ontology is published at [conceptkernel.org/ontology/v3.11/core.ttl](https://conceptkernel.org/ontology/v3.11/core.ttl) and pinned by digest (`e5f7d1e5…` — verify with `shasum` against the published sidecar). Reference authority: [conceptkernel.org](https://conceptkernel.org).

## See it in 30 seconds — over the real wire

The shortest path from zero to sealed, governed, provable state — driven the way a browser or agent drives it: the **cklib client over NATS-WSS → relay → `ckp.dispatch`**. No SQL, no REST, only Docker.

```sh
# from the oci-germination repo — one script, only Docker required:
bash examples/hello-kernel/run.sh
```

```
① activate the kernel                CK.activate(kernel, { wssEndpoint, token })
② land sealed, proof-chained state   create(Project) → proof_digest, verified
③ read it back + re-verify the proof verify · query
④ PROVE enforcement is real          incomplete → REFUSED · anonymous → REFUSED
⑤ relate + traverse                  link → reach
```

And here's what your app (or browser, or agent) actually writes — cklib over NATS-WSS, nothing else. Types are the v3.11 root's own (always full IRIs on the wire):

```js
import { CK } from 'cklib';
// realm-connected (quick-install door ②): your token is verified AT the door,
// and the seal derives who-you-are from the wire — identity is never payload
const k = await CK.activate('demo', { wssEndpoint: 'wss://host/wss', token });

const Project = 'https://conceptkernel.org/ontology/v3.11/core#Project';
const p = await k.create(Project, { label: 'hello', projectKind: 'personal',
                                    ownedBy: 'urn:ckp:participant:you' });
//   ownedBy is DOMAIN data — any IRI you designate. WHO SEALED IT is not yours
//   to claim: createdBy is stamped from your verified connection.
//   → { ok: true, id, verified: true, proof_digest }   — sealed + proof-chained in one
//     transaction, stamped createdBy / producedBy / sealedAtEpoch / conformsToShape

await k.create(Project, { label: 'incomplete' });   // omit shape-required fields
//   → { ok: false }   — REFUSED at the seal, with every violated clause named

// and on the ANONYMOUS bundle (door ①), this same create refuses too:
//   → 'unattributed write refused' — there are no anonymous facts, only
//     anonymous readers. A fact belonging to nobody never lands.

await k.verify(p.id);                          // independently re-checks the proof chain
await k.reach(p.id, '…/core#ownedBy');         // traverse the links you've sealed
```

Every step asserts. The client holds exactly one capability — `ckp.dispatch` — and **cannot** run SQL, reach the query engine, or land a fact that did not pass its shape gate and mint a proof. That is the point: the door is the only surface, the engine is invisible. *(Full runnable example: [oci-germination `hello-kernel`](https://github.com/sporaxis-com/oci-germination/tree/main/examples/hello-kernel).)*

## What a concept kernel means

Strip away every mechanism, and this is what remains: **a concept kernel is a place where meaning lives and is answerable for itself.**

Not a database — a database stores what you tell it and does not care what it means. Not a service — a service does what it is told and does not know why. A concept kernel is closer to a small, sovereign institution of meaning: it declares what kinds of things exist for it, it accepts only facts that honor those declarations, it remembers who said each thing and under which of its laws the thing was judged, and it changes its laws only by the agreement of those who live under them.

Three questions define it — the **[three loops](https://conceptkernel.org/v3.7/three-loops)** of one sovereign entity, in a strict order:

- **What can I mean?** — its declared world: the kinds, shapes and relations it recognizes. This is its identity, and nothing outside it can write there.
- **What can I do?** — the acts it offers others: ways to add to it, ask it, link through it. Capability is always *derived from* meaning, never invented beside it.
- **What have I done?** — the sealed record. Every fact carries who said it, whose law governed it, which version of that law was in force, and which rule judged it. Knowledge here is never anonymous and never unjudged.

The founding sentence holds all of it: *you do not enforce your own shape — you declare it, and the ground refuses what violates it.* A kernel never argues. It declares, and the substrate beneath it refuses everything that violates the declaration — **including the kernel's own attempts**. That is what makes its record trustworthy to a stranger: the kernel cannot exempt itself from its own law. The boundary is real because it is held by **write authority, not convention**: storing a fact can never change the ontology, and running a verb can never rewrite the rules.

And it is sovereign: whole on its own, joined to others only by its own sealed choice. Everyone who can hold a key is a participant of the same standing — a person, an agent, whatever arrives next. The door does not ask what you are, only whether you can answer for what you say.

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

## Quick install — two doors, pick your identity story

Both are attested [oci-germination](https://github.com/sporaxis-com/oci-germination) bundles that carry pgCK + pgRDF + NATS pre-composed. One `docker run`, no build.

**① Localhost, anonymous — the fastest working kernel** (`ociger-pg18-pgrdf-pgck-nats-micro`): PostgreSQL 18 + both extensions + NATS core/WSS in one container. No identity plane — right for a private localhost bench, exploration, and CI. Anonymous dispatch **reads** freely (surface checks, queries, events); **writes refuse** unless an identity is declared — over the wire that means door ②, and on the operator/SQL path it means naming one explicitly (`set_config('ckp.requester', 'svc:my-bench', true)`) before sealing. A fact belonging to nobody never lands, even on a toy bench.

```sh
docker run -d -p 5432:5432 -p 4222:4222 -p 9222:9222 \
  ghcr.io/sporaxis-com/ociger-pg18-pgrdf-pgck-nats-micro:latest
```

**② Realm-connected — identities sealed from the wire** (`ociger-ck-allinone`): the full bundle with the identity boot-provisioner. Hand it your OIDC realm's **JWKS document** at container start (a document, never a URL — verification is in-memory, zero egress) and pgCK itself answers the NATS auth-callout: each user's EdDSA token is verified at the door, and the verified identity rides the broker-enforced wire onto **every fact they seal** — attribution is derived by the substrate, never claimed by the client. Without a realm configured it boots in the same anonymous mode as ①.

Current tags, digests and the realm environment contract: [oci-germination `LATEST.md`](https://github.com/sporaxis-com/oci-germination/blob/main/LATEST.md).

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
