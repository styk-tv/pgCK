-- pgck 0.4.25 -> 0.4.26
--
-- BUILD IDENTITY. Adds ckp.build_id(), the one identifier that survives a
-- wrong drop, and ckp.version(), the bare semver §7 asks every extension on the
-- shared builder to expose.
--
-- Why it needs an upgrade script at all: build_id() is a SQL SURFACE change.
-- pgrx emits it into the generated INSTALL script, which only runs on
-- CREATE EXTENSION. An existing database reaches a new version through
-- ALTER EXTENSION ... UPDATE, which runs the UPGRADE scripts and nothing else.
-- Without this file the function ships in the library, is absent from the
-- database, and `SELECT pgck.build_id()` fails on exactly the bench the
-- identifier exists to make checkable. pgRDF made this error in #93 and
-- corrected it in #95; this is the correction applied before the mistake.
--
-- Why the identifier matters: version, control file and install SQL all agree
-- the moment the CONTROL file is replaced. The library is loaded separately,
-- and by the postmaster. So pgck.version() can report a version the loaded .so
-- is not, and every other plane agrees with it. build_id() is compiled in, so
-- it cannot.
--
-- Disclosure: readable by any connected role, so it carries build IDENTITY and
-- never build ENVIRONMENT — tag, commits-since, short commit, dirty marker. No
-- paths, hosts or users. Enforced by build_id_carries_no_paths, not by review.

-- SCHEMA-QUALIFIED, and it must stay that way. These statements are copied
-- from what pgrx emits into the generated install script (pgck--0.4.26.sql,
-- `#[pg_schema] pub mod ckp`). If the two spellings drift, a database reached
-- by CREATE EXTENSION and one reached by ALTER EXTENSION ... UPDATE end up with
-- the same extversion and DIFFERENT catalogs — the failure this script exists
-- to prevent, reintroduced one schema over.
--
-- ckp, not public: the extension is named pgck but its SCHEMA is ckp, and all
-- 81 of its other functions are already there. pgRDF's extension and schema
-- names coincide, which is the only reason pgrdf.version() reads as it does;
-- ckp.version() is the pgCK equivalent, not pgck.version() — no schema named
-- pgck exists. Leaving these in public would also make them the only pgCK
-- functions outside ckp, and `version` in particular is unreachable there:
-- pg_catalog is searched first, so a bare SELECT version() answers with
-- PostgreSQL's own banner.
CREATE SCHEMA IF NOT EXISTS ckp;

CREATE  FUNCTION ckp."build_id"() RETURNS TEXT /* &str */
STRICT
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'build_id_wrapper';

-- ckp.version() — bare semver, required by §7 alongside build_id().
--
-- Same trap as build_id() above: this is a SQL SURFACE change, so it reaches an
-- existing database only through this upgrade script. Without it the function
-- ships in the library and is absent from the database, and the §10 query
--   SELECT ckp.version(), ckp.build_id();
-- fails on the bench the pair exists to make checkable.
--
-- pgck_version() is NOT touched and stays in public. It returns the prefixed
-- 'pgck <semver>' and oci-germination already reads it there; moving a live
-- consumer's function to satisfy a spelling is a separate decision, not this
-- script's. Both read CARGO_PKG_VERSION, so they cannot disagree — asserted by
-- version_agrees_with_pgck_version.
CREATE  FUNCTION ckp."version"() RETURNS TEXT /* &str */
STRICT
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'version_wrapper';
