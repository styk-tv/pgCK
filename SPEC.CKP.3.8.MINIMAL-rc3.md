# SPEC.CKP.3.8.MINIMAL-rc3 — single-pod, self-governing Concept Kernel runtime

**Status:** MINIMAL DRAFT — rc3 — 2026-05-16 — **build target**
**Supersedes:** [`SPEC.CKP.3.8.MINIMAL-rc2.md`](SPEC.CKP.3.8.MINIMAL-rc2.md) (rc1/rc2 kept for history)
**Goal:** deployable on demand into a marketplace sandbox. One pod, one image, per-tenant params.

> **Δ from rc2.** rc2 split control/data planes and introduced a bgworker. rc3 **names and unifies** it: the runtime is a single Postgres extension — **`conceptkernel`** — that *is* the NATS bridge, the SHACL **validator**, and the **materializer**, in one spot, one transaction boundary. CK self-operations (provenance, ledger, proof) are governed **at the core** by a CKP **core ontology shipped inside the extension** and verified by the same SHACL validator. **No separate CK.Compliance kernel** — the protocol governs itself.

---

## 1. Premise

A **Concept Kernel** is a versioned, ontology-defined unit of behaviour. rc3 runs it as **one self-contained pod**:

- **Embedded NATS broker** — WSS termination; user requests arrive as NATS messages.
- **Embedded PostgreSQL** with exactly three extensions:
  - **`pgrdf`** — RDF graphs, SPARQL, SHACL, OWL 2 RL inference.
  - **`age`** — property-graph instances (optional per kernel).
  - **`conceptkernel`** — the bridge: owns the NATS connection, is the SHACL **validator**, is the **materializer** (ontology → DDL, affordances → subscriptions, operations → ledger/proof). pgrx background worker + SQL surface.
- **Embedded Postgres talks to Azure** via `postgres_fdw` — durable instance/ledger/proof tables live in Azure-managed PG; the pod is the compute + governance surface.

**Everything is governed, governable, proven, verifiable** — including the protocol's own operations. The CKP **core ontology** (Kernel, Organ, Affordance, LedgerEntry, Proof, Provenance + their SHACL shapes) ships *inside the `conceptkernel` extension* and is loaded at install. Every operation the extension performs is SHACL-validated against that core, in the same transaction that performs it. Validator and materializer are the same component.

### Non-goals (rc3)

- No separate compliance/audit kernel — governance is core, not delegated.
- No filesystem track, no migration shims, no per-class tables, no hand-written validation.
- No multi-pod orchestration — one pod per project; scale is "more pods, same image".

---

## 2. The pod

```
┌──────────────────────── ONE POD (the deployable unit) ────────────────────────┐
│                                                                               │
│  Embedded NATS broker  ── WSS in ──┐                                           │
│                                    ▼                                           │
│  Embedded PostgreSQL                                                           │
│    • conceptkernel  ── bgworker: holds NATS conn, validator, materializer ──┐  │
│    • pgrdf          ── CKP core ontology + kernel ontology + SHACL + SPARQL │  │
│    • age (optional) ── graph-shaped instances                              │  │
│    • postgres_fdw   ── foreign tables → Azure ─────────────────────────┐   │  │
│                                                                        │   │  │
│  Mounts: /secrets (Azure creds)  /ontology/kernel.ttl  (image tag = TOOL pin)  │
└────────────────────────────────────────────────────────────────────────┼───┼─┘
                                                                           │   │
                              postgres_fdw (TLS, predicate pushdown)        │   │
                                                                           ▼   ▼
┌──────────────── AZURE-MANAGED POSTGRES (durable data plane) ──────────────────┐
│  db: project_A   role: ck_role@project-A   schema: ckp_data                    │
│    instances (JSONB) · ledger (signed) · proof (verifiable) · (opt) AGE graph  │
└───────────────────────────────────────────────────────────────────────────────┘
```

The pod is a **pure function of (image + kernel.ttl + secrets)**. No durable state in the pod. Kill/restart/replace is free. Durable truth is in Azure.

---

## 3. The `conceptkernel` extension — one component, three duties

Installed with `CREATE EXTENSION conceptkernel;`. On install it loads the **CKP core ontology** into pgRDF graph `urn:ckp:core` and registers a background worker.

| Duty | What it does |
|---|---|
| **Bridge** | Owns the NATS connection to the embedded broker. Subscribes/publishes. WSS user requests enter here. |
| **Validator** | Runs `pgrdf.validate()` against (a) the kernel ontology shapes for instance payloads, and (b) the **core** ontology shapes for every protocol operation it performs (kernel registration, affordance materialisation, ledger append, proof record). |
| **Materializer** | Projects ontology → operational schema (JSONB CHECK on Azure tables, AGE labels), affordances → live NATS subscriptions, and every governed operation → a signed ledger row + a verifiable proof record. |

Validator and materializer share one transaction boundary: an operation is **validated and materialised atomically or not at all**. There is no path that materialises without validating, and no governed write without a proof.

### 3.1 SQL surface (contract)

```
ckp.bootstrap_kernel()                 -- idempotent: Azure schema (CREATE/ALTER), FDW import, core+kernel TTL load
ckp.subscribe(in_topic, affordance)    -- add a live NATS subscription
ckp.publish(out_topic, payload)        -- emit a result (proof-stamped)
ckp.recompile_affordances()            -- diff affordance set vs ontology; adjust subscriptions + Azure CHECK
ckp.validate(graph, shapes)            -- SHACL gate (wraps pgrdf.validate; used for both kernel + core)
ckp.seal(instance_id, body)            -- atomic: validate → INSERT instance → INSERT ledger → record proof
ckp.verify(instance_id)                -- recompute + check signature + check core-shape conformance
```

The pgrx bgworker shape and full signatures are the immediate next artifact (§9).

---

## 4. Core governance — proof and CK self-operations

This is the rc3 differentiator. **Proof and the operations of the CK itself are linked at the CK core level**, not in a downstream kernel.

### 4.1 The CKP core ontology (shipped in the extension)

Loaded into graph `urn:ckp:core` at `CREATE EXTENSION`. Defines and SHACL-shapes:

- `ckp:Kernel`, `ckp:Organ` (CK / TOOL / DATA), `ckp:Affordance` (`ckp:inTopic`, `ckp:outTopic`, `ckp:inShape`, `ckp:sparql`).
- `ckp:LedgerEntry` (`ckp:bodySha`, `ckp:sig`, `ckp:prev`, `ckp:ts`) with a shape that **requires** a non-empty signature and a chain link.
- `ckp:Proof` (`ckp:about`, `ckp:method`, `ckp:digest`, `ckp:verifiedAt`) with a shape that **requires** a digest and a verification method.
- `ckp:Provenance` (PROV-O subset: `prov:wasGeneratedBy`, `prov:wasDerivedFrom`).

### 4.2 The protocol governs itself

Every operation the `conceptkernel` extension performs is itself an instance that must conform to a **core** SHACL shape before it commits:

- Register a kernel → must conform to `ckp:KernelShape`.
- Materialise an affordance → must conform to `ckp:AffordanceShape`.
- Append a ledger row → must conform to `ckp:LedgerEntryShape` (signature + chain mandatory).
- Record a proof → must conform to `ckp:ProofShape` (digest + method mandatory).

If a self-operation fails its core shape, the transaction aborts. **There is no governed write without a conforming, signed, proof-stamped record** — enforced by the same `pgrdf.validate()` used for user data. No CK.Compliance kernel needed: compliance is a property of every commit, checked at the core, in the core.

### 4.3 Validator = materializer = same spot

`ckp.seal()` is the canonical path and shows the unity:

```
ckp.seal(instance_id, body):
  BEGIN
    -- VALIDATE (kernel shape for the payload)
    ckp.validate(body_as_quads, kernel_shapes)            -- abort on non-conformance
    -- MATERIALIZE (durable, atomic, Azure-side via FDW)
    INSERT INTO local_ckp.instances (id, body) VALUES (instance_id, body)
    led := { about: instance_id, bodySha: sha256(canon(body)), sig: ed25519(...), prev: last_seq }
    -- VALIDATE the protocol's own operation (core shape)
    ckp.validate(led_as_quads, core_shapes['ckp:LedgerEntryShape'])   -- abort if ledger entry malformed
    INSERT INTO local_ckp.ledger (...) VALUES (led...)
    prf := { about: instance_id, method: 'ed25519+sha256', digest: led.bodySha, verifiedAt: now() }
    ckp.validate(prf_as_quads, core_shapes['ckp:ProofShape'])         -- abort if proof malformed
    INSERT INTO local_ckp.proof (...) VALUES (prf...)
  COMMIT      -- one Azure transaction: instance + ledger + proof, all validated
```

Validate and materialise are interleaved in one transaction. You cannot get a materialised instance that is unvalidated, unsigned, or unproven.

---

## 5. Three loops, one governance (carried, sharpened)

| Loop | Substrate | Where | Governed by |
|---|---|---|---|
| **Semantic** | pgRDF graphs `urn:ckp:core` + `urn:ckp:<project>/<kernel>/ck` | pod | itself (core + kernel ontology) |
| **Document** | Azure JSONB `instances` (via FDW) | Azure | semantic loop (SHACL gate + Azure CHECK) |
| **Graph** | AGE (Azure if available, else pod) | Azure/pod | semantic loop (vertex/edge labels) |

Governance is **downward only** (ontology → schema/labels/routing; never reverse). Data is **never projected** between loops — kernels write into the loop(s) they declare via `ckp:dataSubstrate`. Loss of a data loop is loss of real data, not a recompute. Identity excludes derivable schema (CHECK text, AGE label defs); includes data + ledger + proof.

---

## 6. Request path (WSS → governed write → proof)

1. **WSS in** — user request hits the embedded NATS broker as a message on `input.<project>.<kernel>.<action>`.
2. **Bridge** — the `conceptkernel` bgworker's live subscription (materialised from an affordance) receives it.
3. **Resolve** — affordance row resolved by SPARQL over the kernel CK graph (in-pod, fast).
4. **Validate (kernel shape)** — `ckp.validate(payload, kernel_shapes)`; reject at the edge on non-conformance (no Azure round-trip on bad input).
5. **Seal (atomic, §4.3)** — instance + ledger + proof written to Azure in one FDW transaction, each core-shape-validated.
6. **Publish** — result emitted on `ckp:outTopic`, proof-stamped.

Every hop is governed by SHACL; every durable write carries a signed ledger row and a verifiable proof, checked against the core ontology in the same commit.

---

## 7. Boot sequence (idempotent, ordered)

1. Embedded Postgres starts; `CREATE EXTENSION pgrdf, age, postgres_fdw, conceptkernel;` (idempotent).
2. `conceptkernel` install loads CKP **core ontology** into `urn:ckp:core`; registers bgworker.
3. bgworker: `pgrdf.parse_turtle(/ontology/kernel.ttl)` → kernel CK graph; `pgrdf.materialize()`.
4. `ckp.bootstrap_kernel()` → FDW server + user mapping from `/secrets`; `IMPORT FOREIGN SCHEMA ckp_data` from Azure; idempotent `CREATE/ALTER` of `instances`/`ledger`/`proof`; refresh Azure CHECK from ontology.
5. SPARQL-enumerate affordances → `ckp.subscribe()` each.
6. Connect embedded NATS; mark ready.
7. CK-graph AFTER-STATEMENT trigger armed → `ckp.recompile_affordances()` on any ontology change (live reroute + CHECK refresh, no restart).

---

## 8. Identity, proof, verifiability

- **CK identity:** `sha256(URDNA2015(N-Quads(core ⊕ kernel CK graph)))`. The core graph is part of identity — the governing rules are pinned with the kernel.
- **DATA identity (Azure):** `sha256(canon(instances) ‖ canon(ledger) ‖ canon(proof) ‖ canon(AGE if used))`. On demand.
- **Proof:** every sealed instance has a `proof` row (`method`, `digest`, `verifiedAt`) that conformed to `ckp:ProofShape` at write time. `ckp.verify(id)` recomputes digest, checks the Ed25519 signature against the kernel identity key, and re-runs the core shape — anyone can verify any instance independently.
- **TOOL pin:** the image tag (the `conceptkernel` extension + bundled core + kernel TTL are the materialised TOOL). Only pin.

---

## 9. The deployable unit (marketplace sandbox)

**One image.** Build once:

```dockerfile
FROM postgres:17
RUN apt-get update && apt-get install -y build-essential postgresql-server-dev-17 \
      git curl libreadline-dev zlib1g-dev flex bison \
 && rm -rf /var/lib/apt/lists/*
# pgRDF (Rust/pgrx)
RUN git clone https://github.com/styk-tv/pgRDF.git /tmp/pgrdf \
 && cd /tmp/pgrdf && make && make install && rm -rf /tmp/pgrdf
# Apache AGE
RUN git clone https://github.com/apache/age.git /tmp/age \
 && cd /tmp/age && make install && rm -rf /tmp/age
# conceptkernel extension (this repo's deliverable — pgrx bgworker + SQL surface + core ontology)
COPY conceptkernel/ /tmp/conceptkernel/
RUN cd /tmp/conceptkernel && make && make install && rm -rf /tmp/conceptkernel
# embedded NATS
RUN curl -sL https://github.com/nats-io/nats-server/releases/latest/download/nats-server-linux-amd64.tar.gz \
      | tar xz -C /usr/local/bin --strip-components=1
COPY docker-entrypoint-ckp.sh /usr/local/bin/
CMD ["/usr/local/bin/docker-entrypoint-ckp.sh"]
# postgres_fdw is in contrib (already present)
```

**Per-tenant parameters (mounts/env only — image unchanged):**

| Param | Form | Purpose |
|---|---|---|
| `/secrets/azure.conn` | mount | Azure PG host/db/role/password for this project |
| `/ontology/kernel.ttl` | mount | this kernel's classes/shapes/affordances |
| `CKP_PROJECT` | env | project name (DB + role scoping on Azure) |
| `CKP_NATS_BIND` | env | WSS bind (default embedded `:4222`/`:443`) |

**Bring-up:** start pod → entrypoint starts Postgres + `nats-server` → `CREATE EXTENSION`s → bgworker boots (§7) → ready. One command, no external orchestration. This is the marketplace-sandbox shape: click deploy, mount two files + a secret, point at an Azure PG, it runs.

---

## 10. What ships next (immediate build order)

1. **CKP core ontology TTL** — `conceptkernel/core.ttl` (Kernel/Organ/Affordance/LedgerEntry/Proof/Provenance + SHACL shapes). Smallest, unblocks everything.
2. **`conceptkernel` extension skeleton** — pgrx crate: control file, `CREATE EXTENSION` SQL (loads `core.ttl`), bgworker registration, `ckp.*` function stubs.
3. **`docker-entrypoint-ckp.sh`** — start Postgres + nats-server, run `CREATE EXTENSION`s, wait-ready.
4. **`ckp.bootstrap_kernel` + `ckp.seal` + `ckp.validate`** — the governed write path (§4.3) end-to-end against a local stand-in for Azure.
5. **FDW wiring** — swap stand-in for real `postgres_fdw` to Azure.
6. **Affordance compile loop** — `ckp.subscribe` / `recompile_affordances` + the CK-graph trigger.

rc3 is the build target. Items 1–3 are a single sitting and produce a pod that boots.

---

*rc3 supersedes rc1/rc2. Comprehensive surface + v3.7.6 transition: [`SPEC.CKP.v3.8-FUTURE.md`](../../SPEC.CKP.v3.8-FUTURE.md) (note: FUTURE/PLAN/TASKS are stale on the single-pod/extension path — reconcile after rc3 ships).*
