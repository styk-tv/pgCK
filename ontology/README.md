# ontology/ — authority, mirrors, and build inputs

## Where authority lives

**The authoritative home of the Concept Kernel Protocol ontology is always the
CK-org publication surface** — repository
[`ConceptKernel/conceptkernel.github.io`](https://github.com/ConceptKernel/conceptkernel.github.io),
path `docs/public/ontology/<version>/`, published at
`https://conceptkernel.org/ontology/<version>/`.

Nothing in this directory is authoritative. Every file here is one of two
things:

1. a **byte-verified mirror** of that surface (the `v3.11/` and `v3.8/`
   subdirectories), or
2. a **pgCK build input** (the top-level `.ttl` files), which either mirrors
   the authority byte-for-byte (`core.ttl`) or awaits re-issue against it
   (the module files — see below).

The v3.11 surface is not yet live at `conceptkernel.org`. **It is authoritative
regardless**: authority is established **by digest against the published
sidecar** — never by reachability, and never by a validator's conformance
report (a validator reports conformance against an absent shapes graph too;
the root's own header states this caveat).

A copy of an ontology in this repo — or loaded in a store — is **not in
force** by being present. A module is in force only because a sealed
`ckp:Adoption` names its `moduleDigest`. *Proximity is not adoption*
(SPEC.CKP v3.11 §2).

## The catalog

| Path | Namespace line | Role | Digest (sha256) |
|---|---|---|---|
| `core.ttl` (+ `core.ttl.sha256`) | **v3.11** | build input — byte-identical mirror of the v3.11 root | `e5f7d1e54b32fa0ba2d41ba248e0909b96ee1ebb4344e2d9e9ccdf4e0b25348d` |
| `v3.11/core.ttl` | **v3.11** | mirror of the publication surface (root, self-contained: 948 triples · 27 classes · 27 shapes · 80 properties) | `e5f7d1e5…` (same as above) |
| `v3.11/modules/wave.ttl` | v3.11 | mirror — the coordination-wave vocabulary module | `f4ad27cec4417e2ed5b566adb7f7ee200b3c3fbfddf25adf840d267fd57e417b` |
| `v3.11/modules/lexicon.ttl` | v3.11 | mirror — the closed defect-symptom lexicon module | `ce9f20f4dc43b79b704a1266ca69956890b006564824c051d44eb31cc90b0329` |
| `v3.11/index.html` | — | mirror — the publication page (states the digest discipline of itself) | — |
| `v3.8/core.ttl`, `v3.8/index.html` | **v3.8** | mirror of the published legacy surface, for reference | `6c4aa53a2abfcd9b907682bb26ee3c682248bc74e8d0648bcd42c4893bb1cf86` |
| `task.ttl` `goal.ttl` | **v3.11 (interim)** | board module build inputs, re-pointed so the board shapes gate what the substrate emits; lasting form is the [#47](https://github.com/styk-tv/pgCK/issues/47) re-issue | — |
| `proof.ttl` `validate.ttl` `affordance.ttl` `delegation.ttl` `delivery.ttl` | **v3.8** | pgCK module build inputs on the legacy line | — |

Earlier published versions (v3.4 … v3.9) live at the same CK-org surface and
are not mirrored here.

## The module files

Five module `.ttl` files still carry the v3.8 namespace. This is deliberate
and tracked: no v3.11 module authority has been published for them yet. They
are **not** migrated in place — the v3.11 resolution is that modules are
**re-issued as digest-addressed entities** against the v3.11 core and adopted
by digest, like everything else
([#47](https://github.com/styk-tv/pgCK/issues/47)). Until then they are the
legacy line: do not author new v3.8 content against them
(see also [#46](https://github.com/styk-tv/pgCK/issues/46) for v3.7 residue).

`task.ttl` and `goal.ttl` carry an **interim v3.11 re-point** (#49): the
board's `shapes_self_test` requires v3.11 `TaskShape`/`GoalShape`, and a
v3.8 shape targets nothing the re-pointed substrate emits. The interim is
named as such in each file's header; the lasting form is the #47 re-issue.

## Verifying a mirror

```sh
# the root: sidecar and file must agree, and match the table above
shasum -a 256 ontology/v3.11/core.ttl
cat ontology/v3.11/core.ttl.wave-3.11-pass-10.sha256

# the build input must be byte-identical to the mirror
cmp ontology/core.ttl ontology/v3.11/core.ttl && echo identical
```

## Update discipline

- **Never edit a mirror here.** Changes land at the CK-org surface first;
  then re-copy and re-verify the digest.
- The top-level `core.ttl` moves **only** to track a new published root, in
  the same change that re-points whatever binds to it (the namespace and the
  root move in one act or neither).
- Sidecar files are named for the wave pass that established them; the
  highest pass number is current.
