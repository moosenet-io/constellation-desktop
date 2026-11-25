#!/usr/bin/env bash
# /opt/moosenet-watcher.sh -- build target #5 job watcher. Started by Start-Builder.ps1, runs as root in WSL.
# Pull model, no inbound ports: the conductor drops <batch>.tar + <batch>.ready into exchange\inbox;
# this picks it up, runs the same run-jobs.sh as AWS, writes <batch>-results.tar(+.sha256) and <batch>.done
# into exchange\outbox. Only the exchange folder is mounted (Windows automount is off).
# Stop: close the window, or Stop-Builder.ps1 (wsl --terminate), or create exchange\STOP.
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
mkdir -p /x/inbox /x/outbox /w/dl
log() { echo "$(date -u +%FT%TZ) $*" | tee -a /x/outbox/watcher.log; }

# runner may only talk to loopback: jobs are offline (vendored deps). Fail closed if the rule can't be set.
iptables -C OUTPUT -m owner --uid-owner "$RUID" ! -o lo -j REJECT 2>/dev/null || \
  iptables -A OUTPUT -m owner --uid-owner "$RUID" ! -o lo -j REJECT || { log "FATAL egress block failed"; exit 3; }
log "watcher up nproc=$(nproc) mem=$(free -g | awk '/Mem:/{print $2}')G free=$(df -BG --output=avail /w | tail -1)"

run_one() {  # $1 = path to .ready (line1: tar file name, line2: sha256, optional line3: extra run-jobs args)
  local ready=$1 b tar sha extra
  b=$(basename "$ready" .ready); tar=$(sed -n 1p "$ready"); sha=$(sed -n 2p "$ready"); extra=$(sed -n 3p "$ready")
  mv "$ready" "/x/inbox/$b.taken"
  log "START $b tar=$tar"
  rm -rf /w/in /w/results; mkdir -p /w/in /w/results
  cp "/x/inbox/$tar" "/w/$tar" || { log "FAIL $b copy"; return; }
  echo "$sha  /w/$tar" | sha256sum -c - >/dev/null || { log "FAIL $b sha mismatch"; echo sha-mismatch > "/x/outbox/$b.done"; return; }
  tar -xf "/w/$tar" -C /w/in && rm -f "/w/$tar"
  ( cd /w/in && sha256sum -c --quiet MANIFEST.sha256 ) || { log "FAIL $b MANIFEST"; echo manifest-fail > "/x/outbox/$b.done"; return; }
  chown -R "$RUNNER:$RUNNER" /w
  if [ -f /w/in/phase2-preflight.sh ]; then bash /w/in/phase2-preflight.sh > /w/results/preflight.log 2>&1 || log "WARN $b preflight rc!=0 (see preflight.log)"; fi
  local t0=$(date +%s)
  # shellcheck disable=SC2086
  runuser -u "$RUNNER" -- env -i HOME="/home/$RUNNER" PATH=/usr/local/bin:/usr/bin:/bin PIPELINE=0 PIPE_MIN_FREE_GB=60 \
    bash /w/in/run-jobs.sh /w/in /w/results --jobs "$(nproc)" $extra > /w/results/run-jobs.log 2>&1 9>&-   # never leak the lock fd into jobs
  local rc=$? secs=$(( $(date +%s) - t0 ))
  cp /etc/moosenet-burst/image-manifest.json /w/results/target-manifest.json 2>/dev/null || true
  echo "{\"target\":\"wsl2-moosenet-builder\",\"rc\":$rc,\"secs\":$secs,\"nproc\":$(nproc)}" > /w/results/target-run.json
  tar -cf "/x/outbox/$b-results.tar.part" -C /w results && mv "/x/outbox/$b-results.tar.part" "/x/outbox/$b-results.tar"
  ( cd /x/outbox && sha256sum "$b-results.tar" > "$b-results.tar.sha256" )
  rm -f "/x/inbox/$tar"; mv "/x/inbox/$b.taken" "/x/inbox/$b.finished"
  echo "rc=$rc secs=$secs" > "/x/outbox/$b.done"; sync
  log "DONE $b rc=$rc secs=$secs"
}

# ---- v2: LAN pull (target5-lan-pull-design). Config in /etc/moosenet-target5.conf: READY_BASE=http://<ct320>:18480/ready/
#      (JSON listing; each TARGET5-READY v1 file for this pc is run once). Fields: batch, inputs_url, inputs_sha256, results_put_url,
#      results_sidecar_put_url, report_put_url, expires. Signature check is added once the relay publishes the key.
[ -f /etc/moosenet-target5.conf ] && . /etc/moosenet-target5.conf
READY_BASE=${READY_BASE:-}
SEEN=/w/archive/.seen; mkdir -p /w/archive; touch "$SEEN"
field() { sed -n "s/^$1=//p" "$2" | head -1; }
run_lan() {  # $1 = local copy of .ready
  local r=$1 b u sha put sput rput body_sha
  body_sha=$(sha256sum "$r" | cut -d' ' -f1)
  grep -qx "$body_sha" "$SEEN" && return 0            # replay / already done
  b=$(field batch "$r"); u=$(field inputs_url "$r"); sha=$(field inputs_sha256 "$r")
  put=$(field results_put_url "$r"); sput=$(field results_sidecar_put_url "$r"); rput=$(field report_put_url "$r")
  [ -n "$b" ] && [ -n "$u" ] && [ -n "$sha" ] && [ -n "$put" ] || { log "REFUSE lan .ready missing fields"; echo "$body_sha" >> "$SEEN"; return; }
  echo "$body_sha" >> "$SEEN"
  log "LAN START $b"
  mkdir -p /w/dl; rm -f "/w/dl/$b.tar"
  if ! curl -fsS --retry 3 -o "/w/dl/$b.tar" "$u"; then log "FAIL $b download"; [ -n "$rput" ] && printf 'REFUSED download-failed\n' | curl -fsS -X PUT --data-binary @- "$rput"; return; fi
  if ! echo "$sha  /w/dl/$b.tar" | sha256sum -c - >/dev/null; then
    got=$(sha256sum "/w/dl/$b.tar" | cut -d' ' -f1); mkdir -p /w/quarantine; mv "/w/dl/$b.tar" /w/quarantine/
    log "REFUSE $b sha mismatch"; [ -n "$rput" ] && printf 'REFUSED sha-mismatch expected=%s got=%s\n' "$sha" "$got" | curl -fsS -X PUT --data-binary @- "$rput"; return
  fi
  # reuse the v1 runner by staging into the local inbox
  cp "/w/dl/$b.tar" "/x/inbox/$b.tar" 2>/dev/null || { log "FAIL stage"; return; }
  printf '%s.tar\n%s\n' "$b" "$sha" > "/x/inbox/$b.ready"; run_one "/x/inbox/$b.ready"
  local res="/x/outbox/$b-results.tar"
  if [ -f "$res" ]; then
    curl -fsS --retry 3 -X PUT --data-binary @"$res" "$put" && log "PUT results $b ok" || log "FAIL PUT results $b"
    [ -n "$sput" ] && curl -fsS -X PUT --data-binary @"$res.sha256" "$sput"
    [ -n "$rput" ] && curl -fsS -X PUT --data-binary @"/x/outbox/$b.done" "$rput"
  fi
  mkdir -p "/w/archive/$b"; mv "/w/dl/$b.tar" "/w/archive/$b/" 2>/dev/null; cp "$r" "/w/archive/$b/"
  sync   # wsl --terminate is a hard stop; flush so the archive survives it
}

while :; do
  if [ -n "$READY_BASE" ]; then   # e.g. http://<drop-server>:18480/ready/ (JSON listing, then each <batch>.ready)
    for n in $(curl -fsS -m 10 "$READY_BASE" 2>/dev/null | grep -o '"name" *: *"[^"]*\.ready"' | sed 's/.*"\([^"]*\.ready\)"/\1/'); do
      curl -fsS -m 10 -o /w/dl.ready "$READY_BASE$n" 2>/dev/null || continue
      head -1 /w/dl.ready | grep -qx 'TARGET5-READY v1' || continue
      [ "$(field pc /w/dl.ready)" = "${PC_NAME:-wsl-builder}" ] || continue
      if [ -s /etc/moosenet-allowed-signers ]; then   # op-1415: signed jobs required once the public key is installed
        curl -fsS -m 10 -o /w/dl.ready.sig "$READY_BASE$n.sig" 2>/dev/null || { log "REFUSE $n unsigned"; continue; }
        ssh-keygen -Y verify -f /etc/moosenet-allowed-signers -I moosenet-build-signer -n moosenet-build-job \
          -s /w/dl.ready.sig < /w/dl.ready >/dev/null 2>&1 || { log "REFUSE $n bad signature"; continue; }
      fi
      run_lan /w/dl.ready
    done
  fi
  [ -e /x/STOP ] && { log "STOP file seen; exiting"; exit 0; }
  for r in /x/inbox/*.ready; do [ -e "$r" ] && run_one "$r"; done
  sleep 20
done
