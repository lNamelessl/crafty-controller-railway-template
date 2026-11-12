#!/bin/bash
# Railway java shim for Crafty Controller (installed at /usr/local/bin/java,
# which precedes /usr/bin/java in sudo's secure_path, so Crafty's spawned
# Minecraft servers run through it; the real binary stays at /usr/bin/java).
#
# WHY: Crafty registers a new server in its DB the moment the user creates
# it, then downloads the server jar (paper.jar, ...) in a background thread
# that sleeps 3 s before it even starts the download. During that window the
# panel still starts servers: agreeing to the EULA in the creation wizard
# (and any manual Start click) spawns `java -jar paper.jar` on a file that
# does not exist yet -> java exits instantly -> "crashed" server. Users see
# a dead server on the default wizard path and report the deploy as failed.
# (The download itself, ~50 MB, takes well under a second on Railway; the
# vulnerable window is the 3 s sleep, and the import-status guard only arms
# once the download thread wakes up.)
#
# This shim makes starting deterministic:
#   1. wait-for-jar: when the command is `java ... -jar X.jar`, wait until
#      X.jar exists, has a stable size (download finished) and carries the
#      zip magic bytes (jars are zips), then exec the real java. If the jar
#      never becomes ready within $JAR_WAIT_TIMEOUT seconds, exec java
#      anyway so the genuine error surfaces instead of hanging forever.
#   2. MEMORY ceiling: if the wizard's chosen -Xmx exceeds $MEMORY (MB), it
#      is clamped down with a loud console note so an oversized JVM cannot
#      OOM the whole Railway service. Raise the MEMORY variable to allow
#      bigger heaps (Paper with a few players: 2048 MB is fine).
#
# Everything else (java -version, Crafty itself, steamcmd, bedrock) passes
# through untouched.

REAL_JAVA="/usr/bin/java"
JAR_WAIT_TIMEOUT="${JAR_WAIT_TIMEOUT:-300}"
MEMORY_MB="${MEMORY:-2048}"

log() { echo "[railway-java] $*"; }

# translate "1024M" / "2G" style values to MB
to_mb() {
    local v="$1" unit num
    case "$v" in
        *[Gg]) num="${v%?}"; echo $((num * 1024)) ;;
        *[Mm]) num="${v%?}"; echo "$num" ;;
        *) echo "$v" ;;
    esac
}

# --- pass through args, clamping -Xms/-Xmx to the MEMORY ceiling ------------
args_out=()
prev=""
jar_path=""
for arg in "$@"; do
    case "$arg" in
        -jar) prev="-jar"; args_out+=("$arg"); continue ;;
        -Xmx*)
            want="${arg#-Xmx}"
            if [ "$(to_mb "$want")" -gt "$MEMORY_MB" ] 2>/dev/null; then
                log "clamping -Xmx${want} -> ${MEMORY_MB}M (MEMORY ceiling; raise the MEMORY variable to allow bigger heaps)"
                args_out+=("-Xmx${MEMORY_MB}M")
                continue
            fi
            args_out+=("$arg")
            ;;
        -Xms*)
            want="${arg#-Xms}"
            if [ "$(to_mb "$want")" -gt "$MEMORY_MB" ] 2>/dev/null; then
                args_out+=("-Xms${MEMORY_MB}M")
                continue
            fi
            args_out+=("$arg")
            ;;
        *) args_out+=("$arg") ;;
    esac
    if [ "$prev" = "-jar" ]; then jar_path="$arg"; fi
    prev="$arg"
done

# --- wait for the server jar download to complete ---------------------------
if [ -n "$jar_path" ]; then
    waited=0
    stable=0
    last_size=-1
    announced=0
    while [ "$waited" -lt "$JAR_WAIT_TIMEOUT" ]; do
        if [ -f "$jar_path" ]; then
            size=$(stat -c %s "$jar_path" 2>/dev/null || echo 0)
            if [ "$size" -gt 0 ] && [ "$size" = "$last_size" ]; then
                stable=$((stable + 1))
            else
                stable=0
            fi
            last_size="$size"
            # zip magic (PK) + two consecutive stable size samples = complete
            if [ "$stable" -ge 2 ] && head -c 2 "$jar_path" 2>/dev/null | grep -q "PK"; then
                log "server jar ready: $jar_path ($size bytes, waited ${waited}s)"
                break
            fi
        elif [ "$announced" -eq 0 ]; then
            log "waiting for the server jar download to finish before starting (start proceeds automatically once the jar is complete)"
            announced=1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [ "$waited" -ge "$JAR_WAIT_TIMEOUT" ]; then
        log "WARNING: $jar_path not ready after ${JAR_WAIT_TIMEOUT}s (download may have failed) - starting java anyway to surface the real error"
    fi
fi

exec "$REAL_JAVA" "${args_out[@]}"
