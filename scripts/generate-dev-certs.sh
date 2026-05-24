#!/usr/bin/env bash
set -euo pipefail

out_dir="compose/dev-certs"
hosts_csv="${PGCK_WSS_CERT_HOSTS:-localhost}"
ips_csv="${PGCK_WSS_CERT_IPS:-127.0.0.1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --hosts)
      hosts_csv="$2"
      shift 2
      ;;
    --ips)
      ips_csv="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$out_dir"

ca_key="$out_dir/ca-key.pem"
ca_cert="$out_dir/ca.pem"
server_key="$out_dir/server-key.pem"
server_csr="$out_dir/server.csr"
server_cert="$out_dir/server.pem"
serial_file="$out_dir/ca.srl"
cfg_file="$out_dir/server-openssl.cnf"

if [[ ! -f "$ca_key" || ! -f "$ca_cert" ]]; then
  openssl genrsa -out "$ca_key" 2048 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "$ca_key" \
    -sha256 \
    -days 3650 \
    -out "$ca_cert" \
    -subj "/CN=pgck-local-dev-ca"
fi

{
  echo "[req]"
  echo "default_bits = 2048"
  echo "prompt = no"
  echo "default_md = sha256"
  echo "distinguished_name = dn"
  echo "req_extensions = v3_req"
  echo
  echo "[dn]"
  echo "CN = pgck-local"
  echo
  echo "[v3_req]"
  echo "subjectAltName = @alt_names"
  echo "extendedKeyUsage = serverAuth"
  echo "keyUsage = digitalSignature, keyEncipherment"
  echo
  echo "[alt_names]"
} >"$cfg_file"

dns_i=1
IFS=',' read -r -a hosts <<<"$hosts_csv"
for host in "${hosts[@]}"; do
  host="$(echo "$host" | xargs)"
  [[ -n "$host" ]] || continue
  echo "DNS.${dns_i} = ${host}" >>"$cfg_file"
  dns_i=$((dns_i + 1))
done

ip_i=1
IFS=',' read -r -a ips <<<"$ips_csv"
for ip in "${ips[@]}"; do
  ip="$(echo "$ip" | xargs)"
  [[ -n "$ip" ]] || continue
  echo "IP.${ip_i} = ${ip}" >>"$cfg_file"
  ip_i=$((ip_i + 1))
done

openssl genrsa -out "$server_key" 2048 >/dev/null 2>&1
openssl req -new -key "$server_key" -out "$server_csr" -config "$cfg_file"
openssl x509 -req \
  -in "$server_csr" \
  -CA "$ca_cert" \
  -CAkey "$ca_key" \
  -CAcreateserial \
  -out "$server_cert" \
  -days 825 \
  -sha256 \
  -extensions v3_req \
  -extfile "$cfg_file"

rm -f "$server_csr" "$cfg_file" "$serial_file"

echo "generated:"
echo "  $ca_cert"
echo "  $server_cert"
echo "  $server_key"
