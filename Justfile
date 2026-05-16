set shell := ["bash", "-uc"]
pgrdf_ver := "0.5.0"
pg := "17"
arch := "arm64"
build := env_var_or_default("PGCK_BUILD_RUNTIME", "podman")
run   := env_var_or_default("PGCK_RUN_RUNTIME", "podman")

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

compose-up:
    cd compose && {{run}} compose up -d
compose-down:
    cd compose && {{run}} compose down
psql:
    cd compose && {{run}} compose exec postgres psql -U pgck -d pgck
