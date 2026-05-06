# Shell

Notes, scripts, and conventions for **POSIX `sh`** and **Bash** on Linux.

## Why care about the shell

The shell is the glue between users, scripts, and the OS: pipelines, job control, environment, and one-off automation. Small habits (quoting, error handling, portability) prevent subtle bugs in production and CI.

## Bash vs POSIX `sh`

| Topic | POSIX `sh` | Bash |
|--------|-------------|------|
| Shebang | `#!/bin/sh` | `#!/usr/bin/env bash` |
| Arrays | No | Yes (`arr=(a b)`) |
| `[[ ... ]]` | No | Yes |
| `${var//pat/repl}` | No | Yes |
| `source` | Often `. file` | `source file` or `. file` |

Use **`#!/usr/bin/env bash`** when you need Bash features; use **`#!/bin/sh`** only when the script is written to the POSIX subset and tested under a strict `sh` (e.g. `dash` on Debian).

## Script header (Bash)

A solid default for non-interactive Bash scripts:

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

- **`set -e`**: exit on first failing command (with caveats in pipelines and conditionals; combine with `-o pipefail`).
- **`set -u`**: treat unset variables as errors.
- **`set -o pipefail`**: pipeline fails if any stage fails.
- **`IFS`**: tighter word splitting when you read lines (adjust if you parse space-separated fields intentionally).

For **`set -e`** edge cases, prefer explicit checks for critical sections or `if ! cmd; then ...; fi` instead of relying on implicit behavior alone.

## Quoting and word splitting

Always quote expansions unless you intentionally want splitting:

```bash
path="$HOME/project"
cp -- "$src" "$dest"
```

Use `"$@"` (not `$@` or `$*`) when forwarding arguments.

## Tools

| Tool | Role |
|------|------|
| [ShellCheck](https://www.shellcheck.net/) | Static analysis; run locally or in CI (`shellcheck script.sh`). |
| `shellcheck -x` | Follow `source`d files when analyzing. |
| `sh -n script.sh` | Syntax check without running. |
| `bash -n script.sh` | Bash syntax check. |

## Style (quick reference)

- Prefer **lowercase** for script-local variables; **environment** and **constants** often use `UPPER_SNAKE`.
- Use **`$(cmd)`** instead of backticks for command substitution.
- Prefer **`printf '%s\n' "$var"`** over `echo "$var"` for portability and special characters.
- Use **`[[ ... ]]`** in Bash for string tests; use **`[ ... ]`** when aiming for POSIX `sh`.
- Name functions **`verb_noun`** or **`snake_case`**; keep functions short and testable.

## Common patterns

**Default for unset variable (Bash):**

```bash
: "${VAR:=default}"
```

**Iterate lines safely:**

```bash
while IFS= read -r line || [[ -n "$line" ]]; do
  printf '%s\n' "$line"
done < file.txt
```

**Temporary directory:**

```bash
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
```

**Avoid parsing `ls`:** use globs, `find` with `-print0` / `read -d ''`, or a small loop over `*.ext` as appropriate.

## Debugging

```bash
bash -x ./script.sh          # trace execution
set -x  # ... code ...  set +x   # localized trace inside script
```

## Further reading

- [POSIX shell specification](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html) — formal `sh` behavior.
- Bash manual: `man bash` or [GNU Bash manual](https://www.gnu.org/software/bash/manual/).
- [ShellCheck wiki](https://github.com/koalaman/shellcheck/wiki) — explains many warnings and idioms.

---

## Local trusted TLS (lab / internal)

To stop browser and Java “self-signed” / PKIX errors by using a **private CA** and a **CA-signed server cert** (with SANs), see [docs/local-trusted-ca.md](docs/local-trusted-ca.md) and run **`scripts/setup-local-ca.sh`**. That doc also covers **Elasticsearch on Ubuntu**: copy `server.crt` / `server.key` into `/etc/elasticsearch/certs/`, set `xpack.security.http.ssl.*` to those paths, and **`sudo systemctl restart elasticsearch`**.

---

Add scripts under a clear layout (for example `bin/` for executables, `lib/` for sourced helpers) and document any non-obvious dependencies or required tools in this file or next to the script.
