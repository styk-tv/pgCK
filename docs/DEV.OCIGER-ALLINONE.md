# pgCK Development with ociger-ck-allinone Container

**Status:** 2026-05-26 | Development setup for Goal/Task Board MVP  
**Target Audience:** oci-germination maintainers, CK.Lib.Js integrators, pgCK developers

---

## Overview

`ghcr.io/sporaxis-com/ociger-ck-allinone:v0.2` is a complete single-container development environment for pgCK v3.8-rc work. It includes:

- **PostgreSQL 17.10** with pgRDF 0.5.1 and pgCK 0.1.2 extensions
- **Embedded NATS Core listener** (TCP 4222, internal)
- **Native NATS server** with WSS bridge (exposed as 9222)
- **Supervisor** managing Postgres + NATS runtime
- **pgck-web OCI layer** v0.1.0 (FastAPI on port 8000)
- **CK.Lib.Js v1.2.0** static client harness (mounted at `/cklib`)

**Key principle:** Single container, update only pgck-web layer for iteration; everything else (Postgres, NATS, extensions) stays stable.

---

## Running Locally (macOS + colima)

### 1. Pull and Start

```bash
docker pull ghcr.io/sporaxis-com/ociger-ck-allinone:v0.2

docker run -d --name pgck-ociger-allinone-dev \
  -p 15432:5432 \
  -p 8000:8000 \
  -p 14222:4222 \
  -p 19222:9222 \
  ghcr.io/sporaxis-com/ociger-ck-allinone:v0.2

sleep 3
docker logs pgck-ociger-allinone-dev | tail -10
```

### 2. Verify Services

```bash
# PostgreSQL
psql -h localhost -p 15432 -U postgres -c "SELECT version();"

# FastAPI (pgck-web)
curl http://localhost:8000/

# NATS Core (internal)
nc -zv localhost 14222

# NATS WSS Bridge (for browser clients)
curl -i http://localhost:19222/ 2>&1 | head -5
```

Expected output:
- PostgreSQL: version string
- FastAPI: HTML response (or "Bad Request" from curl without proper headers — normal)
- NATS Core: Connection succeeded
- WSS Bridge: HTTP 400 (WebSocket upgrade not available to curl — expected)

### 3. Access Points

| Service | Host Port | Container Port | Purpose |
|---------|-----------|-----------------|---------|
| PostgreSQL | 15432 | 5432 | Database with pgCK + pgRDF extensions |
| FastAPI (pgck-web) | 8000 | 8000 | Web UI entry point + API routes |
| NATS Core | 14222 | 4222 | Internal NATS (TCP only, no WSS) |
| NATS WSS Bridge | 19222 | 9222 | Browser WebSocket → NATS gateway |

---

## Development Workflow

### Iterating on pgck-web (FastAPI + Static Assets)

**Scenario:** You've updated `web/` source code and want to test in the container.

1. **Rebuild pgck-web locally:**

```bash
cd /Users/neoxr/git_conceptkernel/pgCK
compose/layers/pgck-web/build.sh
# This detects your arch (arm64/amd64) and builds locally
```

2. **Publish to GHCR (if you want to push a new layer for CI):**

```bash
docker tag styk-tv/pgck-web:latest ghcr.io/styk-tv/pgck-web:v0.X.0
docker push ghcr.io/styk-tv/pgck-web:v0.X.0
```

3. **Update oci-germination bundle.yaml to consume the new layer:**

In `/Users/neoxr/git_sporaxis-com/oci-germination/bundles/bundle-pg17-pgrdf-pgck-web-cklib/bundle.yaml`:

```yaml
components:
  pgckweb:
    version: 0.X.0  # ← bump here
    source: https://github.com/styk-tv/pgCK/tree/main/web
```

Then oci-germination rebuilds the all-in-one container with the new pgck-web layer.

4. **For local-only testing (dev loop):**

Mount your local `pgCK/web/` source over the container's FastAPI app:

```bash
docker run -d --name pgck-ociger-dev-local \
  -p 15432:5432 \
  -p 8000:8000 \
  -p 14222:4222 \
  -p 19222:9222 \
  -v /Users/neoxr/git_conceptkernel/pgCK/web:/opt/pgck-web/app \
  ghcr.io/sporaxis-com/ociger-ck-allinone:v0.2
```

Edit `web/app/main.py` locally, FastAPI will auto-reload (if the container's Dockerfile uses `--reload`).

---

## Development Notes for oci-germination

### 1. Layer Composition

The all-in-one container is composed from these independent OCI artifacts:

```
ociger-ck-allinone:v0.2
├── ociger-pg17-pgrdf-pgck-nats-micro:v0.1.1 (base: Postgres + pgRDF + pgCK + NATS Core)
└── Layer: pgck-web v0.1.0 (FastAPI web server)
└── Layer: ck-lib-js v1.2.0 (static JS client harness, mounted at /cklib)
```

Each layer is independent and versioned. When updating:

1. **pgck-web:** Rebuild + test locally, push to ghcr.io/styk-tv/pgck-web, update bundle.yaml
2. **ck-lib-js:** Rebuild in CK.Lib.Js repo, publish to ghcr.io/conceptkernel/ck-lib-js, update bundle.yaml
3. **Postgres + pgCK + pgRDF:** Update base image reference in bundle.yaml

### 2. Layer Semantics

Per CKP v3.8 ontology:

- **ociger-pg17-pgrdf-pgck-nats-micro** = infrastructure layer (storage + kernel runtime + messaging core)
- **pgck-web** = `ckp:WebServing` (HTTP server for static + API routes)
- **ck-lib-js** = `ckp:WebServing` (browser client harness, will replace pgck-web FastAPI post-MVP)

### 3. For Future v1.2.0+ Integration

Once CK.Lib.Js v1.2.0 ships its OCI bundle:

- pgck-web FastAPI routes will shrink to static file serving only
- Browser client will use CK.Lib.Js for NATS/affordance dispatch instead of HTTP
- Remove HTTP dependency from the stack
- Update bundle.yaml to drop pgck-web API routes

---

## PostgreSQL Access and Queries

### Connect to DB

```bash
psql -h localhost -p 15432 -U postgres

# Inside psql:
\dt ckp.*        -- list pgCK tables
SELECT * FROM ckp.instances LIMIT 5;
SELECT * FROM ckp.ledger LIMIT 5;
```

### Verify pgCK Extensions

```bash
psql -h localhost -p 15432 -U postgres -c "SELECT * FROM pg_extension WHERE extname LIKE 'pgck%';"
```

Expected: pgck extension should be installed.

### Verify pgRDF Extensions

```bash
psql -h localhost -p 15432 -U postgres -c "SELECT * FROM pg_extension WHERE extname LIKE 'pgrdf%';"
```

Expected: pgrdf extension should be installed.

---

## NATS / WSS Bridge

### NATS Core (Internal, TCP)

The embedded NATS Core listener (port 14222) is for **pgCK internal use only** (Python router → NATS subjects). Not exposed for browser use.

Verify from host (if NATS CLI installed):

```bash
nats --server=nats://localhost:14222 server info
```

### WSS Bridge (Browser-Facing)

The native NATS server with WSS listener (port 19222) is for **browser clients**. CK.Lib.Js connects here.

Check connectivity:

```bash
# Can't curl directly (it's WebSocket upgrade), but connectivity is OK
nc -zv localhost 19222
# Connection to localhost port 19222 [tcp/*] succeeded!
```

Browser code (CK.Lib.Js v1.1.0+) connects as:

```javascript
const client = new KernelClient({
  natsUrl: "wss://localhost:19222"  // or wss://yourhost:19222 for remote
});
```

---

## Docker Cleanup

### Stop Container

```bash
docker stop pgck-ociger-allinone-dev
```

### Remove Container

```bash
docker rm pgck-ociger-allinone-dev
```

### View Logs

```bash
docker logs -f pgck-ociger-allinone-dev
docker logs pgck-ociger-allinone-dev | grep -i error
```

---

## Troubleshooting

### Port Already in Use

If you get "Bind for 0.0.0.0:8000 failed: port is already allocated":

```bash
# Find what's using the port
lsof -i :8000

# Stop existing container
docker stop pgck-ociger-allinone-dev

# Or use different host ports
docker run -d --name pgck-ociger-dev \
  -p 8001:8000 \
  -p 15433:5432 \
  ...
```

### Container Exits Immediately

Check logs:

```bash
docker logs pgck-ociger-allinone-dev
```

Common issues:
- PostgreSQL initialization timeout (wait 10 seconds after start)
- NATS port conflict with embedded listener
- Supervisor daemon failed to start services

---

## What's Next

1. **Goal/Task Board MVP** — FastAPI routes + pgCK seal path + NATS broadcast to browser
2. **Static Site Serving** — pgck-web now serves `/tasks.html` and `/display.html`
3. **CK.Lib.Js Integration** — Browser uses CK.Lib.Js v1.1.0 for NATS, drops HTTP API calls (post-MVP)
4. **Binary Compact Delta** — CK.Lib.Js v1.3.0 optimization for high-frequency streams

---

## References

- **oci-germination repo:** `/Users/neoxr/git_sporaxis-com/oci-germination`
- **pgCK MVP spec:** `/Users/neoxr/git_conceptkernel/pgCK/_WIP/SPEC.PGCK.GOAL-TASK-KERNEL-BOARD-MVP.v0.1.md`
- **NATS spec (v3.8-rc-06):** `/Users/neoxr/git_conceptkernel/pgCK/_WIP/SPEC.CKP.v3.8-rc-06-nats.md`
- **CK.Lib.Js publishing guide:** `/Users/neoxr/git_sporaxis-com/oci-germination/GUIDE.CK.LIB.JS.PUBLISHING.md`
- **CK.Lib.Js & pgCK alignment:** `/Users/neoxr/git_conceptkernel/CK.Lib.Js/COMPLIANCE.v0.2-pgCK-ALIGNMENT.md`
