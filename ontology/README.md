# ontology/ — authority and mirrors

## Where authority lives

**THIS DIRECTORY IS THE AUTHORITATIVE SOURCE** (operator ruling 2026-08-26,
reversing the earlier mirror arrangement). The CK-org publication surface —
[`ConceptKernel/conceptkernel.github.io`](https://github.com/ConceptKernel/conceptkernel.github.io)
→ `https://conceptkernel.org/ontology/<version>/` — **pulls from this folder on
change of digest**, per the digest-marker contract below. Authority is still
established **by digest** — never by reachability, and never by a validator's
conformance report (a validator reports conformance against an absent shapes
graph too; the root's own header states this caveat) — the ruling changes which
end authors the bytes, not how anyone verifies them.

A copy of an ontology in this repo — or loaded in a store — is **not in
force** by being present. A module is in force only because a sealed
`ckp:Adoption` names its digest and the composed surface derives from it.
*Proximity is not adoption* (SPEC.CKP v3.11 §2). Since pgck `0.4.35`
composition is adoption-derived; since `0.4.57` an Adoption's `intoProject`
matches in any of its sealed spellings.

## The catalog — v3.12 FINAL (the boot default) and the v3.11 line beside it

**v3.12 was promoted from RC2 to FINAL on 2026-08-26 by operator ruling — the
bytes are the RC2 bytes, unchanged, so the digest carries over.** The container
bundles unpack ontologies from *older pgck releases* and are therefore stale
until oci-germination cuts a bundle against pgck ≥ 0.4.82; until then **this
directory is the only current source**. The v3.12 root binds the
`…/v3.11/core#` namespace deliberately — the graph IRI line does not move, the
LAW carries the version — so v3.12 is v3.11 + the scoring vocabulary
(`ckp:Signal`, `ckp:Score`, the seven gated constants) + the executable-
affordance properties: 30 NodeShapes = 27 + 3.

| Path | Role | Digest (sha256) |
|---|---|---|
| `v3.12/core.ttl` | **the root — the `ckp.boot()` default since 0.4.82**: 30 shapes = 27+3. **Revised 2026-08-28 (wave-3.12 pass-1)**: `ckp:transportSegment` + its `sh:pattern`; supersedes FINAL `7de02b35…` | `97f97cb22baa6e710bd088226728aef693c32ff33d0380105c4a9174f3f4857e` |
| `v3.12/core.ttl.wave-3.12-pass-1.sha256` | **the CURRENT digest sidecar** — wave-3.12 pass-1, 2026-08-28: `ckp:transportSegment` declared on `ckp:Kernel` and constrained in `ckp:KernelShape` with `sh:pattern "^[a-z0-9]+(-[a-z0-9]+)*$"`, moving the lowercase-kernel-id rule out of PL/pgSQL and into the composed surface (rc1/rc2/FINAL sidecars retained as history and fail by design) | — |
| `v3.12/modules/wave.ttl` | the wave module, v3.12 shelf (Finding requires `rdfs:label`; ruled-at-pass retyped) | `ad887db28c6e0ea04c7cbd835c40dc5441f073be988475a9634c76e9131db727` |
| `v3.11/modules/recon.ttl` | the recon reference spore, namespace-corrected re-issue (cut in wave-v3.12; the namespace tracks the LINE) | `b2b11f1b76e22f7bfac10be3eba7b5104ff0d5d0a1d92147ec3dc392f1475d7d` |
| `v3.12/modules/recon.ttl` | **superseded** (wrong-namespace original) — retained ONLY because sealed Adoptions cite it and composition fails closed on an absent adopted graph | `6a7c199e7ad19580…` (sidecar `-superseded`) |
| `v3.11/core.ttl` | the prior root — ships beside v3.12 for benches pinned to it | `e5f7d1e54b32fa0ba2d41ba248e0909b96ee1ebb4344e2d9e9ccdf4e0b25348d` |
| `v3.11/modules/wave.ttl` | the coordination-wave vocabulary module (11 shapes) | `f4ad27cec4417e2ed5b566adb7f7ee200b3c3fbfddf25adf840d267fd57e417b` |
| `v3.11/modules/lexicon.ttl` | the closed defect-symptom lexicon module — **wave-3.12 revision: the closed sets gained teeth** (assertion gates + derived-only fences; 6 shapes = 4 + 2) | `5def86bacfe3d2a8a6a85e9c81f8f9d77c3cfeee72509a360b2b00433d3cf21c` |
| *(lexicon, superseded revision)* | the 4-shape original — retained only in sealed Adoptions that cite it (`…pass-19` sidecar) | `ce9f20f4dc43b79b704a1266ca69956890b006564824c051d44eb31cc90b0329` |
| `v3.11/index.html` | the publication page (states the digest discipline of itself) | — |

## The digest-marker contract (for CK-org's automated pull — added 2026-08-26)

Every published `.ttl` carries at least one `<file>.<wave-tag>.sha256` sidecar.
The rules an automated consumer relies on:

1. **The file's own sha256 IS its identity.** "On change of digest" means the
   `.ttl` bytes changed — watch the file, not the sidecar set.
2. **The current sidecar is the one `shasum -c` passes against the current
   bytes** — the highest wave tag among the passing ones. Usually exactly one;
   a promotion that keeps the bytes (rc2 → FINAL on the v3.12 root) leaves two
   tags legitimately pinning one digest. Zero passing sidecars is the drift
   signal, never the count.
3. **Historical sidecars are RETAINED and fail against current bytes by
   design** — they pin superseded revisions (`…pass-7` on the v3.11 core,
   `…rc1` on the v3.12 core) so old citations stay checkable. A `-c` failure
   on a historical sidecar is not drift; a `-c` failure on EVERY sidecar of a
   file is.
4. A new revision ships **bytes + its new sidecar in the same commit** — a
   commit that moves one without the other is a defect (the suite's audit
   instrument checks this on the root).

`ckp.boot()` reads `/ontology/v3.12/core.ttl` since `0.4.82` (previously
`/ontology/v3.11/core.ttl`, moved there at `0.4.40`). Existing v3.11-booted
databases are untouched — boot is an install-time act, and re-grounding a live
kernel is a governed act, never an upgrade side effect. **These digests are
load-bearing on the live substrate**: `bindsRoot` in sealed `wave:Statement`s
names a root digest, and the wave/lexicon Adoptions name the module digests —
re-verify any of them against this table without asking anyone.

## What is deliberately NOT here any more

Earlier revisions of this directory carried a top-level `core.ttl` build
input, a `v3.8/` mirror, and seven legacy module files
(`task` `goal` `proof` `validate` `affordance` `delegation` `delivery`).
**All are removed from the tree**, and the removals are enforcement, not
housekeeping:

- the five superseded v3.8 modules were **retired at 0.4.39** (C2) —
  `import_module` refuses them by name;
- `task`/`goal` are retired with them; the board vocabulary is **not** a
  substrate module — since `0.4.51` `instance.link`/`notify` carry no
  substrate-default board class, and a project that wants the legacy board
  vocabulary declares it in its own kernel graph (the smoke fixtures are the
  worked example);
- the boot default moved to `/ontology/v3.11/core.ttl` at `0.4.40`, ending the
  top-level build-input copy.

The lasting form for domain modules remains the
[#47](https://github.com/styk-tv/pgCK/issues/47) re-issue: modules are
**re-issued as digest-addressed entities** against the v3.11 core and adopted
by digest, like everything else.

**v3.8 and every earlier line are RETIRED and will not be published forward.**
Their history is preserved in exactly one place — the CK-org publication
surface (`conceptkernel.org` gh-pages), where published versions are
immutable — and **nowhere in pgCK**: not mirrored here, not loadable by
`import_module`, not authorable. pgCK carries the v3.11 line exclusively;
references to v3.8 in migration comments and the changelog are record, not
surface. (See [#46](https://github.com/styk-tv/pgCK/issues/46) for the last
v3.7 residue.)

## Verifying the mirror

```sh
# file, sidecar and the table above must agree, three for three
shasum -a 256 ontology/v3.11/core.ttl ontology/v3.11/modules/wave.ttl ontology/v3.11/modules/lexicon.ttl
cat ontology/v3.11/core.ttl.wave-3.11-pass-10.sha256
cat ontology/v3.11/modules/wave.ttl.wave-3.11-pass-12.sha256
cat ontology/v3.11/modules/lexicon.ttl.wave-3.11-pass-19.sha256
```

And the in-force half, through the door (never by proximity):

```
ck_do surface.typecheck {"type": ".../wave#Finding"}   → admitted, shaped, via composed
ck_focus                                               → modules present, quad counts
```

## Update discipline

- **This folder authors; CK-org republishes.** A change lands HERE as
  bytes + new sidecar in one commit (contract rule 4); the CK-org surface
  follows the digest. Never edit the CK-org copy directly.
- Sidecar files are named for the wave pass that established them; the
  highest pass number is current (`pass-10` supersedes `pass-7` for the root).
- A new root version arrives as a new `v<version>/` directory in the same
  change that re-points whatever binds to it — the namespace and the root
  move in one act or neither.
