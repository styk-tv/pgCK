set shell := ["bash", "-uc"]
pgrdf_ver := "0.6.17"
pg := "17"
arch := "arm64"
docker_context := env_var_or_default("DOCKER_CONTEXT", "colima")
compose_project := env_var_or_default("PGCK_COMPOSE_PROJECT", "pgck")
compose_wss_project := env_var_or_default("PGCK_WSS_COMPOSE_PROJECT", "pgck-nats-wss")

colima-up:
    if ! colima status >/dev/null 2>&1; then colima start; fi
    if [ "$$(docker context show)" != "{{docker_context}}" ]; then docker context use "{{docker_context}}" >/dev/null; fi

pgrdf-fetch:
    mkdir -p compose/extensions/pgrdf
    cd compose/extensions/pgrdf && \
      gh release download "v{{pgrdf_ver}}" --repo styk-tv/pgRDF \
        --pattern "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" \
        --pattern "SHA256SUMS" --clobber && \
      grep "pg{{pg}}-glibc-{{arch}}" SHA256SUMS | sha256sum -c - && \
      tar xzf "pgrdf-{{pgrdf_ver}}-pg{{pg}}-glibc-{{arch}}.tar.gz" --strip-components=1

build-ext: colima-up
    DOCKER_CONTEXT={{docker_context}} DOCKER_BUILDKIT=1 docker build --target export \
      -t pgck-builder:pg{{pg}} --build-arg PG_MAJOR={{pg}} \
      -f compose/builder.Containerfile .
    rm -rf compose/extensions/pgck/lib compose/extensions/pgck/share
    mkdir -p compose/extensions/pgck/lib compose/extensions/pgck/share/extension
    DOCKER_CONTEXT={{docker_context}} docker run --rm --entrypoint sh \
      -v "$PWD/compose/extensions/pgck:/export" pgck-builder:pg{{pg}} \
      -lc 'cp -r /out/* /export/ && ls -laR /export'
    # A warm BuildKit /work/target cache can retain stale per-version
    # pgck--<old>.sql files (cargo pgrx package's *.sql cp glob copies
    # them all). Keep only the current default_version's SQL so the
    # compose per-file bind mount + CREATE EXTENSION resolve cleanly.
    cd compose/extensions/pgck/share/extension && \
      ver=$(grep -oE "default_version = '[^']+'" pgck.control | cut -d"'" -f2) && \
      find . -name 'pgck--*.sql' ! -name "pgck--$ver.sql" -delete

# Recreate the pod (down+up) — picks up compose.yml mount changes.
compose-recreate: colima-up
    # `docker compose restart` does NOT re-read volume/mount changes;
    # use this after build-ext when a version bump renamed pgck--<ver>.sql.
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} down
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} up -d

compose-up: colima-up
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} up -d
compose-up-fg: colima-up
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} up

compose-recreate-fg: colima-up
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} down
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} up
compose-down:
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} down
psql: colima-up
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec postgres psql -U pgck -d pgck

smoke-s4: pgrdf-fetch build-ext compose-recreate
    until (cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec postgres pg_isready -U pgck); do sleep 2; done
    # Reset the FULL semantic substrate each run, not just pgck: pgrdf's hexastore
    # survives DROP EXTENSION pgck and has no (s,p,o,g) quad-uniqueness, so re-running
    # the warm gate would re-materialize the same direct triples and double-count
    # (e.g. s32 concept.match count=6). Dropping pgrdf too makes the gate idempotent.
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 \
      -c "DROP EXTENSION IF EXISTS pgck CASCADE; DROP EXTENSION IF EXISTS pgrdf CASCADE; CREATE EXTENSION pgck CASCADE; CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');"
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_validate.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_seal_ok.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_seal_reject.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s4_verify.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s9_seal_participant.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s11_ci_a4_role_floor.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s12_ci_a3_ring1_definer.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s13_ci_a2_dispatch_only.sql
    DOCKER_CONTEXT={{docker_context}} PGCK_COMPOSE_PROJECT={{compose_project}} bash sql/test/s14_ci_a1_sidecar.sh
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s15_alpha_web2_verbs.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s16_ci_b5_plane_epoch.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s17_ci_b4_registry.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s18_ci_b3_validate_report.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s19_ci_b2_plane_route.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s20_ci_b1_routing_authority.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s21_ci_c4_plans_table.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s22_ci_c3_plan_compiler.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s23_ci_c2_epoch_invalidation.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s24_ci_d6_governance_ontology.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s25_ci_d5_propose_change.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s26_ci_d4_vote_quorum.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s27_ci_d3_apply_cascade.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s28_ci_d2_fenced_rawttl.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s29_ci_e5_typed_query.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s30_ci_e4_reach.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s31_ci_e3_transition_snapshot.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s32_ci_e2_concept_match.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s33_ci_e1_hot_loop.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s35_instance_retire.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s36_instance_update_patch.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s37_tier1_consumer_fixes.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s38_generic_typed_create.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s39_graph_apply_type_evolution.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s40_reach_edge_materialization.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s41_governed_query_affordance.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s42_query_shape.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s43_declared_predicates.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s44_transition_map.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s45_update_patch.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s46_validation_report.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s47_governed_concept_match.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s48_csvc_domain_shape.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s49_adopt_kernel_ttl.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s50_bare_id_roundtrip.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s51_provenance_id_form.sql
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec -T postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 < ../sql/test/s52_epsilon_materialize.sql

smoke-s3: smoke-s4
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 \
      -c "DROP EXTENSION IF EXISTS pgck CASCADE; CREATE EXTENSION pgck CASCADE;"
    sleep 3
    printf 'PING\r\n' | nc -w2 "${NATS_HOST:-127.0.0.1}" "${NATS_PORT:-4222}" | grep -q server_name && echo "INFO banner OK"
    bash sql/test/s3_nats_roundtrip.sh

smoke-s5: pgrdf-fetch build-ext compose-recreate
    until (cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec postgres pg_isready -U pgck); do sleep 2; done
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_project}} exec postgres psql -U pgck -d pgck -v ON_ERROR_STOP=1 \
      -c "CREATE EXTENSION IF NOT EXISTS pgrdf CASCADE; DROP EXTENSION IF EXISTS pgck CASCADE; CREATE EXTENSION pgck CASCADE;" \
      -c "CALL ckp.boot(); CALL ckp.load_kernel('/examples/example.kernel.ttl','demo');" \
      -tc "SELECT pgck_version();"

nats-wss-certs:
    ./scripts/generate-dev-certs.sh

nats-wss-up: nats-wss-certs colima-up
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_wss_project}} -f compose.nats-wss.yml up -d

nats-wss-up-fg: nats-wss-certs colima-up
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_wss_project}} -f compose.nats-wss.yml up

nats-wss-down:
    cd compose && DOCKER_CONTEXT={{docker_context}} docker compose -p {{compose_wss_project}} -f compose.nats-wss.yml down

smoke-nats-wss: nats-wss-up
    until curl --silent --fail "http://127.0.0.1:${NATS_MONITOR_PORT:-8222}/varz" >/dev/null; do sleep 2; done
    user="${NATS_USER:-dev}"; pass="${NATS_PASSWORD:-devpass-change-me}"; \
      nats rtt -s "nats://127.0.0.1:${NATS_TCP_PORT:-4223}" --user "$user" --password "$pass" 1
    curl --silent --show-error --include --http1.1 \
      --cacert compose/dev-certs/ca.pem \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      "https://127.0.0.1:${NATS_WSS_PORT:-8443}/" | grep -q '101 Switching Protocols'

# s34 — install-from-zero gate: a virgin cluster + CREATE EXTENSION pgck CASCADE must yield
# a working governed dispatch as a REAL ck_participant login, zero manual steps, floor intact
# (answers oci-germination's install-cascade NOTIFY). Separate from smoke-s4 by design:
# s4..s33 run against the warm compose volume; s34 proves the from-zero consumer journey.
smoke-s34:
    DOCKER_CONTEXT={{docker_context}} bash scripts/smoke-s34-fresh-install.sh

browser-demo-test:
    pytest -q tests/test_web.py

browser-demo-run:
    uvicorn web.app:app --host "${PGCK_BROWSER_HOST:-0.0.0.0}" --port "${PGCK_BROWSER_PORT:-8000}"

webui:
    uvicorn web.app:app --host "${PGCK_BROWSER_HOST:-0.0.0.0}" --port "${PGCK_BROWSER_PORT:-8000}"
