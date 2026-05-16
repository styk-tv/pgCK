# CKP rc3 single-pod image: Postgres + pgRDF + AGE + conceptkernel + embedded NATS.
# Per-tenant differences are mounts only (/secrets, /ontology/kernel.ttl) — image is identical across projects.
FROM postgres:17

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential postgresql-server-dev-17 git curl ca-certificates \
      libreadline-dev zlib1g-dev flex bison pkg-config \
 && rm -rf /var/lib/apt/lists/*

# --- pgRDF (Rust/pgrx) — RDF graphs, SPARQL, SHACL, OWL2RL ---
RUN git clone --depth 1 https://github.com/styk-tv/pgRDF.git /tmp/pgrdf \
 && cd /tmp/pgrdf && make && make install && rm -rf /tmp/pgrdf

# --- Apache AGE — property-graph instance loop (optional per kernel) ---
RUN git clone --depth 1 https://github.com/apache/age.git /tmp/age \
 && cd /tmp/age && make install && rm -rf /tmp/age

# --- conceptkernel extension (this scaffold): core ontology + governed write path ---
COPY conceptkernel/conceptkernel.control      /usr/share/postgresql/17/extension/
COPY conceptkernel/conceptkernel--0.1.0.sql   /usr/share/postgresql/17/extension/
COPY conceptkernel/core.ttl                   /usr/share/conceptkernel/core.ttl

# --- embedded NATS broker ---
RUN curl -sL https://github.com/nats-io/nats-server/releases/latest/download/nats-server-linux-amd64.tar.gz \
      | tar xz -C /usr/local/bin --strip-components=1 nats-server-linux-amd64/nats-server || \
    (curl -sL https://github.com/nats-io/nats-server/releases/latest/download/nats-server-linux-amd64.zip -o /tmp/n.zip \
      && (cd /usr/local/bin && unzip -j /tmp/n.zip '*/nats-server'))

# postgres_fdw ships in contrib (already present in the base image).

COPY docker-entrypoint-ckp.sh /usr/local/bin/docker-entrypoint-ckp.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-ckp.sh

ENV CKP_PROJECT=demo \
    CKP_CORE_TTL=/usr/share/conceptkernel/core.ttl \
    CKP_KERNEL_TTL=/ontology/kernel.ttl
EXPOSE 4222 5432
CMD ["/usr/local/bin/docker-entrypoint-ckp.sh"]
