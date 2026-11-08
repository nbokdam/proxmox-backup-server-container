#!/bin/bash
# Runs the two PBS daemons without systemd and bootstraps a fresh volume.
#
# Environment:
#   PBS_ADMIN_PASSWORD   password for admin@pbs (created/updated on every start; required)
#   PBS_DATASTORE_NAME   datastore to create if missing (optional, needs PBS_DATASTORE_PATH)
#   PBS_DATASTORE_PATH   directory for that datastore; must be empty or absent on first use
#   PBS_TLS_CERT/KEY     PEM files (e.g. a mounted cert-manager Secret) used instead of the
#                        self-signed certificate. A change exits the container so it restarts.
set -euo pipefail

ETC=/etc/proxmox-backup
LIB=/var/lib/proxmox-backup
LOG=/var/log/proxmox-backup

log() { echo "entrypoint: $*"; }

mkdir -p /run/systemd/journal "$ETC" "$LIB" "$LOG"
# libsystemd callers look for the journald socket.
[ -e /run/systemd/journal/socket ] || ln -s /dev/log /run/systemd/journal/socket 2>/dev/null || true

chown backup:backup "$ETC" "$LIB" "$LOG"
chmod 700 "$ETC" "$LIB" "$LOG"
rm -f "$ETC"/.*.lck "$ETC"/*.lock 2>/dev/null || true

# The package postinst ran at image build time, against an empty config. Its upgrade
# migrations are gated on the previously installed version ("configure <old>"), so replay it
# against the persisted volumes whenever the image version differs from the one that last
# used them. Failure is fatal on purpose: don't start the daemons on a half-migrated config.
migrate_volumes() {
  local marker="$LIB/.image-version" current previous postinst
  current=$(dpkg-query -W -f='${Version}' proxmox-backup-server)
  postinst=/var/lib/dpkg/info/proxmox-backup-server.postinst

  if [ ! -s "$marker" ]; then
    # Fresh volume (nothing to migrate) or one from before this marker existed (unknown origin).
    if [ -e "$ETC/datastore.cfg" ] || [ -e "$ETC/user.cfg" ]; then
      log "WARNING: existing data without version marker; cannot determine migrations to run"
    fi
    previous=""
  else
    previous=$(cat "$marker")
  fi

  if [ -n "$previous" ] && [ "$previous" != "$current" ]; then
    if dpkg --compare-versions "$previous" gt "$current"; then
      log "WARNING: volume was last used by newer version $previous (downgrade to $current); skipping migrations"
    else
      log "upgrading volume data $previous -> $current, running package postinst"
      # dpkg-maintscript-helper (called by the postinst) requires dpkg's maintscript environment.
      DPKG_MAINTSCRIPT_NAME=postinst DPKG_MAINTSCRIPT_PACKAGE=proxmox-backup-server \
      DPKG_MAINTSCRIPT_PACKAGE_REFCOUNT=1 DPKG_MAINTSCRIPT_ARCH=amd64 \
      DPKG_RUNNING_VERSION="$current" "$postinst" configure "$previous" 2>&1 | tee /tmp/postinst.out
      # The postinst reports most migration failures as messages and still exits 0.
      if [ "${PIPESTATUS[0]}" -ne 0 ] || grep -q -E '^(Failed migrate|Failed to rename|Error:)' /tmp/postinst.out; then
        log "ERROR: postinst migration failed; not starting (volume marker left at $previous)"
        exit 1
      fi
    fi
  fi
  echo "$current" > "$marker"
  chown backup:backup "$marker"
}
migrate_volumes

install_cert() {
  [ -n "${PBS_TLS_CERT:-}" ] && [ -r "${PBS_TLS_CERT}" ] && [ -r "${PBS_TLS_KEY:-}" ] || return 0
  # PBS reads the key and certificate chain from these fixed names.
  install -o backup -g backup -m 640 "$PBS_TLS_KEY"  "$ETC/proxy.key"
  install -o backup -g backup -m 640 "$PBS_TLS_CERT" "$ETC/proxy.pem"
  log "installed TLS certificate from $PBS_TLS_CERT"
}
install_cert

cert_hash() { [ -r "${PBS_TLS_CERT:-}" ] && sha256sum "$PBS_TLS_CERT" | cut -d' ' -f1 || echo none; }
initial_cert_hash=$(cert_hash)

# PBS logs to syslog; forward it to the container's stdout.
busybox syslogd -n -O /dev/stdout &
for _ in $(seq 1 20); do [ -S /dev/log ] && break; sleep 0.2; done

/usr/lib/x86_64-linux-gnu/proxmox-backup/proxmox-backup-api &
api=$!

# The proxy daemon needs the API's keys and certificate, so wait for the API.
for _ in $(seq 1 60); do
  [ -e "$ETC/authkey.key" ] && [ -e "$ETC/proxy.pem" ] && break
  sleep 1
done
install_cert  # the API may have generated a self-signed one meanwhile

setpriv --reuid=backup --regid=backup --init-groups /usr/lib/x86_64-linux-gnu/proxmox-backup/proxmox-backup-proxy &
proxy=$!

# Bootstrap the admin user (idempotent) once the API answers on its local socket.
for _ in $(seq 1 60); do
  proxmox-backup-manager user list >/dev/null 2>&1 && break
  sleep 1
done
if [ -n "${PBS_ADMIN_PASSWORD:-}" ]; then
  if proxmox-backup-manager user list --output-format json | grep -q '"userid":"admin@pbs"'; then
    proxmox-backup-manager user update admin@pbs --password "$PBS_ADMIN_PASSWORD" --enable 1
  else
    proxmox-backup-manager user create admin@pbs --password "$PBS_ADMIN_PASSWORD"
  fi
  proxmox-backup-manager acl update / Admin --auth-id admin@pbs
else
  log "PBS_ADMIN_PASSWORD not set; admin@pbs not managed"
fi

if [ -n "${PBS_DATASTORE_NAME:-}" ] && [ -n "${PBS_DATASTORE_PATH:-}" ]; then
  if ! proxmox-backup-manager datastore list --output-format json | grep -q "\"name\":\"${PBS_DATASTORE_NAME}\""; then
    mkdir -p "$PBS_DATASTORE_PATH"
    chown backup:backup "$PBS_DATASTORE_PATH"
    proxmox-backup-manager datastore create "$PBS_DATASTORE_NAME" "$PBS_DATASTORE_PATH"
  fi
fi

shutdown() { kill "$proxy" "$api" 2>/dev/null || true; wait; exit 0; }
trap shutdown TERM INT

# Exit when either daemon dies (the orchestrator restarts us) or the mounted certificate changes.
while kill -0 "$api" 2>/dev/null && kill -0 "$proxy" 2>/dev/null; do
  if [ "$(cert_hash)" != "$initial_cert_hash" ]; then
    log "TLS certificate changed, restarting"
    shutdown
  fi
  sleep 10 & wait $!
done
log "a PBS daemon exited"
shutdown
