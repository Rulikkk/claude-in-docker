# syntax=docker/dockerfile:1
#
# claude-docker — a hardened, unattended-friendly Claude Code container.
#
# Contains no business logic. Downstream images and compose files supply the
# CMD, the prompts, and the policy; this layer supplies auth, egress control,
# permission floor, uid alignment and a headless job runner.
FROM node:22-slim

ARG CC_VERSION=latest

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gosu iproute2 ipset iptables jq locales \
      python3 python3-yaml ripgrep tini \
 && sed -i '/^# *en_US.UTF-8 UTF-8/s/^# *//' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@${CC_VERSION} \
 && npm cache clean --force \
 && claude --version

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC

# ~/.claude.json (OAuth account, MCP servers, per-project trust) normally lives
# OUTSIDE ~/.claude. Setting this moves it inside, so one mount persists login
# and directory trust across container recreates.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# DISABLE_REMOTE_CONTROL is the single switch for whether this container can
# be driven by Remote Control. Default "1" (off) sets the four vars
# Anthropic's docs name as disabling the feature-flag evaluation RC
# eligibility depends on — DISABLE_TELEMETRY, DO_NOT_TRACK,
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, DISABLE_GROWTHBOOK — to "1".
# https://code.claude.com/docs/en/remote-control#requirements
# Set to "0" to enable RC; entrypoint.sh reconciles all four vars from this
# one at every start, so setting it here is just the image default.
ENV DISABLE_REMOTE_CONTROL=1

ENV ENABLE_FIREWALL=1 \
    PUID=1000 \
    PGID=1000

# Secure-by-default permission floor. Read at the highest precedence on Linux;
# nothing in ~/.claude or a project's .claude/ can loosen it. Bind-mount your
# own file over this path to replace it.
COPY config/managed-settings.default.json /etc/claude-code/managed-settings.json

COPY bin/ /usr/local/bin/
COPY docker-entrypoint.d/ /docker-entrypoint.d/
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/init-firewall.sh \
             /usr/local/bin/install-mcp-servers.sh \
             /usr/local/bin/claude-run.sh \
             /docker-entrypoint.d/*.sh

RUN mkdir -p /home/node/.claude /workspace \
 && chown -R node:node /home/node/.claude /workspace

WORKDIR /workspace

# Entrypoint does privileged setup then drops to node and execs CMD.
# Downstream sets CMD to its own worker. Do not override the entrypoint;
# drop scripts into /docker-entrypoint.d/ instead.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
