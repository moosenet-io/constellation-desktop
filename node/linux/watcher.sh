#!/usr/bin/env bash
# /opt/moosenet-watcher.sh -- build-target job watcher (v3: concurrent slots). Started by the node controller, runs as
# root in WSL / Lima. Pull model, no inbound ports. Two job sources:
#   LAN pull: READY_BASE (/etc/moosenet-target5.conf) lists signed TARGET5-READY v1 files; each one for this PC runs once.
#   Local   : <batch>.tar + <batch>.ready dropped into exchange/inbox (legacy).
# v3: up to SLOTS batches run at once, each in its own work root /w/s<N> (own inputs, results, CARGO_TARGET_DIR and
# scratch) with JOBS_PER_SLOT cargo jobs, so they share the CPU instead of oversubscribing it. The poll loop keeps
# running while slots are busy, so the drop server's /ready/ heartbeat stays fresh and queued batches start the moment a
# slot frees. Config (optional, /etc/moosenet-target5.conf): SLOTS (default 3), JOBS_PER_SLOT (default nproc/SLOTS).
# Stop: close the window, Stop-Builder.ps1 (wsl --terminate), or create exchange/STOP (stops taking new batches,
# waits for running ones, then exits).
set -uo pipefail
WINX=${1:?usage: watcher.sh 'C:\path\to\exchange'}
WINX=${WINX//\//\\}   # accept C:/a/b (wsl.exe strips backslashes from args) -> C:\a\b
RUNNER=builder; RUID=$(id -u "$RUNNER")
exec 9>/run/moosenet-watcher.lock; flock -n 9 || { echo "another watcher is running; exiting"; exit 0; }
mkdir -p /x
if [ -d "$1" ] && [ "${1#/}" != "$1" ]; then   # macOS/Lima: exchange is already a Linux path (shared mount)
  mountpoint -q /x || mount --bind "$1" /x || { echo "FATAL: cannot bind $1"; exit 2; }
else
  mountpoint -q /x || mount -t drvfs "$WINX" /x || { echo "FATAL: cannot mount $WINX"; exit 2; }
fi
mkdir -p /x/inbox /x/outbox /w/archive
log() { echo "$(date -u +%FT%TZ) $*" | tee -a /x/outbox/watcher.log; }

# runner may only talk to loopback: jobs are offline (vendored deps). Fail closed if the rule can't be set.
iptables -C OUTPUT -m owner --uid-owner "$RUID" ! -o lo -j REJECT 2>/dev/null || \
  iptables -A OUTPUT -m owner --uid-owner "$RUID" ! -o lo -j REJECT || { log "FATAL egress block failed"; exit 3; }

[ -f /etc/moosenet-target5.conf ] && . /etc/moosenet-target5.conf
READY_BASE=${READY_BASE:-}
NPROC=$(nproc)
SLOTS=${SLOTS:-3}; [[ "$SLOTS" =~ ^[1-9]$ ]] || SLOTS=3
JOBS_PER_SLOT=${JOBS_PER_SLOT:-$(( NPROC / SLOTS ))}; [ "$JOBS_PER_SLOT" -ge 1 ] 2>/dev/null || JOBS_PER_SLOT=1
SLOTDIR=/run/moosenet-slots; rm -rf "$SLOTDIR"; mkdir -p "$SLOTDIR"   # slot claims never survive a restart
SEEN=/w/archive/.seen; touch "$SEEN"
log "watcher v3 up nproc=$NPROC slots=$SLOTS jobs/slot=$JOBS_PER_SLOT mem=$(free -g | awk '/Mem:/{print $2}')G free=$(df -BG --output=avail /w | tail -1 | tr -d ' ')"

claim_slot() {  # prints a free slot number and claims it (mkdir is atomic); returns 1 when all are busy
  local n; for ((n = 1; n <= SLOTS; n++)); do mkdir "$SLOTDIR/$n" 2>/dev/null && { echo "$n"; return 0; }; done; return 1
}
release_slot() { rm -rf "$SLOTDIR/$1"; }
busy_slots() { find "$SLOTDIR" -mindepth 1 -maxdepth 1 -type d | wc -l; }

run_one() {  # $1 slot, $2 batch, $3 tar file name (in /x/inbox), $4 sha256, [$5 extra run-jobs args]
  local slot=$1 b=$2 tar=$3 sha=$4 extra=${5:-} W="/w/s$1"
  log "START $b slot=$slot tar=$tar"
  : > "/x/inbox/$b.taken"   # the node controller never restarts WSL while a .taken exists
  rm -rf "$W/in" "$W/results"; mkdir -p "$W/in" "$W/results"
  cp "/x/inbox/$tar" "$W/$tar" || { log "FAIL $b copy"; echo copy-fail > "/x/outbox/$b.done"; rm -f "/x/inbox/$b.taken"; return; }
  echo "$sha  $W/$tar" | sha256sum -c - >/dev/null || { log "FAIL $b sha mismatch"; echo sha-mismatch > "/x/outbox/$b.done"; rm -f "/x/inbox/$b.taken"; return; }
  tar -xf "$W/$tar" -C "$W/in" && rm -f "$W/$tar"
  ( cd "$W/in" && sha256sum -c --quiet MANIFEST.sha256 ) || { log "FAIL $b MANIFEST"; echo manifest-fail > "/x/outbox/$b.done"; rm -f "/x/inbox/$b.taken"; return; }
  chown -R "$RUNNER:$RUNNER" "$W"
  if [ -f "$W/in/phase2-preflight.sh" ]; then bash "$W/in/phase2-preflight.sh" > "$W/results/preflight.log" 2>&1 || log "WARN $b preflight rc!=0 (see preflight.log)"; fi
  local t0; t0=$(date +%s)
  # shellcheck disable=SC2086
  runuser -u "$RUNNER" -- env -i HOME="/home/$RUNNER" PATH=/usr/local/bin:/usr/bin:/bin PIPELINE=0 PIPE_MIN_FREE_GB=60 WORK_ROOT="$W" \
    bash "$W/in/run-jobs.sh" "$W/in" "$W/results" --jobs "$JOBS_PER_SLOT" $extra > "$W/results/run-jobs.log" 2>&1 9>&-   # never leak the lock fd into jobs
  local rc=$? secs=$(( $(date +%s) - t0 ))
  cp /etc/moosenet-burst/image-manifest.json "$W/results/target-manifest.json" 2>/dev/null || true
  echo "{\"target\":\"wsl2-moosenet-builder\",\"rc\":$rc,\"secs\":$secs,\"nproc\":$NPROC,\"slot\":$slot,\"slots\":$SLOTS,\"cargo_jobs\":$JOBS_PER_SLOT}" > "$W/results/target-run.json"
  tar -cf "/x/outbox/$b-results.tar.part" -C "$W" results && mv "/x/outbox/$b-results.tar.part" "/x/outbox/$b-results.tar"
  ( cd /x/outbox && sha256sum "$b-results.tar" > "$b-results.tar.sha256" )
  rm -f "/x/inbox/$tar"; mv "/x/inbox/$b.taken" "/x/inbox/$b.finished"
  echo "rc=$rc secs=$secs" > "/x/outbox/$b.done"; sync
  log "DONE $b slot=$slot rc=$rc secs=$secs"
}

field() { sed -n "s/^$1=//p" "$2" | head -1; }
run_lan() {  # $1 slot, $2 local copy of .ready (owned by this call; removed at the end)
  local slot=$1 r=$2 b u sha put sput rput D="/w/s$1/dl"
  b=$(field batch "$r"); u=$(field inputs_url "$r"); sha=$(field inputs_sha256 "$r")
  put=$(field results_put_url "$r"); sput=$(field results_sidecar_put_url "$r"); rput=$(field report_put_url "$r")
  log "LAN START $b slot=$slot"
  mkdir -p "$D"; rm -f "$D/$b.tar"
  if ! curl -fsS --retry 3 -o "$D/$b.tar" "$u"; then log "FAIL $b download"; [ -n "$rput" ] && printf 'REFUSED download-failed\n' | curl -fsS -X PUT --data-binary @- "$rput"; rm -f "$r"; return; fi
  if ! echo "$sha  $D/$b.tar" | sha256sum -c - >/dev/null; then
    local got; got=$(sha256sum "$D/$b.tar" | cut -d' ' -f1); mkdir -p /w/quarantine; mv "$D/$b.tar" /w/quarantine/
    log "REFUSE $b sha mismatch"; [ -n "$rput" ] && printf 'REFUSED sha-mismatch expected=%s got=%s\n' "$sha" "$got" | curl -fsS -X PUT --data-binary @- "$rput"; rm -f "$r"; return
  fi
  cp "$D/$b.tar" "/x/inbox/$b.tar" 2>/dev/null || { log "FAIL stage $b"; rm -f "$r"; return; }
  run_one "$slot" "$b" "$b.tar" "$sha"
  local res="/x/outbox/$b-results.tar"
  if [ -f "$res" ]; then
    curl -fsS --retry 3 -X PUT --data-binary @"$res" "$put" && log "PUT results $b ok" || log "FAIL PUT results $b"
    [ -n "$sput" ] && curl -fsS -X PUT --data-binary @"$res.sha256" "$sput"
    [ -n "$rput" ] && curl -fsS -X PUT --data-binary @"/x/outbox/$b.done" "$rput"
  fi
  mkdir -p "/w/archive/$b"; mv "$D/$b.tar" "/w/archive/$b/" 2>/dev/null; mv "$r" "/w/archive/$b/$b.ready" 2>/dev/null
  sync   # wsl --terminate is a hard stop; flush so the archive survives it
}

poll_lan() {  # dispatch each new, valid .ready for this PC into a free slot; stop early when all slots are busy
  local n tmp body_sha slot
  for n in $(curl -fsS -m 10 "$READY_BASE" 2>/dev/null | grep -o '"name" *: *"[^"]*\.ready"' | sed 's/.*"\([^"]*\.ready\)"/\1/'); do
    tmp=$(mktemp /w/dl.ready.XXXXXX)
    curl -fsS -m 10 -o "$tmp" "$READY_BASE$n" 2>/dev/null || { rm -f "$tmp"; continue; }
    head -1 "$tmp" | grep -qx 'TARGET5-READY v1' || { rm -f "$tmp"; continue; }
    [ "$(field pc "$tmp")" = "${PC_NAME:-wsl-builder}" ] || { rm -f "$tmp"; continue; }
    body_sha=$(sha256sum "$tmp" | cut -d' ' -f1)
    grep -qx "$body_sha" "$SEEN" && { rm -f "$tmp"; continue; }   # replay / already taken
    if [ -s /etc/moosenet-allowed-signers ]; then   # op-1415: signed jobs required once the public key is installed
      curl -fsS -m 10 -o "$tmp.sig" "$READY_BASE$n.sig" 2>/dev/null || { log "REFUSE $n unsigned"; rm -f "$tmp" "$tmp.sig"; continue; }
      ssh-keygen -Y verify -f /etc/moosenet-allowed-signers -I moosenet-build-signer -n moosenet-build-job \
        -s "$tmp.sig" < "$tmp" >/dev/null 2>&1 || { log "REFUSE $n bad signature"; rm -f "$tmp" "$tmp.sig"; continue; }
      rm -f "$tmp.sig"
    fi
    if [ -z "$(field batch "$tmp")" ] || [ -z "$(field inputs_url "$tmp")" ] || [ -z "$(field inputs_sha256 "$tmp")" ] || [ -z "$(field results_put_url "$tmp")" ]; then
      log "REFUSE $n missing fields"; echo "$body_sha" >> "$SEEN"; rm -f "$tmp"; continue
    fi
    slot=$(claim_slot) || { rm -f "$tmp"; return; }   # all busy: leave it queued on the drop, retry next poll
    echo "$body_sha" >> "$SEEN"
    ( run_lan "$slot" "$tmp"; release_slot "$slot" ) 9>&- &
  done
}

poll_local() {  # legacy exchange/inbox drops: <batch>.ready = line1 tar, line2 sha256, optional line3 extra args
  local r b slot
  for r in /x/inbox/*.ready; do
    [ -e "$r" ] || return
    slot=$(claim_slot) || return
    b=$(basename "$r" .ready); mv "$r" "/x/inbox/$b.claimed"
    ( run_one "$slot" "$b" "$(sed -n 1p "/x/inbox/$b.claimed")" "$(sed -n 2p "/x/inbox/$b.claimed")" "$(sed -n 3p "/x/inbox/$b.claimed")"
      rm -f "/x/inbox/$b.claimed"; release_slot "$slot" ) 9>&- &
  done
}

while :; do
  if [ -e /x/STOP ]; then
    log "STOP file seen; taking no new batches, waiting for $(busy_slots) running"; wait; log "watcher exiting"; exit 0
  fi
  [ -n "$READY_BASE" ] && poll_lan
  poll_local
  sleep 20
done
