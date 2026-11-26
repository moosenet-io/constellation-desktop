#!/usr/bin/env bash
# bootstrap.sh -- MooseNet build target #5 (WSL2 distro "moosenet-builder"), golden-env parity with AWS
# golden AMI ami-0e44e2cf6eee04eef (b3/ud-p1.sh): same pins, same runner user, same /w layout.
# Runs ONCE inside the distro as root (setup-windows.ps1 calls it). Idempotent: safe to re-run.
# Contains NO secrets, NO source, NO credentials. Builds run with vendored deps, offline.
set -euo pipefail
exec > >(tee -a /var/log/moosenet-bootstrap.log) 2>&1
TC=1.97.0
PGVECTOR_TAG=v0.8.0
RUSTUP_INIT_SHA256=b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55
MUSL_SHA256=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
NODE_SHA256=cbe59620b21732313774df4428586f7222a84af29e556f848abf624ba41caf90
RUNNER=builder
HERE=$(cd "$(dirname "$0")" && pwd)

echo "== 0. preflight"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
echo "nproc=$(nproc) mem=$(free -g | awk '/Mem:/{print $2}')G"; df -h / | tail -1

echo "== 1. packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential git jq curl ca-certificates xz-utils tar gzip perl \
  libssl-dev pkg-config iptables redis-server postgresql-16 postgresql-server-dev-16
# no long-lived services: run-jobs.sh makes per-job throwaway clusters/redis itself
pg_lsclusters -h 2>/dev/null | awk '{print $1" "$2}' | while read -r v c; do pg_dropcluster --stop "$v" "$c" || true; done
service redis-server stop 2>/dev/null || true
for b in /usr/lib/postgresql/16/bin/*; do ln -sf "$b" /usr/local/bin/; done   # run-jobs expects psql etc. in /usr/local/bin

echo "== 2. pgvector $PGVECTOR_TAG"
if [ ! -f /usr/share/postgresql/16/extension/vector.control ]; then
  rm -rf /opt/pgvector-src
  git clone --depth 1 --branch "$PGVECTOR_TAG" https://github.com/pgvector/pgvector.git /opt/pgvector-src
  make -C /opt/pgvector-src PG_CONFIG=/usr/bin/pg_config && make -C /opt/pgvector-src PG_CONFIG=/usr/bin/pg_config install
fi
PGVECTOR_COMMIT=$(git -C /opt/pgvector-src rev-parse HEAD 2>/dev/null || echo installed)

echo "== 3. musl-gcc 1.2.5"
if [ ! -x /usr/local/musl/bin/musl-gcc ]; then
  cd /tmp && curl -fsSL --proto '=https' --tlsv1.2 -o musl.tgz https://musl.libc.org/releases/musl-1.2.5.tar.gz
  echo "$MUSL_SHA256  musl.tgz" | sha256sum -c -
  tar -xzf musl.tgz && (cd musl-1.2.5 && ./configure --prefix=/usr/local/musl >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null)
  rm -rf /tmp/musl.tgz /tmp/musl-1.2.5
fi
ln -sf /usr/local/musl/bin/musl-gcc /usr/local/bin/musl-gcc

echo "== 4. node 20.19.2"
if ! /opt/node/bin/node -v 2>/dev/null | grep -qx v20.19.2; then
  cd /tmp && curl -fsSL --proto '=https' --tlsv1.2 -o node.txz https://nodejs.org/dist/v20.19.2/node-v20.19.2-linux-x64.tar.xz
  echo "$NODE_SHA256  node.txz" | sha256sum -c -
  rm -rf /opt/node && mkdir -p /opt/node && tar -xJf node.txz -C /opt/node --strip-components=1 && rm -f node.txz
fi

echo "== 5. runner + rust $TC"
id -u "$RUNNER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$RUNNER"
H=/home/$RUNNER
if ! runuser -u "$RUNNER" -- "$H/.cargo/bin/rustc" +"$TC" -V >/dev/null 2>&1; then
  curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/rustup-init https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init
  echo "$RUSTUP_INIT_SHA256  /tmp/rustup-init" | sha256sum -c -
  chmod 0755 /tmp/rustup-init
  runuser -u "$RUNNER" -- /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "$TC" \
    --target x86_64-unknown-linux-musl --component rust-src
  rm -f /tmp/rustup-init
fi
# repos pin components in rust-toolchain.toml (clippy, rustfmt); the runner has no egress, so install them now
runuser -u "$RUNNER" -- "$H/.cargo/bin/rustup" component add clippy rustfmt rust-src --toolchain "$TC"

echo "== 5b. rootless podman (docker-compatible CLI) + preloaded pgvector image for docker-using gate scripts"
# Rootless: the runner gets containers without a root daemon or docker group (it never becomes root-equivalent)
# and keeps its egress block; the image is pulled by root and loaded into the runner's own store.
apt-get install -y -q podman podman-docker uidmap slirp4netns passt fuse-overlayfs
grep -q "^$RUNNER:" /etc/subuid || usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$RUNNER"
mkdir -p /etc/containers/registries.conf.d; touch /etc/containers/nodocker
printf 'unqualified-search-registries = ["docker.io"]\nshort-name-mode = "permissive"\n' > /etc/containers/registries.conf.d/50-moosenet.conf
mount --make-rshared / || true
podman pull -q docker.io/pgvector/pgvector:pg16 >/dev/null && podman save -q -o /var/tmp/pgv.tar docker.io/pgvector/pgvector:pg16 && chmod 644 /var/tmp/pgv.tar
( cd "$H" && runuser -u "$RUNNER" -- env -i HOME="$H" PATH=/usr/local/bin:/usr/bin:/bin podman load -q -i /var/tmp/pgv.tar )
rm -rf "$H/.cargo/registry" "$H"/.cargo/credentials*
mkdir -p /w /x && chown "$RUNNER:$RUNNER" /w

echo "== 6. self-check"
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; return 1; fi; }
fail=0
check "redis-server ping" "redis-server --port 6399 --daemonize yes --save '' && sleep 1 && redis-cli -p 6399 ping | grep -qx PONG && redis-cli -p 6399 shutdown nosave" || fail=1
check "postgres 16" "postgres --version | grep -q ' 16\.'" || fail=1
check "pg throwaway + vector" "d=\$(runuser -u $RUNNER -- mktemp -d) && runuser -u $RUNNER -- initdb -D \$d/data -U terminus_test --auth=trust --no-sync && runuser -u $RUNNER -- pg_ctl -D \$d/data -o \"-k \$d -c listen_addresses=\" -w start && runuser -u $RUNNER -- psql -h \$d -U terminus_test -d postgres -c 'create extension vector' && runuser -u $RUNNER -- pg_ctl -D \$d/data -m immediate stop && rm -rf \$d" || fail=1
check "rustc $TC" "runuser -u $RUNNER -- $H/.cargo/bin/rustc +$TC -V" || fail=1
check "musl target" "runuser -u $RUNNER -- $H/.cargo/bin/rustup +$TC target list --installed | grep -qx x86_64-unknown-linux-musl" || fail=1
check "musl-gcc" "test -x /usr/local/bin/musl-gcc" || fail=1
check "clippy + rustfmt" "runuser -u $RUNNER -- $H/.cargo/bin/rustup component list --installed --toolchain $TC | grep -q clippy" || fail=1
check "rootless container (pgvector) as $RUNNER" "cd $H && runuser -u $RUNNER -- env -i HOME=$H PATH=/usr/local/bin:/usr/bin:/bin docker run --rm pgvector/pgvector:pg16 postgres --version" || fail=1
check "node v20.19.2" "/opt/node/bin/node -v | grep -qx v20.19.2" || fail=1
check "iptables owner match" "iptables -A OUTPUT -m owner --uid-owner $(id -u $RUNNER) -d 192.0.2.1 -j REJECT && iptables -D OUTPUT -m owner --uid-owner $(id -u $RUNNER) -d 192.0.2.1 -j REJECT" || fail=1
[ $fail = 0 ] || { echo "BOOTSTRAP SELF-CHECK FAILED"; exit 4; }

echo "== 7. manifest"
mkdir -p /etc/moosenet-burst
jq -n --arg built "$(date -u +%FT%TZ)" --arg kernel "$(uname -r)" --arg os "$(. /etc/os-release; echo "$PRETTY_NAME")" \
  --arg rustc "$(runuser -u $RUNNER -- $H/.cargo/bin/rustc +$TC -V)" --arg cargo "$(runuser -u $RUNNER -- $H/.cargo/bin/cargo +$TC -V)" \
  --arg redis "$(redis-server --version)" --arg postgres "$(postgres --version)" \
  --arg pgvector_tag "$PGVECTOR_TAG" --arg pgvector_commit "$PGVECTOR_COMMIT" \
  --arg node "$(/opt/node/bin/node -v)" --arg gcc "$(gcc --version | head -1)" --arg git "$(git --version)" \
  --arg dpkg_sha256 "$(dpkg-query -W | sort | sha256sum | cut -d' ' -f1)" --arg nproc "$(nproc)" \
  '{schema:"moosenet-burst-golden/v1", target:"wsl2-moosenet-builder", built:$built, os:$os, kernel:$kernel, nproc:$nproc,
    toolchain:{rustc:$rustc, cargo:$cargo, targets:["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"], components:["rust-src"]},
    services:{redis:$redis, postgres:$postgres, pgvector:{tag:$pgvector_tag, commit:$pgvector_commit}},
    tools:{node:$node, musl:"1.2.5", gcc:$gcc, git:$git}, dpkg_sha256:$dpkg_sha256,
    contains:{source:false, pr_inputs:false, credentials:false, cargo_registry_cache:"empty (deps vendored per job)"}}' \
  > /etc/moosenet-burst/image-manifest.json
cat /etc/moosenet-burst/image-manifest.json

echo "== 8. install watcher + lock down Windows access (applies after: wsl --terminate moosenet-builder)"
install -m 0755 "$HERE/watcher.sh" /opt/moosenet-watcher.sh
cat > /etc/wsl.conf <<'CONF'
[automount]
enabled=false
mountFsTab=false
[interop]
enabled=false
appendWindowsPath=false
[boot]
systemd=false
CONF
rm -rf /opt/pgvector-src; apt-get clean
sync; echo "BOOTSTRAP OK"
