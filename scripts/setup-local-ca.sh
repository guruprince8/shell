#!/usr/bin/env bash
# Create a local private Root CA and a server TLS certificate with SANs,
# then optionally install the CA into Ubuntu trust store, Java cacerts,
# and /etc/hosts so browsers, curl, and JVM apps (e.g. Pega) trust HTTPS
# without "self-signed certificate" errors (the server cert is signed by
# your locally trusted CA, not anonymous self-signed).
set -euo pipefail

CA_DIR="${CA_DIR:-${HOME}/myCA}"
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-825}"
CA_CN="${CA_CN:-MyLocalRootCA}"
KEYSTORE_ALIAS="${KEYSTORE_ALIAS:-my-local-ca}"
KEYSTORE_PASS="${KEYSTORE_PASS:-changeit}"
CA_CERT_INSTALL_NAME="${CA_CERT_INSTALL_NAME:-mylocal-developer-root-ca.crt}"

INSTALL_SYSTEM=0
INSTALL_JAVA=0
INSTALL_HOSTS=0
FORCE_CA=0
NEW_SERVER_KEY=0
DOMAINS=()
IPS=()

usage() {
  cat <<'EOF'
Usage: setup-local-ca.sh [options]

  Creates ~/myCA (or CA_DIR) with rootCA.key, rootCA.crt, server.key,
  server.crt, server.cnf — CA signs the server cert (not a lone self-signed
  server cert), which avoids untrusted-chain errors once the CA is installed.

Options:
  -d, --domain FQDN     DNS name in SAN (repeatable). First -d is also the cert CN. Default if none: oauth2.sapphire.com or \$DOMAIN.
  -i, --ip ADDR         Extra SAN IP (repeatable). 127.0.0.1 and localhost added by default.
  -c, --ca-dir PATH     Output directory (default: ~/myCA)
  --ca-cn NAME          Root CA Common Name (default: MyLocalRootCA)
  --install-system      sudo: copy CA to /usr/local/share/ca-certificates and update-ca-certificates
  --install-java        sudo: import CA into default java cacerts (needs java + keytool)
  --install-hosts       sudo: add "IP domain" to /etc/hosts (needs --ip or uses 127.0.0.1)
  --install-all         all three install steps above
  --force-ca            Regenerate CA even if rootCA.key exists (overwrites)
  --new-server-key      Regenerate server.key (default: reuse if present)
  -h, --help            This help

Environment:
  DOMAIN, CA_DIR, CA_DAYS, SERVER_DAYS, CA_CN, KEYSTORE_ALIAS, KEYSTORE_PASS,
  CA_CERT_INSTALL_NAME, JAVA_HOME (optional; else detected from `java`)

Examples:
  ./setup-local-ca.sh -d oauth2.sapphire.com -i 192.168.1.228
  ./setup-local-ca.sh -d oauth2.sapphire.com -d elastic.sapphire.com -i 192.168.1.228 --install-all
  ./setup-local-ca.sh -d api.local.test -i 10.0.0.5 --install-all
EOF
}

log() { printf '[setup-local-ca] %s\n' "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "missing required command: $1"
    exit 1
  }
}

detect_java_cacerts() {
  if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/lib/security/cacerts" ]]; then
    printf '%s' "${JAVA_HOME}/lib/security/cacerts"
    return
  fi
  require_cmd java
  local home
  home="$(java -XshowSettings:properties -version 2>&1 | sed -n 's/.*java.home = //p' | head -1 | tr -d '\r')"
  if [[ -z "$home" || ! -f "$home/lib/security/cacerts" ]]; then
    log "could not find cacerts under java.home=$home; set JAVA_HOME"
    exit 1
  fi
  printf '%s' "$home/lib/security/cacerts"
}

write_server_cnf() {
  local cnf="$1"
  local cn_primary="${DOMAINS[0]}"
  {
    echo '[req]'
    echo 'default_bits = 2048'
    echo 'prompt = no'
    echo 'default_md = sha256'
    echo 'distinguished_name = dn'
    echo 'req_extensions = req_ext'
    echo ''
    echo '[dn]'
    echo "CN = ${cn_primary}"
    echo ''
    echo '[req_ext]'
    echo 'subjectAltName = @alt_names'
    echo 'extendedKeyUsage = serverAuth'
    echo 'keyUsage = digitalSignature, keyEncipherment'
    echo ''
    echo '[alt_names]'
    local d=1
    local dom
    declare -A seen_dns=()
    for dom in "${DOMAINS[@]}"; do
      [[ -n "${seen_dns[$dom]:-}" ]] && continue
      seen_dns[$dom]=1
      echo "DNS.${d} = ${dom}"
      d=$((d + 1))
    done
    echo "DNS.${d} = localhost"
    local p=1
    echo "IP.${p} = 127.0.0.1"
    p=$((p + 1))
    for ip in "${IPS[@]}"; do
      echo "IP.${p} = ${ip}"
      p=$((p + 1))
    done
  } >"$cnf"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      DOMAINS+=("$2")
      shift 2
      ;;
    -i|--ip)
      IPS+=("$2")
      shift 2
      ;;
    -c|--ca-dir)
      CA_DIR="$2"
      shift 2
      ;;
    --ca-cn)
      CA_CN="$2"
      shift 2
      ;;
    --install-system)
      INSTALL_SYSTEM=1
      shift
      ;;
    --install-java)
      INSTALL_JAVA=1
      shift
      ;;
    --install-hosts)
      INSTALL_HOSTS=1
      shift
      ;;
    --install-all)
      INSTALL_SYSTEM=1
      INSTALL_JAVA=1
      INSTALL_HOSTS=1
      shift
      ;;
    --force-ca)
      FORCE_CA=1
      shift
      ;;
    --new-server-key)
      NEW_SERVER_KEY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  DOMAINS=("${DOMAIN:-oauth2.sapphire.com}")
fi

require_cmd openssl
mkdir -p -- "$CA_DIR"
CA_DIR="$(cd -- "$CA_DIR" && pwd)"
ROOT_KEY="${CA_DIR}/rootCA.key"
ROOT_CRT="${CA_DIR}/rootCA.crt"
SRV_KEY="${CA_DIR}/server.key"
SRV_CSR="${CA_DIR}/server.csr"
SRV_CRT="${CA_DIR}/server.crt"
SRV_CNF="${CA_DIR}/server.cnf"

write_server_cnf "$SRV_CNF"

if [[ -f "$ROOT_KEY" && "$FORCE_CA" -eq 0 ]]; then
  log "reusing existing CA: $ROOT_KEY"
  if [[ ! -f "$ROOT_CRT" ]]; then
    log "missing $ROOT_CRT (regenerate with --force-ca)"
    exit 1
  fi
elif [[ -f "$ROOT_KEY" && "$FORCE_CA" -eq 1 ]]; then
  log "regenerating CA (--force-ca)"
  openssl genrsa -out "$ROOT_KEY" 4096
  openssl req -x509 -new -nodes \
    -key "$ROOT_KEY" \
    -sha256 -days "$CA_DAYS" \
    -out "$ROOT_CRT" \
    -subj "/O=Local Dev/CN=${CA_CN}"
else
  log "generating new Root CA in $CA_DIR"
  openssl genrsa -out "$ROOT_KEY" 4096
  openssl req -x509 -new -nodes \
    -key "$ROOT_KEY" \
    -sha256 -days "$CA_DAYS" \
    -out "$ROOT_CRT" \
    -subj "/O=Local Dev/CN=${CA_CN}"
fi

if [[ ! -f "$SRV_KEY" || "$NEW_SERVER_KEY" -eq 1 ]]; then
  log "generating server key"
  openssl genrsa -out "$SRV_KEY" 2048
else
  log "reusing server key: $SRV_KEY"
fi

log "generating CSR and signing server certificate (${SERVER_DAYS} days)"
openssl req -new -key "$SRV_KEY" -out "$SRV_CSR" -config "$SRV_CNF"
openssl x509 -req \
  -in "$SRV_CSR" \
  -CA "$ROOT_CRT" \
  -CAkey "$ROOT_KEY" \
  -CAcreateserial \
  -out "$SRV_CRT" \
  -days "$SERVER_DAYS" \
  -sha256 \
  -extensions req_ext \
  -extfile "$SRV_CNF"

chmod 600 -- "$ROOT_KEY" "$SRV_KEY" 2>/dev/null || true

log "done. Artifacts:"
log "  CA cert (trust this): $ROOT_CRT"
log "  Server cert + key:    $SRV_CRT  $SRV_KEY"
openssl x509 -in "$SRV_CRT" -noout -subject -issuer -ext subjectAltName 2>/dev/null | sed 's/^/  /' >&2 || true

if [[ "$INSTALL_SYSTEM" -eq 1 ]]; then
  require_cmd sudo
  log "installing CA into system trust (sudo)"
  sudo cp -- "$ROOT_CRT" "/usr/local/share/ca-certificates/${CA_CERT_INSTALL_NAME}"
  sudo update-ca-certificates
fi

if [[ "$INSTALL_JAVA" -eq 1 ]]; then
  require_cmd sudo
  require_cmd keytool
  cacerts="$(detect_java_cacerts)"
  log "importing CA into Java cacerts: $cacerts"
  sudo keytool -delete -alias "$KEYSTORE_ALIAS" -keystore "$cacerts" -storepass "$KEYSTORE_PASS" >/dev/null 2>&1 || true
  sudo keytool -importcert \
    -alias "$KEYSTORE_ALIAS" \
    -file "$ROOT_CRT" \
    -keystore "$cacerts" \
    -storepass "$KEYSTORE_PASS" \
    -noprompt
fi

if [[ "$INSTALL_HOSTS" -eq 1 ]]; then
  require_cmd sudo
  hosts_ip="127.0.0.1"
  if [[ ${#IPS[@]} -gt 0 ]]; then
    hosts_ip="${IPS[0]}"
  fi
  for dom in "${DOMAINS[@]}"; do
    line="${hosts_ip}	${dom}"
    if grep -qF -- "$dom" /etc/hosts 2>/dev/null; then
      log "/etc/hosts already mentions $dom — skipping (edit manually if IP is wrong)"
    else
      log "appending hosts line: $line"
      printf '%s\n' "$line" | sudo tee -a /etc/hosts >/dev/null
    fi
  done
fi

cat <<EOF

Next steps (if you did not use --install-*):
  1. Trust CA (Ubuntu): sudo cp $ROOT_CRT /usr/local/share/ca-certificates/${CA_CERT_INSTALL_NAME} && sudo update-ca-certificates
  2. Java: sudo keytool -importcert -alias $KEYSTORE_ALIAS -file $ROOT_CRT -keystore \$(dirname \$(readlink -f \$(which java)))/../lib/security/cacerts -storepass changeit -noprompt
     (or set JAVA_HOME and use \$JAVA_HOME/lib/security/cacerts)
  3. Point your server (Elasticsearch, etc.) at: $SRV_CRT and $SRV_KEY
  4. curl test, e.g.: curl -v "https://${DOMAINS[0]}:9200"   (try each -d name; adjust port/path)

EOF
