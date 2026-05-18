set shell := ["bash", "-uc"]
pgrdf_ver := "0.5.0"
pg := "17"
arch := "arm64"
build := env_var_or_default("PGCK_BUILD_RUNTIME", "podman")
run   := env_var_or_default("PGCK_RUN_RUNTIME", "podman")
compose_project := env_var_or_default("PGCK_COMPOSE_PROJECT", "pgck")

pgrdf-fetch:
    mkdir -p compose/extensions/pgrdf
    cd compose/extensions/pgrdf && \
      gh release download "v{{pgrdf_ver}}" --repo styk-tv/pgRDF \
        --pattern "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" \
        --pattern "SHA256SUMS" --clobber && \
      grep "pg{{pg}}-glibc-{{arch}}" SHA256SUMS | sha256sum -c - && \
      tar xzf "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" --strip-components=1

build-ext:
    DOCKER_BUILDKIT=1 {{build}} build --target export \
      -t pgck-builder:pg{{pg}} --build-arg PG_MAJOR={{pg}} \
      -f compose/builder.Containerfile .
    rm -rf compose/extensions/pgck/lib compose/extensions/pgck/share
    mkdir -p compose/extensions/pgck
    {{build}} run --rm -v "$PWD/compose/extensions/pgck:/export" pgck-builder:pg{{pg}}
    # A warm BuildKit /work/target cache can retain stale per-version
    # pgck--<old>.sql files (cargo pgrx package's *.sql cp glob copies
    # them all). Keep only the current default_version's SQL so the
    # compose per-file bind mount + CREATE EXTENSION resolve cleanly.
    cd compose/extensions/pgck/share/extension && \
      ver=$(grep -oE "default_version = '[^']+'" pgck.control | cut -d"'" -f2) && \
      find . -name 'pgck--*.sql' ! -name "pgck--$ver.sql" -delete

# Recreate the pod (down+up) — picks up compose.yml mount changes.
compose-recreate:
    # `podman compose restart` does NOT re-read volume/mount changes;
    # use this after build-ext when a version bump renamed pgck--<ver>.sql.
    cd compose && {{run}} compose -p {{compose_project}} down
    cd compose && {{run}} compose -p {{compose_project}} up -d

compose-up:
    cd compose && {{run}} compose -p {{compose_project}} up -d
compose-down:
    cd compose && {{run}} compose -p {{compose_project}} down
psql:
    cd compose && {{run}} compose -p {{compose_project}} exec postgres psql -U pgck -d pgck

smoke-s4: pgrdf-fetch build-ext compose-recreate
    until (cd compose && {{run}} compose -p {{compose_project}} exec postgres pg_isready -U pgck); do sleep 2; done
    cd compose && {{run}} compose -p {{compose_project}} exec postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 \
      -c "DROP EXTENSION IF EXISTS pgck CASCADE; CREATE EXTENSION pgck CASCADE;"
    cd compose && {{run}} compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_validate.sql
    cd compose && {{run}} compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_seal_ok.sql
    cd compose && {{run}} compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_seal_reject.sql
    cd compose && {{run}} compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_verify.sql

smoke-s5: pgrdf-fetch build-ext compose-recreate
    until (cd compose && {{run}} compose -p {{compose_project}} exec postgres pg_isready -U pgck); do sleep 2; done
    cd compose && {{run}} compose -p {{compose_project}} exec postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 \
      -c "CREATE EXTENSION IF NOT EXISTS pgrdf CASCADE; DROP EXTENSION IF EXISTS pgck CASCADE; CREATE EXTENSION pgck CASCADE;" \
      -c "CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');" \
      -tc "SELECT pgck_version();"
