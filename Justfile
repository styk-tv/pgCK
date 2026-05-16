# pgCK build — mirrors pgRDF's pgrx toolchain.
set shell := ["bash", "-uc"]

pg := "pg17"

# Compile the extension.
build:
    cargo pgrx package --features {{pg}}

# Install into a pgrx-managed PG (pgRDF must be installed in the same PG).
install:
    cargo pgrx install --features {{pg}} --release

# Spin a pgrx test instance and load both extensions.
run:
    cargo pgrx run {{pg}} --features {{pg}} <<< "CREATE EXTENSION IF NOT EXISTS pgrdf; CREATE EXTENSION IF NOT EXISTS pgck;"

# Unit + pg_test.
test:
    cargo pgrx test --features {{pg}}

# Build the single-pod image (Postgres + pgrdf + age + pgck + embedded NATS).
image:
    docker build -f docker/Dockerfile -t pgck-rc3 .

fmt:
    cargo fmt

lint:
    cargo clippy --features {{pg}} -- -D warnings
