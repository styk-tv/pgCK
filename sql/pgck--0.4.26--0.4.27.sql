-- pgck 0.4.26 -> 0.4.27
--
-- BUILD IDENTITY. Adds ckp.build_id(), the one identifier that survives a
-- wrong drop, and ckp.version(), the bare semver the shared-builder contract
-- (SPEC.RUST-BUILDER.CK.v3.11 §7) asks every extension on the builder to
-- expose. 0.4.26 is the flatten baseline (#31, namespace-neutral) and does
-- not carry the pair; 0.4.27 is the flatten plus build identity.
--
-- Why an upgrade script at all: the pair is a SQL SURFACE change. pgrx emits
-- it into the generated INSTALL script (from `#[pg_schema] pub mod ckp` in
-- src/lib.rs), which only runs on CREATE EXTENSION. An existing database
-- reaches a new version through ALTER EXTENSION ... UPDATE, which runs the
-- UPGRADE scripts and nothing else. Without this file the functions ship in
-- the library, are absent from the database, and SELECT ckp.build_id() fails
-- on exactly the bench the identifier exists to make checkable. pgRDF made
-- this error in #93 and corrected it in #95.
--
-- Why the identifier matters: version, control file and install SQL all agree
-- the moment the CONTROL file is replaced. The library is loaded separately,
-- and by the postmaster. So ckp.version() can report a version the loaded .so
-- is not, and every other plane agrees with it. build_id() is compiled in, so
-- it cannot.
--
-- Disclosure: readable by any connected role, so it carries build IDENTITY and
-- never build ENVIRONMENT — tag, commits-since, short commit, dirty marker. No
-- paths, hosts or users. Enforced by build_id_carries_no_paths, not by review.

-- SCHEMA-QUALIFIED, matching what pgrx emits into the generated install
-- (pgck--0.4.27.sql). If the two spellings drift, a database reached by
-- CREATE EXTENSION and one reached by ALTER EXTENSION ... UPDATE end up with
-- the same extversion and DIFFERENT catalogs — the failure this script exists
-- to prevent, reintroduced one schema over.
--
-- ckp, not public: the extension is named pgck but its SCHEMA is ckp, and all
-- of its other functions are already there. pgRDF's extension and schema names
-- coincide, which is the only reason pgrdf.version() reads as it does;
-- ckp.version() is the pgCK equivalent — no schema named pgck exists. In
-- public, `version` is unreachable besides: pg_catalog is searched first, so a
-- bare SELECT version() answers with PostgreSQL's own banner (measured).
CREATE SCHEMA IF NOT EXISTS ckp;

-- CREATE OR REPLACE, deliberately. pgck.localhost reached 0.4.26 during the
-- shared-builder adoption (2026-08-07) with the pair ALREADY present as
-- extension members, migrated in place; a plain CREATE fails there with
-- "already exists". OR REPLACE covers both that bench and a flatten-fresh
-- 0.4.26 (which has neither function). Both bodies are the same compiled
-- wrappers, so replacement is a no-op where they exist. Safe under the
-- CVE-2022-2625 rule: OR REPLACE in an extension script is refused only for
-- pre-existing objects that are NOT members — on the bench they are members.
CREATE OR REPLACE FUNCTION ckp."build_id"() RETURNS TEXT /* &str */
STRICT
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'build_id_wrapper';

-- pgck_version() is NOT touched and stays in public. It returns the prefixed
-- 'pgck <semver>' and oci-germination already reads it there. Both read
-- CARGO_PKG_VERSION, so they cannot disagree — asserted by
-- version_agrees_with_pgck_version.
CREATE OR REPLACE FUNCTION ckp."version"() RETURNS TEXT /* &str */
STRICT
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'version_wrapper';
