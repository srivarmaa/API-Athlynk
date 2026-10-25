# Portability drill (DEVELOPMENT.md §8, plan slice-1-auth §9)

Moving Athlynk to another Postgres host should cost `pg_dump` + `pg_restore` + changing
environment variables. This drill proves it. Run it at Slice 1 and again in the first slice
that adds object storage, production mail, or scheduled jobs.

**Shape of the move:** the *schema* comes from Flyway (the migrations in git are its source
of truth), the *data* comes from a data-only dump. Both dump and restore run as
`athlynk_backup` (approved 2026-10-17, see `docs/slice-tracker.md`), never as the owner,
the app role, or a superuser.

## Why a dedicated backup role

Every tenant table has `FORCE ROW LEVEL SECURITY` and `athlynk_owner` is `NOBYPASSRLS`. So:

| Attempt | Result |
|---|---|
| `pg_dump -U athlynk_owner` | **Refuses**: `query would be affected by row-level security policy for table "audit_logs"` |
| `pg_dump -U athlynk_owner --enable-row-security` | **Silently wrong**: zero rows from every tenant table, but *every* row of the four tables with the owner-only `preauth_definer_read` policy (V7) |
| `pg_restore -U athlynk_owner` | COPY into a forced-RLS table fails |
| `pg_dump -U athlynk_backup` | Complete. `BYPASSRLS` + `pg_read_all_data` |

Since V12 the owner also has a SELECT-only `platform_definer_read` policy on `organizations` (for `platform_list_orgs()`), so an owner-run `pg_dump --enable-row-security` additionally dumps **every** `organizations` row while still dumping zero rows of the other tenant tables: one more reason it looks plausible and is wrong.

`athlynk_backup` is `LOGIN BYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION`, owns
nothing, and between restores holds **only** `pg_read_all_data`. Write access
(`pg_write_all_data`) is granted by the host admin for the restore and revoked straight after.
`RlsStartupGuard` refuses to boot the API as a BYPASSRLS role, so this role cannot be
mistaken for the API's.

## Variables

The only things that change between hosts:

| Used by | Variables |
|---|---|
| API | `ATHLYNK_DB_URL`, `ATHLYNK_DB_APP_USER`/`_PASSWORD`, `ATHLYNK_DB_MIGRATION_USER`/`_PASSWORD`, `ATHLYNK_IDENTIFIER_PEPPER`, `ATHLYNK_WEB_ORIGIN`, `SMTP_*` |
| `bootstrap-roles.sql` | `ATHLYNK_DB_MIGRATION_PASSWORD`, `ATHLYNK_DB_APP_PASSWORD`, `ATHLYNK_DB_BACKUP_PASSWORD` |
| dump / restore | `PGPASSWORD` for `athlynk_backup` on each host |

Passwords may differ between hosts; role **names** must not (they are baked into policies
and grants by the `${appRole}` placeholder and `TO CURRENT_USER`).

## Steps

Commands below are what was run on 2026-10-17 with Docker. On real hosts drop the
`docker exec` wrapper and point `-h` at the host. Use client tools of the **same major
version** as the server (18).

### 0. Host A has an `athlynk_backup` role

New volumes get it from `bootstrap-roles.sql` on first init. A volume created before the
role existed: re-run the bootstrap by hand (idempotent; also re-asserts the other roles):

```sh
docker exec -e ATHLYNK_DB_BACKUP_PASSWORD=athlynk_backup_dev athlynk_v2-postgres-1 \
  psql -v ON_ERROR_STOP=1 -U postgres -d athlynk -f /docker-entrypoint-initdb.d/10-bootstrap-roles.sql
```

(Git Bash on Windows: `export MSYS_NO_PATHCONV=1` first, or the container path is mangled.)

### 1. Dump host A — data only, as `athlynk_backup`

```sh
PGPASSWORD=... pg_dump -h HOST_A -U athlynk_backup -d athlynk \
  --data-only --format=custom --file=athlynk-data.dump
```

`--data-only` is required, not a preference: only a data-only dump records foreign-key
ordering between tables' data. A full dump restored with `--data-only` loads tables in OID
order and fails (`audit_logs violates foreign key constraint audit_logs_org_id_fkey`).

Expected warnings — harmless, see Traps:
`there are circular foreign-key constraints among these tables: cities, staff, branches` (and
`branches, staff`), and `… on this table: staff` (and `sessions`, `platform_sessions`).

The dump includes `flyway_schema_history`; it is used in step 4 to check versions and is
excluded from the restore.

**The dump holds password hashes, token hashes and personal data. Treat it as a secret;
delete it when the drill is over.**

### 2. Fresh Postgres 18 host B

```sh
docker network create athlynk-drill
docker run -d --name athlynk-drill-b --network athlynk-drill -p 127.0.0.1:55432:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=hostb_admin -e POSTGRES_DB=athlynk \
  postgres:18.6-trixie
```

### 3. Roles first, then schema by Flyway

```sh
# roles — as B's admin, BEFORE anything else (pg_dump does not carry roles)
ATHLYNK_DB_MIGRATION_PASSWORD=owner_b_pw ATHLYNK_DB_APP_PASSWORD=app_b_pw \
ATHLYNK_DB_BACKUP_PASSWORD=backup_b_pw \
  psql -v ON_ERROR_STOP=1 -h HOST_B -U postgres -d athlynk -f infra/db/bootstrap-roles.sql

# schema — as athlynk_owner, same migrations, same placeholder as the API
docker run --rm --network athlynk-drill \
  -v "$PWD/apps/api/src/main/resources/db/migration:/flyway/sql:ro" flyway/flyway:11.14.1 \
  -url=jdbc:postgresql://athlynk-drill-b:5432/athlynk -user=athlynk_owner -password=owner_b_pw \
  -placeholders.appRole=athlynk_app -locations=filesystem:/flyway/sql migrate
```

Flyway CLI 11.14.1 matches the version Spring Boot 4.0.8 manages. Starting the API against
B instead also works (it migrates on boot), but then it is running while data is loaded —
the CLI keeps the steps separate. The CLI's checksums equal the API's, so the API validates
B's history without complaint later.

Building the schema from migrations, not from the dump, means the owner of every table and
of the four `SECURITY DEFINER` functions is `athlynk_owner` *by construction*, the
`preauth_definer_read` policies name `athlynk_owner`, and grants name B's `athlynk_app`.
No `--no-owner` gymnastics.

### 4. Check versions match

```sh
pg_restore --data-only --table=flyway_schema_history -f - athlynk-data.dump   # dump's history
psql -h HOST_B -U postgres -d athlynk -c \
  "select version, description, checksum from flyway_schema_history order by installed_rank"
```

Version list and checksums must be identical. If the dump is from a newer version, migrate
B to that version first; if older, restore into an older checkout's migrations. Never
restore data across a schema version gap.

### 5. Restore — data only, as `athlynk_backup`, no superuser

```sh
pg_restore -l athlynk-data.dump | grep -v 'TABLE DATA public flyway_schema_history ' > restore.list

psql -h HOST_B -U postgres -d athlynk -c "GRANT pg_write_all_data TO athlynk_backup"
PGPASSWORD=backup_b_pw pg_restore -h HOST_B -U athlynk_backup -d athlynk \
  --data-only --use-list=restore.list --single-transaction --exit-on-error athlynk-data.dump
psql -h HOST_B -U postgres -d athlynk -c "REVOKE pg_write_all_data FROM athlynk_backup"
```

- `--single-transaction`: any failure leaves B empty, never half-loaded.
- No `--disable-triggers` (it needs superuser). Not needed: no Athlynk trigger fires on
  INSERT — `audit_logs` rejects UPDATE/DELETE/TRUNCATE only, `organizations` guards UPDATE only.
- `flyway_schema_history` is excluded because Flyway already wrote B's own.
- **Load order within an FK cycle does not matter** (since V9, 2026-10-19). `pg_dump` breaks
  data-only cycles by its own heuristic, ignoring deferrability, so every edge of the
  `staff`/`branches`/`cities` cycles is `DEFERRABLE INITIALLY DEFERRED` and checked once at the
  restore's COMMIT. Enforced, not checked by hand: `SchemaGuardIT.everyForeignKeyCycleEdgeIsDeferred`
  (catalog) and `DataOnlyRestoreIT` (this exact step, in pg_dump's order and with the cycle
  loaded backwards). Sanity note only: if a restore ever fails with `violates foreign key
  constraint` on a table that appears in the `circular foreign-key constraints` warning, a
  migration has added a cycle edge that is not deferred, and those tests should have failed.
- Always run the REVOKE, even after a failure. Re-running `bootstrap-roles.sql` also revokes it.

### 6. Start the API on B with only env vars changed

```sh
ATHLYNK_DB_URL=jdbc:postgresql://HOST_B:5432/athlynk \
ATHLYNK_DB_APP_USER=athlynk_app ATHLYNK_DB_APP_PASSWORD=app_b_pw \
ATHLYNK_DB_MIGRATION_USER=athlynk_owner ATHLYNK_DB_MIGRATION_PASSWORD=owner_b_pw \
ATHLYNK_IDENTIFIER_PEPPER=<same as A> ATHLYNK_WEB_ORIGIN=... SMTP_HOST=... \
  java -jar apps/api/target/athlynk-api-0.1.0-SNAPSHOT.jar
```

Then `docker rm -f athlynk-drill-b && docker network rm athlynk-drill`, and delete the dump.

## Pass criteria

Database half (verifiable with psql):

1. Dump as `athlynk_backup` exits 0 and contains every row: per-table `count(*)` **and**
   `md5(string_agg(t::text ORDER BY t::text))` equal on A and B, for every table except
   `flyway_schema_history`.
2. Restore succeeds as `athlynk_backup` (`NOSUPERUSER`), and afterwards `athlynk_backup` is a
   member of `pg_read_all_data` only.
3. `pg_dump --schema-only` of A and of B are **identical** (policies, FORCE RLS, grants,
   function owners, `SECURITY DEFINER`).
4. As `athlynk_app` on B, with no `app.current_org`: every tenant table returns 0 rows.
   With `set_config('app.current_org', <org>, true)` in a transaction: only that org's rows,
   0 foreign rows; after commit, 0 again.
5. `RlsStartupGuard` conditions, as `athlynk_app`: not superuser, not BYPASSRLS, owns no
   table, every tenant table ENABLE + FORCE. Plus `pg_has_role('athlynk_app', X, 'MEMBER')`
   is false for `athlynk_owner`, `athlynk_backup`, `pg_read_all_data`, `pg_write_all_data`.
6. `auth_find_credentials(<a known email>, null, null)` as `athlynk_app` returns the
   credential (definer ownership + `preauth_definer_read` intact on B).

Application half (plan §9): same credentials log in on B; an existing refresh cookie still
works (token hashes are plain SHA-256, so the DB alone suffices); `RlsStartupGuard` logs
"passed"; `CrossTenantRlsIT` green against B.

## Traps

- **Dumping or restoring as the owner.** Refuses, or with `--enable-row-security` produces a
  plausible-looking dump with no tenant data. Always `athlynk_backup`.
- **Full dump + `--data-only` restore.** FK-order failure, see step 1.
- **Cross-table FK cycles.** Self-references (`staff`, `sessions`) load fine: a single COPY
  checks its FKs at the end of the statement. Cross-table cycles (today `staff ⇄ branches` and
  `cities → staff → branches → cities`) load only because **every** edge on them is
  `DEFERRABLE INITIALLY DEFERRED` (V8 + V9). Deferring one edge per cycle is not enough —
  pg_dump may cut the cycle at an immediate edge. A migration that adds a cycle edge must defer
  it (`SchemaGuardIT` fails otherwise) and re-run this drill in that slice.
- **Pointing the API at the admin, owner or backup role.** RLS is bypassed or weakened;
  `RlsStartupGuard` must refuse — that refusal is a pass, not a problem.
- **A managed host that cannot grant `BYPASSRLS` or `pg_read_all_data`/`pg_write_all_data`.**
  Bootstrap fails there. Check this before choosing a production host.
- **Restoring across schema versions.** Step 4 exists to stop it.
- **Lost pepper.** `ATHLYNK_IDENTIFIER_PEPPER` keys only the `login_attempts` HMACs; a
  different pepper on B only resets lockout counters. Carry it anyway.
- **Timezone.** PG 18 rejects the legacy `Asia/Calcutta` alias at connect; the JVM is forced
  to UTC (slice tracker). Hosts must not override this.
- **`citext` / `uuidv7()`.** Need PG 18 and CREATE on the database for the owner (bootstrap
  grants it). An older B fails in V1.
- **Leftover write grant.** If a restore dies before the REVOKE, `athlynk_backup` keeps write
  access. Re-run `bootstrap-roles.sql` or REVOKE by hand.
