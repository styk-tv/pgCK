# ontology/ — authority and mirrors

## Where authority lives

**The authoritative home of the Concept Kernel Protocol ontology is always the
CK-org publication surface** — repository
[`ConceptKernel/conceptkernel.github.io`](https://github.com/ConceptKernel/conceptkernel.github.io),
path `docs/public/ontology/<version>/`, published at
`https://conceptkernel.org/ontology/<version>/`.

Nothing in this directory is authoritative. Every file here is a
**byte-verified mirror** of that surface. The v3.11 surface is not yet live at
`conceptkernel.org`. **It is authoritative regardless**: authority is
established **by digest against the published sidecar** — never by
reachability, and never by a validator's conformance report (a validator
reports conformance against an absent shapes graph too; the root's own header
states this caveat).

A copy of an ontology in this repo — or loaded in a store — is **not in
force** by being present. A module is in force only because a sealed
`ckp:Adoption` names its digest and the composed surface derives from it.
*Proximity is not adoption* (SPEC.CKP v3.11 §2). Since pgck `0.4.35`
composition is adoption-derived; since `0.4.57` an Adoption's `intoProject`
matches in any of its sealed spellings.

## The catalog — the complete v3.11 mirror set

| Path | Role | Digest (sha256) |
|---|---|---|
| `v3.11/core.ttl` | **the root** — self-contained: 948 triples · 27 classes · 27 shapes · 80 properties | `e5f7d1e54b32fa0ba2d41ba248e0909b96ee1ebb4344e2d9e9ccdf4e0b25348d` |
| `v3.11/modules/wave.ttl` | the coordination-wave vocabulary module (11 shapes) | `f4ad27cec4417e2ed5b566adb7f7ee200b3c3fbfddf25adf840d267fd57e417b` |
| `v3.11/modules/lexicon.ttl` | the closed defect-symptom lexicon module (4 shapes) | `ce9f20f4dc43b79b704a1266ca69956890b006564824c051d44eb31cc90b0329` |
| `v3.11/index.html` | the publication page (states the digest discipline of itself) | — |

This set is what `ckp.boot()` reads (`/ontology/v3.11/core.ttl`, the ε0 root)
and what sealed Adoptions bind by the digests above. **These three digests are
load-bearing on the live substrate**: `bindsRoot` in every sealed
`wave:Statement` names the root digest, and the wave/lexicon Adoptions name
the module digests — re-verify any of them against this table without asking
anyone.

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

- **Never edit a mirror here.** Changes land at the CK-org surface first;
  then re-copy and re-verify the digest.
- Sidecar files are named for the wave pass that established them; the
  highest pass number is current (`pass-10` supersedes `pass-7` for the root).
- A new root version arrives as a new `v<version>/` directory in the same
  change that re-points whatever binds to it — the namespace and the root
  move in one act or neither.
