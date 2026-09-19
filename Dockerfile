# Crafty Controller on Railway — Minecraft server management panel.
#
# Pinned to the official upstream image's registry version tag (latest
# release v4.11.0, 2026-09-16). Upgrades: bump this tag and redeploy.
#   Registry: https://gitlab.com/crafty-controller/crafty-4/container_registry
FROM registry.gitlab.com/crafty-controller/crafty-4:4.11.0

USER root
# socat bridges Railway's plain-HTTP router to Crafty's HTTPS-only listener
# (see railway-entrypoint.sh). Nothing else is changed from upstream.
RUN apt-get update \
    && apt-get -y --no-install-recommends install socat \
    && apt-get autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY railway-entrypoint.sh /railway-entrypoint.sh
RUN chmod +x /railway-entrypoint.sh

# Upstream ENTRYPOINT is /crafty/docker_launcher.sh with CMD ["-d","-i"]
# (daemon mode, ignore session.lock). We keep both and only wrap the
# entrypoint with the Railway volume-linking + bridge setup.
ENTRYPOINT ["/railway-entrypoint.sh"]
CMD ["-d", "-i"]

# Upstream image EXPOSEs 8000, 8123 (dynmap), 8443 (panel), 19132/udp
# (bedrock), 5520-5550/udp and 25500-25600 (Minecraft servers).
# On Railway: panel via the Railway domain (PORT=8000 -> bridge -> 8443),
# Minecraft servers via TCP proxies on individual ports in 25500-25600,
# Bedrock/dynmap not exposed (UDP not routable; dynmap optional).
