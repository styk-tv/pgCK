# Goal/Task Kernel Board MVP Design

Date: 2026-05-20
Status: Approved for planning
Scope: Goal/Task ontology unification in `core.ttl`, one owner-facing board page, one shared NATS subject, DB insert plus browser fan-out, output-first MVP.

## 1. Problem Statement

The repo currently has three partially overlapping sources of truth for Goal/Task-like concepts:

- `fixtures/ontologies/core.ttl`
- `fixtures/ontologies/base-instances.ttl`
- exported `CK.Goal` / `CK.Task` kernel TTLs under `fixtures/WIP/ref-ck/...`

That split creates collisions and ambiguity:

- `core.ttl` already uses `ckp:taskId` for `ckp:OrganLock`.
- `base-instances.ttl` already defines `ckp:TaskInstance` for consensus-generated tasks.
- `CK.Task` defines a different `TaskInstance` plus a different property vocabulary using snake_case terms such as `task_id`, `lifecycle_state`, and `target_kernel`.

For the MVP, we need one clean model that starts in `core.ttl`, then proves the end-to-end loop:

1. owner creates a task
2. task is validated and inserted into Postgres
3. middle server advertises the update on NATS
4. browser board receives the update and renders it into the correct ConceptKernel column

The board should feel like the existing `CK.Goal` web board: multiple mutable columns, visible queue cards, column toggles, and simple animated insertion/reordering. We are not designing the future audio grammar here; audio remains a later iteration.

## 2. MVP Goals

- Make `core.ttl` the canonical home of the Goal/Task model.
- Keep `base-instances.ttl` generic and non-opinionated.
- Render one live board page with multiple ConceptKernel columns.
- Use one shared NATS subject for browser updates.
- Insert successful tasks into the DB through the existing governed path.
- Show task validity state in the UI using results from validation, seal, and verification steps.
- Reuse the existing `web_demo` browser/NATS mechanics instead of inventing a new frontend transport.

## 3. Explicit Non-Goals

- No generalized workflow engine.
- No multi-subject routing per kernel column.
- No automatic DB-to-NATS bridge inside the pgCK bgworker yet.
- No cross-browser drag persistence.
- No full ontology refactor of every existing CK kernel.
- No custom audio grammar per task in this slice.
- No canonical handling of multi-goal tasks.

## 4. Existing Substrate We Will Reuse

### 4.1 Browser/NATS demo path

The current `web_demo` already has:

- a FastAPI host in `web_demo/app.py`
- a shared subject protocol in `web_demo/protocol.py`
- browser-side NATS-over-WebSocket handling in `web_demo/static/app.js`

It currently supports `theme`, `slide`, and `audio` payloads over one shared subject. The MVP extends that same path with task-board events rather than replacing it.

### 4.2 Governed DB path

The extension SQL in `compose/extensions/pgck/share/extension/pgck--0.1.1.sql` already provides:

- `ckp.boot(...)`
- `ckp.load_kernel(...)`
- `ckp.validate(...)`
- `ckp.seal(...)`
- `ckp.verify(...)`

`ckp.seal(...)` already performs:

1. shape-aware validation against the loaded kernel graph
2. durable write into `ckp.instances`
3. governed ledger entry generation and validation
4. proof entry generation and validation

The MVP middle server should use this path rather than bypassing it.

### 4.3 Board reference interaction model

The reference board in `/Users/neoxr/.config/conceptkernel/ck-data/xrv.localhost/CK.Goal/7b1ddbc5f5ce/data/web/index.html` gives three UI behaviors worth copying:

- column toggles
- queue-style task cards
- animated visual reordering

Important finding: the reference file does not do automatic priority sorting. `priority` is shown as metadata only. The only reordering behavior is drag/drop inside a list.

## 5. Canonical Ontology Design

### 5.1 Ownership boundary

The canonical Goal/Task model moves into `core.ttl`.

`base-instances.ttl` remains the home of:

- `ckp:InstanceManifest`
- `ckp:SealedInstance`
- generic instance mechanics
- ledger/proof/conversation scaffolding

`CK.Goal` and `CK.Task` stop being competing semantic sources of truth. In later cleanup they become thin overlays or imports of the core-defined model.

### 5.2 Canonical classes

For the MVP, `core.ttl` introduces canonical classes:

- `ckp:Goal`
- `ckp:Task`

Both subclass `ckp:SealedInstance`.

Rationale:

- avoids collision with the already-defined `ckp:TaskInstance` in `base-instances.ttl`
- avoids pretending the old `TaskInstance` meaning still matches the new board/task meaning
- gives one clean vocabulary starting from core

### 5.3 Canonical relationships

The approved model is:

- one `Goal` has many `Task`
- one `Task` belongs to exactly one `Goal`
- one `Task` targets exactly one `ConceptKernel`
- external launch URL belongs to the `ConceptKernel`, not the task

### 5.4 Canonical MVP properties

These stay in snake_case and become canonical for this model:

- `ckp:goal_id`
- `ckp:task_id`
- `ckp:title`
- `ckp:lifecycle_state`
- `ckp:part_of_goal`
- `ckp:target_kernel`
- `ckp:priority`
- `ckp:queue_seq`
- `ckp:created_at`
- `ckp:created_by`
- `ckp:detail`

Task validity and display support for the MVP:

- `ckp:shape_valid`
- `ckp:sealed`
- `ckp:verified`
- `ckp:proof_digest`

Kernel-level routing/display support:

- existing `ckp:Kernel` in `core.ttl` remains canonical for columns
- `ckp:launch_url` is added to `ckp:Kernel` for the external machine launch URL use case

### 5.5 Property typing for MVP

For the MVP, the task body remains JSON-first and uses string values for references:

- `part_of_goal` stores the canonical goal id or goal URN string
- `target_kernel` stores the canonical kernel URN/string key used by the board column

Rationale:

- matches the current governed JSON body path
- avoids forcing object-property hydration into the MVP
- keeps the browser/event payload simple

This is intentionally pragmatic. If later work needs richer RDF linking, object properties can be added as derived semantics without renaming the browser/API payload contract.

## 6. Kernel Board Data Model

### 6.1 Columns

Board columns represent ConceptKernels, not goals.

Each column is identified by a kernel key, for example:

- `CK.Task`
- `CK.Goal`
- `CK.ComplianceCheck`
- `LOCAL.ClaudeCode`

Each column has display metadata:

- `kernel_id`
- `title`
- `icon`
- `color`
- `launch_url`
- `visible`

For the MVP this display metadata can live in the middle server config or demo seed data, not in ontology display classes.

### 6.2 Goals

Goals exist as first-class ontology objects and are referenced by tasks, but they do not drive the visible board layout in the MVP. They act as task grouping/context and can be shown in card metadata or filters later.

### 6.3 Tasks

Each task card carries at minimum:

- `task_id`
- `title`
- `part_of_goal`
- `target_kernel`
- `lifecycle_state`
- `priority`
- `queue_seq`
- `created_at`
- `shape_valid`
- `sealed`
- `verified`
- `proof_digest`

Optional display fields:

- `detail`
- `created_by`

## 7. Board Ordering Rules

### 7.1 Canonical order

Canonical queue order is FIFO by `queue_seq`.

This is the durable order stored in the DB.

### 7.2 Visual order

The UI supports visible priority-based emphasis without rewriting canonical FIFO semantics:

- primary visual sort: `priority DESC`
- secondary visual sort: `queue_seq ASC`

This means higher-priority items float upward visually, but items with the same priority still respect FIFO.

This is the MVP answer to the “priority appears to reorder the list” requirement:

- DB truth stays simple and append-only
- browser gets the effect users expect
- we do not invent persistent drag semantics yet

### 7.3 Drag behavior

The reference board’s drag behavior is visual only. For the MVP:

- preserve the drag affordance only if it can be kept local-only in the browser
- do not persist drag reorder to DB
- do not publish drag reorder over NATS

If needed, drag can be omitted entirely in the first cut and replaced by the priority-based visual sort above.

## 8. Browser Event Protocol

### 8.1 Shared subject

Use one shared NATS subject.

Default subject for the MVP:

- `broadcast.demo.display`

Rationale:

- it matches the current `web_demo` mechanics
- minimizes new configuration
- proves DB insert -> publish -> browser receive on the existing path

### 8.2 Event kinds

Keep the existing kinds:

- `theme`
- `audio`

Replace `slide` with board-oriented kinds:

- `task_upsert`
- `board_snapshot`

`board_snapshot` is optional for HTTP parity but useful as a debug and forced-resync primitive.

### 8.3 `task_upsert` payload

```json
{
  "kind": "task_upsert",
  "task": {
    "task_id": "FC-T-0001",
    "title": "Rotate SPIFFE SVIDs",
    "part_of_goal": "FC-G-0001",
    "target_kernel": "CK.ComplianceCheck",
    "lifecycle_state": "pending",
    "priority": 4,
    "queue_seq": 12,
    "created_at": "2026-05-20T20:00:00Z",
    "shape_valid": true,
    "sealed": true,
    "verified": true,
    "proof_digest": "abc123..."
  }
}
```

### 8.4 `board_snapshot` payload

```json
{
  "kind": "board_snapshot",
  "board": {
    "kernels": [
      {
        "kernel_id": "CK.ComplianceCheck",
        "title": "Compliance",
        "icon": "verified",
        "color": "#22c55e",
        "launch_url": "https://machine-a.example",
        "visible": true
      }
    ],
    "tasks": []
  }
}
```

## 9. Middle Server Design

### 9.1 Purpose

The middle server exists because the repo does not yet have an automatic pgCK bgworker bridge from DB writes to browser-facing NATS events.

The middle server is therefore responsible for:

- booting and validating the ontology/kernel substrate
- accepting owner task creation requests
- calling the governed SQL path
- publishing browser-safe events to the shared NATS subject
- serving the live board page and initial board snapshot

### 9.2 Process responsibilities

At startup:

1. connect to Postgres
2. call `ckp.bootstrap_kernel()`
3. load/materialize the required ontology and demo kernel graphs
4. load seed kernel column config and seed goals if missing

On owner task creation:

1. accept request body
2. normalize task payload into canonical core vocabulary
3. verify referenced goal exists
4. verify target kernel is known
5. call `ckp.seal(...)`
6. call `ckp.verify(...)`
7. construct browser event payload including validity fields
8. publish `task_upsert` to the shared NATS subject
9. return JSON response to the owner UI

### 9.3 Why this is acceptable for MVP

This keeps the first version operationally honest:

- DB insert really happens
- validation really happens
- proof rows really happen
- NATS publish really happens
- browser update really happens

Without blocking on the future in-extension dispatch bridge.

## 10. Required Kernel/Shape Construction

### 10.1 Why a demo kernel graph is required

`ckp.seal(...)` does not validate arbitrary JSON by magic. It reads required property constraints from the loaded kernel graph.

Therefore the MVP must provide a small project kernel graph dedicated to this board slice.

### 10.2 Required kernel graph contents

The demo kernel graph must define SHACL constraints for the task and goal payloads used by the owner console.

At minimum:

- a target class for the task payload
- required properties:
  - `task_id`
  - `title`
  - `part_of_goal`
  - `target_kernel`
  - `lifecycle_state`
  - `priority`
  - `queue_seq`
  - `created_at`

Optional but recommended:

- `detail`
- `created_by`

Goal payloads should also have shapes, even if goal creation is seeded rather than interactive in the first cut.

### 10.3 Validity elements

The UI validity chips come from the middle server’s governed result:

- `shape_valid = true` if payload passed shape validation
- `sealed = true` if `ckp.seal(...)` succeeded
- `verified = true` if `ckp.verify(...)` returns true
- `proof_digest` from the returned digest / proof row

If creation fails:

- no durable task row is written
- no `task_upsert` is published
- owner UI receives a structured error response

This keeps the board showing only successfully governed tasks.

## 11. Owner Console / Board UI

### 11.1 Route model

One owner-facing page is enough for the MVP.

Recommended shape:

- top-left: connection/status card
- top-right or top bar: small owner composer form
- main area: kernel columns board

### 11.2 Owner composer controls

Minimal create-only controls:

- goal selector
- target kernel selector
- title
- detail
- priority

No move/reorder controls are required in the owner form.

### 11.3 Board behavior

The board should copy the reference feel, but swap “goal columns” for “kernel columns”:

- toggle visible columns
- animate column entrance/exit
- render queue cards
- animate card insertion
- sort visually by `priority DESC, queue_seq ASC`

### 11.4 Card appearance

Each card should show:

- title
- task id
- target kernel
- goal reference
- lifecycle state
- priority
- validity chips: SHACL, SEAL, VERIFY

Keeping it “silly” for the MVP is acceptable; the important thing is that updates are obvious and correctness signals are visible.

## 12. HTTP API Surface

Minimal HTTP endpoints:

- `GET /` -> owner board page
- `GET /healthz` -> liveness
- `GET /protocol` -> shared-subject message protocol
- `GET /api/board` -> current board snapshot from DB + seed kernel config
- `POST /api/tasks` -> create task, validate/seal/verify, publish `task_upsert`

Optional:

- `GET /api/goals`
- `GET /api/kernels`

## 13. Startup and Runtime Flow

### 13.1 Startup

1. start Postgres/pgCK
2. start local NATS WSS service for browser connectivity
3. start the middle server
4. middle server bootstraps DB substrate and loads demo kernel graph
5. browser loads `/`
6. browser fetches `/api/board`
7. browser subscribes to the shared NATS subject

### 13.2 Happy path task creation

1. owner submits new task
2. server assigns `task_id` and `queue_seq`
3. server calls governed DB path
4. DB writes instance/ledger/proof
5. server publishes `task_upsert`
6. browser inserts task into the correct kernel column
7. task appears with green validity chips

## 14. Failure Handling

### 14.1 Validation failure

If shape validation fails:

- return `4xx`
- include missing fields / reason
- do not insert into `ckp.instances`
- do not publish to NATS

### 14.2 NATS publish failure after successful DB write

For MVP:

- DB write remains authoritative
- server returns success-with-warning or logs the publish failure
- board can recover on reload through `GET /api/board`

This is acceptable because the board snapshot endpoint exists as a resync path.

### 14.3 Browser disconnect

If the browser misses live events:

- reconnect to the shared subject
- refresh with `GET /api/board`

## 15. Verification Requirements

The implementation following this spec must prove:

1. `POST /api/tasks` inserts a governed task into Postgres
2. `ckp.instances`, `ckp.ledger`, and `ckp.proof` all receive the expected rows
3. `ckp.verify(task_instance_id)` returns true for the inserted task
4. the task is published on the shared NATS subject
5. the browser receives the event and renders it into the correct kernel column
6. invalid payloads are rejected and do not create rows

## 16. Files Expected To Change In Implementation

Likely implementation targets:

- `web_demo/app.py`
- `web_demo/protocol.py`
- `web_demo/static/app.js`
- `web_demo/static/app.css`
- new server-side helper modules under `web_demo/`
- tests under `tests/`
- canonical ontology files under `fixtures/ontologies/`
- WIP/exported Goal/Task TTLs under `fixtures/WIP/` only as temporary comparison artifacts

## 17. Deferred Work

Explicitly deferred beyond this MVP:

- audio grammar per task
- custom per-task spoken output
- persistent drag reorder
- per-kernel NATS subjects
- automatic pgCK in-extension publish after DB write
- richer RDF object links for goal/kernel references
- full cleanup of every historical Goal/Task ontology variant

## 18. Final Decision Summary

The approved MVP is:

- canonical Goal/Task semantics start in `core.ttl`
- one owner-facing board page
- columns represent ConceptKernels
- one goal has many tasks; each task belongs to one goal
- each task targets one ConceptKernel
- one shared NATS subject
- create-only owner flow
- governed DB insert first, then publish browser update
- visual priority support implemented as browser sorting over FIFO queue order

This design is intentionally narrow. It proves the ontology direction, the governed DB write path, the NATS fan-out path, and the browser rendering path in one slice without pretending the rest of the platform is already solved.
