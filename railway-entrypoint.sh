#!/bin/bash
# Railway entrypoint for Crafty Controller 4.
#
# Three jobs, all upstream-compatible:
#
# 1. One-volume persistence. Railway allows exactly one volume per service;
#    it is mounted at /data. The upstream image expects five separate paths
#    (/crafty/app/config, /crafty/servers, /crafty/backups, /crafty/logs,
#    /crafty/import). We create those as symlinks into /data subdirs before
#    the upstream launcher (/crafty/docker_launcher.sh) runs, so everything
#    the app writes under the documented paths lands on the volume.
#
# 2. Group permissions. The app runs as user `crafty` (primary group root).
#    The upstream launcher's repair_permissions() only walks /crafty with
#    `find` (which does NOT follow symlinks), so it can never fix perms
#    inside the volume. We do it here: seed the config dir ourselves on
#    first boot and make it group-writable, so `crafty` can write the DB,
#    crafty.yaml and default-creds.txt it generates on first boot.
#
#    - First boot (config empty): seed defaults from /crafty/app/config_original
#      and fix perms recursively (one-time cost).
#    - Every boot: fix perms on the five top-level dirs only (cheap).
#      Everything created later at runtime is created BY crafty, so it is
#      already crafty-owned and writable.
#
# 3. Deterministic first server start + non-CLI login discoverability:
#    - pre-seed the big-bucket jar catalog cache so jar downloads cannot
#      silently fail when the catalog endpoint is unreachable at boot;
#    - print default-creds.txt to the deploy log once it exists (users
#      without railway ssh cannot otherwise read a volume file);
#    - the java shim at /usr/local/bin/java (see java-shim.sh) makes server
#      starts wait for the async jar download and enforces the MEMORY heap
#      ceiling.

set -e

DATA_ROOT="/data"
CRAFTY_CONFIG_SRC="/crafty/app/config_original"

# volume-subdir -> documented upstream path
make_link() {
    local name="$1" target="$2"
    mkdir -p "${DATA_ROOT}/${name}"
    if [ ! -L "${target}" ]; then
        # Fresh container layer: the path is either absent or an empty
        # leftover dir from the image. Preserve anything unexpected, then
        # replace it with the symlink.
        if [ -d "${target}" ] && [ -n "$(ls -A "${target}" 2>/dev/null)" ]; then
            cp -a "${target}/." "${DATA_ROOT}/${name}/" 2>/dev/null || true
        fi
        rm -rf "${target}"
        ln -s "${DATA_ROOT}/${name}" "${target}"
    fi
    # Top-level perms every boot: crafty needs group rw + traversal.
    chgrp root "${DATA_ROOT}/${name}" "${DATA_ROOT}" 2>/dev/null || true
    chmod 2775 "${DATA_ROOT}/${name}" 2>/dev/null || true
    chmod 2775 "${DATA_ROOT}" 2>/dev/null || true
}

echo "[railway] linking volume ${DATA_ROOT} into upstream crafty paths..."
make_link config  /crafty/app/config
make_link servers /crafty/servers
make_link backups /crafty/backups
make_link logs    /crafty/logs
make_link import  /crafty/import

# First-boot hardening for the server-jar catalog cache. Crafty fetches its
# "big bucket" jar catalog (jars.arcadiatech.org manifest) into
# config/bigbucket.json; if that fetch fails on the very first boot the cache
# stays missing and every "download jar" server creation silently fails
# (get_fetch_url returns None -> no download, no error). Pre-seeding the cache
# at boot makes jar downloads work even when the catalog endpoint hiccups;
# the app's own 12-hour refresher overwrites it once it can reach the bucket.
BIGBUCKET_CACHE="${DATA_ROOT}/config/bigbucket.json"
if [ ! -s "${BIGBUCKET_CACHE}" ]; then
    echo "[railway] pre-seeding big-bucket jar catalog cache..."
    seeded=0
    for attempt in 1 2 3; do
        if python3 -c "
import json, urllib.request
req = urllib.request.Request(
    'https://jars.arcadiatech.org/manifest.json',
    headers={'User-Agent': 'crafty-railway-template-preseed'},
)
with urllib.request.urlopen(req, timeout=20) as r:
    manifest = json.load(r)
with open('${BIGBUCKET_CACHE}', 'w') as f:
    json.dump({'last_refreshed': 'preseeded by railway entrypoint', 'categories': manifest}, f)
" 2>/dev/null; then
            seeded=1
            break
        fi
        sleep 3
    done
    if [ "$seeded" -eq 1 ]; then
        chgrp root "${BIGBUCKET_CACHE}" 2>/dev/null || true
        chmod g+rw "${BIGBUCKET_CACHE}" 2>/dev/null || true
        echo "[railway] jar catalog cache seeded (server downloads work even if the catalog endpoint is down)"
    else
        rm -f "${BIGBUCKET_CACHE}.tmp"
        echo "[railway] jar catalog cache pre-seed failed (catalog unreachable) - Crafty will retry on its 12h schedule"
    fi
fi

# First boot only: the upstream launcher seeds ./app/config from
# ./app/config_original when it is empty, but its perm repair never
# reaches inside our volume (find does not follow symlinks) and files it
# copies land root-owned 644 -> crafty could not write its own DB.
# So we seed + fix perms here; the launcher then sees a non-empty config
# dir and only refreshes version.json.
if [ -z "$(ls -A /crafty/app/config 2>/dev/null)" ]; then
    echo "[railway] first boot: seeding config defaults with volume-safe perms..."
    cp -r "${CRAFTY_CONFIG_SRC}"/. /crafty/app/config/
    chgrp -R root "${DATA_ROOT}/config"
    chmod -R g+rwX "${DATA_ROOT}/config"
    find "${DATA_ROOT}/config" -type d -exec chmod g+s {} +
fi

# First-login discoverability for non-CLI users. Crafty generates
# /data/config/default-creds.txt a few seconds after first boot; CLI users
# read it with `railway ssh`, but dashboard-only users have no shell. Print
# the file to the deploy log (Railway dashboard -> Deployments -> View Logs)
# as soon as it appears. Reprints on later boots while the file still exists
# (i.e. while the default password is still unchanged).
(
    n=0
    while [ "$n" -lt 120 ]; do
        if [ -s "${DATA_ROOT}/config/default-creds.txt" ]; then
            echo "[railway] ============================================================"
            echo "[railway] CRAFTY PANEL FIRST LOGIN (username + password below)"
            cat "${DATA_ROOT}/config/default-creds.txt"
            echo "[railway] (same file lives at /data/config/default-creds.txt on the volume;"
            echo "[railway]  change the password in the panel after your first login)"
            echo "[railway] ============================================================"
            break
        fi
        sleep 5
        n=$((n + 1))
    done
) &

echo "[railway] MEMORY=${MEMORY:-2048}MB is the JVM heap ceiling (raise the MEMORY variable for bigger Minecraft heaps)"
echo "[railway] server starts wait for the jar download to complete automatically (no more instant-exit crashes on fresh servers)"

# Plain-HTTP bridge for Railway's router. Crafty v4 is HTTPS-only (self-signed
# cert on 8443); Railway terminates TLS at the edge and forwards plain HTTP to
# the domain's target port (8000). socat bridges the two: browser -> Railway
# TLS -> HTTP here -> TLS to Crafty. Users get a valid Railway certificate;
# the self-signed cert stays an internal detail.
#
# Two listeners, on purpose:
#   - 8000 always: the HTTP domain's target port (routing).
#   - $PORT when set (Railway injects it, e.g. the TCP-proxy port): Railway's
#     healthcheck probes $PORT, so we answer there too. The template sets
#     PORT=${{RAILWAY_TCP_PROXY_PORT}} so it never collides with the
#     25500-25600 Minecraft server range.
# Restart loops keep both bridges alive independently.
CRAFTY_HTTPS_PORT="${CRAFTY_HTTPS_PORT:-8443}"
BRIDGE_PORT="8000"

start_bridge() {
    local port="$1"
    echo "[railway] starting HTTP->HTTPS bridge 0.0.0.0:${port} -> 127.0.0.1:${CRAFTY_HTTPS_PORT}"
    (
        while true; do
            socat -d -d "TCP-LISTEN:${port}",fork,reuseaddr \
                  "OPENSSL:127.0.0.1:${CRAFTY_HTTPS_PORT}",verify=0 >>/var/log/railway-bridge.log 2>&1 || true
            sleep 1
        done
    ) &
}

start_bridge "${BRIDGE_PORT}"
if [ -n "${PORT:-}" ] && [ "${PORT}" != "${BRIDGE_PORT}" ]; then
    start_bridge "${PORT}"
fi

echo "[railway] handing off to upstream docker_launcher.sh $*"
exec /crafty/docker_launcher.sh "$@"
