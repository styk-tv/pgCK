-- pgck 0.4.25 -> 0.4.26
--
-- BUILD IDENTITY. Adds pgck.build_id(), the one identifier that survives a
-- wrong drop.
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

CREATE  FUNCTION "build_id"() RETURNS TEXT /* &str */
STRICT
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'build_id_wrapper';
