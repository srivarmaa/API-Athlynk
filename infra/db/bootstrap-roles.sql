-- =============================================================================
-- Athlynk cluster roles. Run ONCE per Postgres host, BEFORE Flyway and before
-- any pg_restore. pg_dump does not carry roles, so this file is half of the
-- portability drill (DEVELOPMENT.md §8, plan slice-1-auth §9).
--
-- Run as the host's admin role, connected to the Athlynk database:
--
--   ATHLYNK_DB_MIGRATION_PASSWORD=... ATHLYNK_DB_APP_PASSWORD=... \
--   ATHLYNK_DB_BACKUP_PASSWORD=... \
--     psql -v ON_ERROR_STOP=1 -U postgres -d athlynk -f infra/db/bootstrap-roles.sql
--
-- docker-compose mounts it into /docker-entrypoint-initdb.d, where the image's
-- entrypoint runs it with psql against $POSTGRES_DB and the container env.
--
-- Requires psql >= 15 (\getenv). Idempotent: safe to re-run; re-running
-- resets all three passwords to the current environment values.
--
-- Roles:
--   athlynk_owner  owns every table and function; Flyway connects as this.
--                  NOBYPASSRLS on purpose: tables use FORCE ROW LEVEL SECURITY,
--                  so even the owner is tenant-scoped (see V7 for the one
--                  narrow exception used by the pre-auth lookup functions).
--   athlynk_app    the running API. Owns nothing, NOSUPERUSER, NOBYPASSRLS.
--                  RlsStartupGuard refuses to boot if either is untrue.
--   athlynk_backup pg_dump / pg_restore ONLY (approved 2026-10-17, see
--                  docs/slice-tracker.md). BYPASSRLS, because FORCE RLS makes
--                  an owner-run pg_dump refuse or silently dump zero tenant
--                  rows. Owns nothing. Standing privilege is read-only, via
--                  the predefined role pg_read_all_data (also covers tables
--                  added by future migrations; no per-table grant to forget).
--                  Write access for a restore is granted temporarily on the
--                  target host and revoked afterwards - see
--                  infra/db/PORTABILITY-DRILL.md. Never point the API or
--                  Flyway at this role; RlsStartupGuard refuses BYPASSRLS.
-- =============================================================================

\set ON_ERROR_STOP on

\getenv owner_password ATHLYNK_DB_MIGRATION_PASSWORD
\getenv app_password   ATHLYNK_DB_APP_PASSWORD
\getenv backup_password ATHLYNK_DB_BACKUP_PASSWORD

-- A missing variable must fail the run (non-zero exit), not silently skip.
-- \quit always exits 0, so raise an error under ON_ERROR_STOP instead.
\if :{?owner_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'ATHLYNK_DB_MIGRATION_PASSWORD is not set'; END $$;
\endif
\if :{?app_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'ATHLYNK_DB_APP_PASSWORD is not set'; END $$;
\endif
\if :{?backup_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'ATHLYNK_DB_BACKUP_PASSWORD is not set'; END $$;
\endif

-- Create if missing (CREATE ROLE has no IF NOT EXISTS).
SELECT 'CREATE ROLE athlynk_owner'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'athlynk_owner') \gexec
SELECT 'CREATE ROLE athlynk_app'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'athlynk_app') \gexec
SELECT 'CREATE ROLE athlynk_backup'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'athlynk_backup') \gexec

-- Attributes are (re)asserted every run, so a drifted role is corrected.
ALTER ROLE athlynk_owner WITH LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'owner_password';
ALTER ROLE athlynk_app   WITH LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'app_password';
-- INHERIT so membership in pg_read_all_data applies without SET ROLE.
-- Granting BYPASSRLS needs a superuser (or, PG 16+, a CREATEROLE admin that
-- itself has BYPASSRLS). A managed host whose admin cannot do this cannot run
-- the drill as written - check before choosing a host.
ALTER ROLE athlynk_backup WITH LOGIN BYPASSRLS INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'backup_password';

-- Backup role standing state: read everything, write nothing.
-- pg_read_all_data = SELECT on every table/view/sequence + USAGE on every
-- schema, current and future. RLS is skipped by BYPASSRLS, not by this grant.
GRANT pg_read_all_data TO athlynk_backup;
-- A restore grants pg_write_all_data temporarily (PORTABILITY-DRILL.md). If a
-- restore was interrupted before its REVOKE, re-running this file closes it.
-- On a clean host this prints WARNING 'role "athlynk_backup" has not been
-- granted membership in role "pg_write_all_data"' - expected, harmless.
REVOKE pg_write_all_data FROM athlynk_backup;

-- Database-level privileges. CREATE on the database is needed for the
-- owner to install the trusted extension citext (V1). :DBNAME is the
-- database psql is connected to.
GRANT CONNECT, CREATE, TEMPORARY ON DATABASE :"DBNAME" TO athlynk_owner;
GRANT CONNECT ON DATABASE :"DBNAME" TO athlynk_app;
GRANT CONNECT ON DATABASE :"DBNAME" TO athlynk_backup;

-- Schema privileges. PG 15+ no longer grants CREATE on public to PUBLIC.
GRANT USAGE, CREATE ON SCHEMA public TO athlynk_owner;
GRANT USAGE         ON SCHEMA public TO athlynk_app;
