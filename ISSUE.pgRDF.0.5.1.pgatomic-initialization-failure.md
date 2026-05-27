---
title: "pgRDF 0.5.1: PgAtomic Initialization Failure on ckp.boot()"
severity: critical
status: open
date_reported: 2026-05-27
version: pgRDF 0.5.1
postgresql_version: PostgreSQL 17.10
environment: ociger-ck-allinone:v0.2 container (aarch64)
---

# pgRDF Extension: PgAtomic Initialization Failure

## Problem Summary

When bootstrapping a fresh pgCK kernel using `CALL ckp.boot()` on a newly initialized database with pgRDF 0.5.1, the operation fails with:

```
ERROR:  PgAtomic was not initialized
CONTEXT:  SQL statement "SELECT pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#')"
PL/pgSQL function ckp.boot(text) line 15 at PERFORM
```

This blocks initialization of any pgCK governance kernel that depends on loading RDF ontologies at bootstrap time.

## Reproduction Steps

### 1. Environment Setup
```bash
docker pull ghcr.io/sporaxis-com/ociger-ck-allinone:v0.2
docker run -d --name pgck-test \
  -p 15432:5432 \
  ghcr.io/sporaxis-com/ociger-ck-allinone:v0.2
sleep 5
```

### 2. Create Database and Load Extensions
```bash
psql -h 127.0.0.1 -p 15432 -U postgres -c "CREATE DATABASE pgck;"
psql -h 127.0.0.1 -p 15432 -U postgres -d pgck << 'EOF'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION pgrdf CASCADE;
CREATE EXTENSION pgck CASCADE;
EOF
```

### 3. Copy Ontologies into Container
```bash
docker cp ontology/ pgck-test:/ontology/
docker cp examples/ pgck-test:/examples/
```

### 4. Attempt Bootstrap
```bash
psql -h 127.0.0.1 -p 15432 -U postgres -d pgck << 'EOF'
\set ON_ERROR_STOP 1
CALL ckp.bootstrap_kernel();
CALL ckp.boot();
EOF
```

### Result
```
CALL
ERROR:  PgAtomic was not initialized
CONTEXT:  SQL statement "SELECT pgrdf.parse_turtle(v_ttl, v_core, 'urn:ckp:core#')"
PL/pgSQL function ckp.boot(text) line 15 at PERFORM
```

## Error Context

The failure occurs in `ckp.boot()` → `pgrdf.parse_turtle()` when attempting to parse the core RDF ontology on first connection. The PgAtomic shared memory structure is never initialized, suggesting either:

1. **Missing Initialization Step**: pgRDF's shared memory setup hook not being called
2. **Extension Load Order**: pgcrypto or another dependency loaded in wrong order
3. **Container/Platform Issue**: aarch64 (ARM) specific shared memory issue in distroless container
4. **Version Mismatch**: pgRDF 0.5.1 incompatible with PostgreSQL 17.10 on this platform

## Environment Details

| Component | Version | Notes |
|-----------|---------|-------|
| Container | ociger-ck-allinone:v0.2 | distroless/base-debian12 |
| PostgreSQL | 17.10 | Debian 17.10-1.pgdg12+1 |
| pgcrypto | (bundled) | PostgreSQL standard |
| pgRDF | 0.5.1 | From container image |
| pgCK | 0.1.2 | From container image |
| Platform | aarch64 | Apple Silicon via colima |
| OS | macOS 23.6.0 | Host running colima/Docker |

## Test Results

### What Works
- ✅ Extensions load without error: `CREATE EXTENSION pgcrypto, pgrdf, pgck`
- ✅ `CALL ckp.bootstrap_kernel()` succeeds
- ✅ Extensions appear in `pg_extension` catalog
- ✅ Basic pgRDF functions callable in isolation

### What Fails
- ❌ `CALL ckp.boot()` fails immediately on `pgrdf.parse_turtle()` call
- ❌ Attempting retry with fresh connection/session still fails
- ❌ PgAtomic initialization never occurs

## Attempted Workarounds

### 1. Retry with New Connection
```sql
-- Result: Same error on new psql session
CALL ckp.boot();
```
**Outcome**: ❌ Failed — PgAtomic still not initialized

### 2. Explicit pgRDF Initialization
```sql
-- No explicit initialization function found in pgRDF API
SELECT pgrdf.init();  -- Does not exist
```
**Outcome**: ❌ Failed — no public initialization function

### 3. Direct parse_turtle() Call
```sql
SELECT pgrdf.parse_turtle('PREFIX ex: <http://example.org/> ex:test a ex:Thing .', 
                          'urn:default', 'urn:ex#');
```
**Outcome**: ❌ Failed — "PgAtomic was not initialized"

## Hypothesis

pgRDF's PgAtomic shared memory structure is initialized in a PostgreSQL startup hook (likely `_PG_init()` in pgRDF C code). On first connection or first RDF operation, the hook should have fired, but:

1. **Hook Never Fired**: pgRDF's module initialization code didn't run, or ran but failed silently
2. **Shared Memory Allocation Failed**: The VZ hypervisor in colima or container environment may not provide required shared memory capabilities
3. **Version Incompatibility**: pgRDF 0.5.1 was built for PostgreSQL 16.x and has compatibility issues with 17.10

## Questions for pgRDF Maintainers

1. Is pgRDF 0.5.1 tested and supported on PostgreSQL 17.10?
2. What are the minimum shared memory requirements (`shared_preload_libraries` configuration)?
3. Is PgAtomic initialization automatic on extension load, or does it require explicit `CALL` or GUC setting?
4. Are there known issues with aarch64/ARM64 builds?
5. Is the distroless container environment supported (no /usr/bin tools, minimal libc)?

## Impact on pgCK MVP

**Blocked:** Goal/Task Kernel Board MVP cannot complete end-to-end governance testing because:
- Cannot initialize pgCK kernel on first connection
- Cannot load SHACL ontologies or domain vocabulary
- Cannot seal tasks with `ckp.seal()` (depends on bootstrapped state)
- Cannot verify proofs with `ckp.verify()`

**Workaround Available:** Use FastAPI UI with in-memory task storage (non-governed) for UI/UX demonstration, but governance path is untestable.

## Reproduction Checklist

- [x] Issue reproducible in ociger-ck-allinone:v0.2 container
- [x] Issue reproducible with fresh pgck database
- [x] All prerequisites (extensions, ontologies) confirmed present
- [x] Bootstrap succeeds but boot() fails consistently
- [x] Error occurs in pgRDF C code (pgrdf.parse_turtle), not pgCK plpgsql
- [x] Manual retry and workarounds all fail
- [ ] Verified with newer pgRDF version (needs investigation)
- [ ] Verified on PostgreSQL 16.x (needs test environment)
- [ ] Verified on x86_64 host (needs test environment)

## References

- pgRDF Repository: https://github.com/styk-tv/pgRDF
- pgCK Repository: https://github.com/styk-tv/pgCK
- Bootstrap Call Stack: `ckp.boot(text)` → `pgrdf.parse_turtle()` (line 15 of ckp.boot)
- Related OCI Bundle: `bundle-pg17-pgrdf-pgck-web-cklib` in oci-germination

## Suggested Next Steps

1. **Investigate pgRDF Version**: Check if newer pgRDF version available, or if 0.5.1 has known PostgreSQL 17 incompatibilities
2. **Check PostgreSQL Configuration**: Verify `shared_preload_libraries` and shared memory settings in container
3. **Test on x86_64 Host**: Determine if issue is ARM-specific or generic
4. **Enable pgRDF Debug Logging**: If available, run with pgRDF debug output to see where PgAtomic init fails
5. **Contact pgRDF Maintainers**: File issue with styk-tv/pgRDF repo including this reproduction case

---

**Created By:** Claude Code (automated investigation)  
**Last Updated:** 2026-05-27 06:45 UTC  
**Status:** OPEN - Awaiting pgRDF investigation or version upgrade
