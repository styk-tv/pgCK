# `scripts/` — devops tooling only

## The rule (binding)

**No file in `scripts/` may participate in the live runtime communication path.**

The published pgCK system ships as **Python-free OCI bundles** (s6 + busybox httpd, scratch base — see `oci-germination` `ck-allinone`). Anything that mediates the browser ↔ kernel conversation at runtime therefore **cannot be Python** — it would simply be absent in production and the feature would break.

| Class | Allowed here? | Test |
|---|---|---|
| **devops** | ✅ yes (any language) | Runs during build / test / setup / one-shot migration / CI, then **exits**. Provisions or checks; never in the request path. |
| **ops** | ❌ **no** | Stays running to serve live messages, sits in a request/response loop, or mediates browser ↔ kernel. **Belongs in the Rust extension (`src/`), not here.** |

Quick discriminator: *does it exit after doing its job, or does it stay up handling traffic?* Exits → devops, fine. Stays up in the message loop → ops, forbidden in `scripts/`.

Ops logic lives in **`src/`** (the Rust `pgck` extension / bgworker) and runs **inside** the database — `ckp.seal`, `ckp.verify`, NATS publish, affordance dispatch. That is what ships, Python-free.

## Current files

| File | Class | Status |
|---|---|---|
| `generate-dev-certs.sh` | devops (TLS setup) | ✅ ok |
| `gh-watch.sh` | devops (CI watch, then exits) | ✅ ok |
| `gen_protocol_json.py` | devops (build-time asset gen) | ✅ ok |
| `export_ck_ttls.py` | devops (one-shot TTL export) | ✅ ok |
| `import_ttls_into_pgck.py` | devops (one-shot import) | ✅ ok |
| `tutorial_dispatcher.py` | **ops — VIOLATION** | ❌ **delete.** A Python process subscribed to `input.kernel.pgCK.action.>` that calls `ckp.seal` — it is in the live path. It exists only as a throwaway local scaffold for the browser tools (board / explorer / forge / tutorial). It does **not** ship and must not be depended on. Its verbs (`affordances`, `task.create`, `task.update`, `snapshot.board`, `provenance`, `kernel.detail`, `shape.validate`, `shape.seal`, `participant.join`) move to the **Rust CKA-4 dispatcher** in `src/` (bgworker subscribes the action topics, runs the SQL via SPI, publishes `result.kernel.pgCK.action.<verb>`). Once CKA-4 ships, delete this file. |

## Do not

- Do not add a Python (or any non-`src/`) component that handles live NATS traffic, HTTP requests, or the browser ↔ kernel loop.
- Do not build a feature whose runtime correctness depends on a `scripts/` process being up. If it must run to serve users, it belongs in `src/`.
