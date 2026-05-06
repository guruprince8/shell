# Local trusted TLS (no browser / Java certificate errors)

On a **lab or internal** machine, a common pain is HTTPS that uses a certificate the OS and JVM do not trust: browsers show warnings, `curl` needs `-k`, and Java stacks (Elasticsearch clients, Pega, etc.) fail with PKIX or “self signed certificate” errors.

This repo’s approach is **not** to trust a raw self-signed *server* certificate. Instead you:

1. Create your own **private Root CA** (one long-lived trust anchor).
2. Issue a **server certificate** signed by that CA, with correct **Subject Alternative Names (SANs)** for DNS names and IPs you use.
3. **Install the CA** (not necessarily the server cert) into:
   - Ubuntu’s system trust store → Chrome, Firefox, `curl`, most native TLS clients.
   - **Java `cacerts`** → JVM HTTPS and Elasticsearch Java clients.

After that, the **chain** is trusted: the server presents `server.crt` + clients already trust `rootCA.crt`. You avoid the usual “self-signed” untrusted-server-cert problem because the server cert is **CA-signed**, and your systems **trust the CA**.

> **Security:** Your `rootCA.key` can sign certificates for *any* name. Treat `CA_DIR` like a production signing key: restrict permissions, do not copy the private key off trusted admin machines, and use this pattern only where a private CA is appropriate (homelab, corporate internal PKI, dev VMs).

## Script: `scripts/setup-local-ca.sh`

Automates:

| Step | What it does |
|------|----------------|
| Root CA | `rootCA.key` (4096-bit RSA), `rootCA.crt` (10-year default), non-interactive subject |
| Server | `server.key`, `server.cnf` (SAN), CSR, `server.crt` signed by the CA |
| Optional `--install-system` | `sudo cp` CA cert into `/usr/local/share/ca-certificates/`, `sudo update-ca-certificates` |
| Optional `--install-java` | Detects `java.home` (or `JAVA_HOME`), imports CA into that JDK’s `cacerts` via `keytool` |
| Optional `--install-hosts` | Appends `IP<TAB>domain` to `/etc/hosts` for each `-d` (first `--ip`, or `127.0.0.1`) |

Defaults match a typical internal hostname example; override with flags or env vars.

### Requirements

- **Ubuntu** (or similar) with `openssl`, `sudo` for install flags.
- **`java` / `keytool`** on `PATH` for `--install-java` (OpenJDK is fine).

### Quick start

```bash
chmod +x scripts/setup-local-ca.sh

# Create material under ~/myCA (default), for oauth2.sapphire.com + LAN IP
./scripts/setup-local-ca.sh \
  -d oauth2.sapphire.com \
  -d elastic.sapphire.com \
  -i 192.168.1.228 \
  --install-all
```

- **`-d` / `--domain`:** Repeat for every hostname that must validate (each becomes a DNS SAN). The **first** `-d` is also the certificate **CN**. Must match what clients put in the URL.
- **`-i` / `--ip`:** Extra SAN IP (repeat `-i` for more). The script always adds `localhost` and `127.0.0.1` to SANs.
- **`--install-all`:** System CA store + Java `cacerts` + `/etc/hosts` line.

Run **without** `--install-*` if you only want files under `CA_DIR` and will install trust manually.

### Useful options

| Flag | Purpose |
|------|---------|
| `-c /path` | CA output directory (default `~/myCA`) |
| `--ca-cn NAME` | Issuer CN on the root cert (default `MyLocalRootCA`) |
| `--force-ca` | Regenerate root CA even if `rootCA.key` exists |
| `--new-server-key` | New `server.key` (default is reuse if present) |
| `-h` / `--help` | Usage |

### Environment variables

You can set defaults instead of flags: `DOMAIN` (single hostname when you pass no `-d`), `CA_DIR`, `CA_DAYS`, `SERVER_DAYS`, `CA_CN`, `KEYSTORE_ALIAS`, `KEYSTORE_PASS`, `CA_CERT_INSTALL_NAME`, `JAVA_HOME`.

The default `keytool` store password is the usual OpenJDK default **`changeit`**; override with `KEYSTORE_PASS` if your JDK uses something else.

### Re-running the script

- If `rootCA.key` exists and you **omit** `--force-ca`, the **same CA** is reused and only the **server** CSR/cert is regenerated (e.g. after changing `-d` / `-i`). That keeps one stable trust anchor.
- Use **`--force-ca`** only when you intentionally want a new root (you will need to re-import the new `rootCA.crt` everywhere).

## Manual equivalents (what the script automates)

### 1. Root CA

```bash
openssl genrsa -out rootCA.key 4096
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 -out rootCA.crt -subj "/O=Local Dev/CN=MyLocalRootCA"
```

### 2. Server cert with SAN

Use an OpenSSL config with `[req_ext]` / `subjectAltName` (the script writes `server.cnf` for you), then CSR + sign with `-extensions req_ext -extfile server.cnf`.

### 3. Trust on Ubuntu

```bash
sudo cp rootCA.crt /usr/local/share/ca-certificates/mylocal-developer-root-ca.crt
sudo update-ca-certificates
```

### 4. Trust in Java (Pega, Elasticsearch JVM clients, etc.)

Find `cacerts` (often `$JAVA_HOME/lib/security/cacerts`) and:

```bash
sudo keytool -importcert -alias my-local-ca -file rootCA.crt \
  -keystore "$JAVA_HOME/lib/security/cacerts" \
  -storepass changeit -noprompt
```

If the alias already exists from a previous import, delete it first or pick a new `KEYSTORE_ALIAS`.

### 5. Point apps at the **server** files

Use **`server.crt`** and **`server.key`** on the HTTPS listener (Elasticsearch `xpack.security.http.ssl.*`, nginx, etc.). Clients need the **CA** in their trust store, not necessarily the server cert file copied into the browser.

### 6. `/etc/hosts`

Map the hostname to the machine that serves TLS:

```text
192.168.1.228   oauth2.sapphire.com
```

### 7. Smoke test

```bash
curl -v "https://oauth2.sapphire.com:9200"
```

Adjust port and path. You should **not** need `-k` once the CA is trusted.

## Elasticsearch on Ubuntu (copy certs + HTTP SSL + restart)

After `setup-local-ca.sh` has produced `server.crt` and `server.key` (by default under **`~/myCA`**, or whatever you passed as `-c` / `CA_DIR`), install them where the Elasticsearch service can read them and point `xpack` at those paths.

### 1. Copy certificate and key into Elasticsearch’s cert directory

Adjust **`MY_CA`** if your files live elsewhere:

```bash
MY_CA="${HOME}/myCA"
sudo install -d -m 0755 /etc/elasticsearch/certs
sudo cp -- "$MY_CA/server.crt" "$MY_CA/server.key" /etc/elasticsearch/certs/
sudo chown root:elasticsearch /etc/elasticsearch/certs/server.crt /etc/elasticsearch/certs/server.key
sudo chmod 0640 /etc/elasticsearch/certs/server.crt /etc/elasticsearch/certs/server.key
```

If your package runs as a different user/group than `elasticsearch`, match ownership to whatever owns the Elasticsearch process (see `systemctl show -p User -p Group elasticsearch`).

### 2. Enable HTTP TLS in `elasticsearch.yml`

Edit **`/etc/elasticsearch/elasticsearch.yml`** (merge with your existing settings; do not duplicate keys):

```yaml
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: /etc/elasticsearch/certs/server.key
xpack.security.http.ssl.certificate: /etc/elasticsearch/certs/server.crt
```

Use the **same** hostname (or IP) in client URLs as in the cert SAN. Transport TLS between nodes is separate—see Elastic’s docs for your major version if you also secure transport.

### 3. Restart Elasticsearch

```bash
sudo systemctl restart elasticsearch
sudo systemctl status elasticsearch --no-pager
```

### 4. Quick check

```bash
curl -v "https://$(hostname -f):9200"
# or the host name from your cert, e.g. https://elastic.sapphire.com:9200
```

You should **not** need `-k` once the OS (and/or Java `cacerts`) trusts your local Root CA as described above.

## Troubleshooting

| Symptom | Things to check |
|---------|------------------|
| Browser still warns | CA imported? Restart browser. Cert SAN includes exact host from address bar? |
| `curl` still fails | System store updated? Try new shell / `curl` from same machine that ran `update-ca-certificates`. |
| Java PKIX / SSLHandshake | Correct JDK’s `cacerts`? Multiple JDKs installed—set `JAVA_HOME` before `--install-java` or import into each. |
| Name mismatch | URL host must appear as DNS SAN (or IP as IP SAN). Wildcard certs need `*.domain` in SAN. |

## Alternatives

- **mkcert** — ergonomic local HTTPS; still installs a CA into trust stores.
- **Corporate ADCS / Vault PKI** — when you have an existing internal CA.

For a **single automated file** on Ubuntu that mirrors a manual “my CA + signed server cert + trust installs” flow, use **`scripts/setup-local-ca.sh`** as above.
