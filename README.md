# claude-in-docker

Claude Code in a container, set up for unattended use on a server: long-lived
auth, default-deny egress, a permission floor that a prompt-injected session
cannot loosen, and a headless job runner with meaningful exit codes.

No business logic. Supply own CMD and the prompts.

Use to run Claude Code unattended on a VPS, where it reads untrusted input and nobody is watching. 

Defaults:

- **Auth survives the night.** On headless Linux there is a documented
  failure where a container holding a valid refresh token returns 401 rather
  than refreshing once the access token expires, with no recovery path without
  a human running `/login`. A long-lived token from `claude setup-token` skips
  the refresh path entirely.
- **Egress is restricted.** Host `ufw` rules do not filter
  container traffic; Docker inserts its own rules ahead of them. The firewall
  here runs inside the container's network namespace, and is on by default.
- **A permission floor.** `/etc/claude-code/managed-settings.json` is read at
  the highest precedence on Linux, above anything in `~/.claude` or a project's
  `.claude/`. That is where deny rules belong when the agent's input is
  untrusted.
- **Config that persists.** `~/.claude.json` normally lives *outside*
  `~/.claude`, so mounting one directory does not keep you signed in.
  `CLAUDE_CONFIG_DIR` moves it inside.

## Quick start

```bash
mkdir -p data/claude-home data/logs workspace config
cp .env.example .env && chmod 600 .env

# This will require browser and sign-in to your Claude acct:
claude setup-token           # -> sk-ant-oat01-..., paste into .env

cp compose.example.yml compose.yml
docker compose build
docker compose run --rm console claude -p "hi" --output-format json
```

## Using it as a base

Two supported extension points. Both avoid forking the image.

**CMD** is yours. The entrypoint does privileged setup, drops to `node`, and
execs whatever you pass:

```yaml
services:
  worker:
    image: ghcr.io/rulikkk/claude-in-docker
    command: ["python3", "/app/worker.py"]
    volumes:
      - ./app:/app:ro
```

**`/docker-entrypoint.d/*.sh`** runs as root, sorted, before privileges drop.
Mount extra scripts there for setup the base image cannot know about.

Do not override `ENTRYPOINT`. That is what applies the firewall and the uid
alignment.

## Configuration

Everything is a bind mount, so you can inspect and back up state directly.

| Path | Purpose |
|---|---|
| `/home/node/.claude` | login, per-project trust, session transcripts |
| `/config/firewall-allow.txt` | extra egress domains, one per line |
| `/config/mcp-servers.txt` | `claude mcp add` commands, applied on demand |
| `/config/claude-home/CLAUDE.md` | seeded into the volume each start |
| `/config/claude-home/settings.json` | seeded into the volume each start |
| `/etc/claude-code/managed-settings.json` | permission floor; mount over to replace |
| `/data/logs` | one `.jsonl` per headless run |

Key env vars: `CLAUDE_CODE_OAUTH_TOKEN`, `PUID`/`PGID`, `ENABLE_FIREWALL`,
`FIREWALL_ALLOW_DOMAINS`, `FIREWALL_ALLOW_SUBNET`, `FIREWALL_REFRESH_SECONDS`,
`CLAUDE_PERMISSION_MODE`, `CLAUDE_ALLOWED_TOOLS`, `DISABLE_REMOTE_CONTROL`.
See `.env.example`.

`claude-run.sh` also recognizes these opt-in vars, all off/unset by default:

- `CLAUDE_NO_SESSION_PERSISTENCE` — set to add `--no-session-persistence`, so
  the run's transcript is not written to the mounted claude-home.
- `CLAUDE_RESTRICTED` — set to add `--restricted`, dropping Bash/code-exec
  tools and confining file tools to the working directory.
- `CLAUDE_MAX_BUDGET_USD` — dollar amount (e.g. `2.00`); caps spend on that
  single headless run via `--max-budget-usd`.
- `CLAUDE_FALLBACK_MODEL` — comma-separated model list; passed to
  `--fallback-model` so transient overload on the primary model doesn't fail
  the run outright.

### Remote Control

`DISABLE_REMOTE_CONTROL` (default `1`) is the one switch. On, it forces
`DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` all to `1` — the last of those
also turns off feature-flag evaluation, which is what actually breaks RC.
Off (`0`), `entrypoint.sh` forces all four back to `0`.

Only one login method can drive a Remote Control session: a full interactive
`/login`. A `claude setup-token` credential (`CLAUDE_CODE_OAUTH_TOKEN`) makes
model requests but cannot start RC. If `DISABLE_REMOTE_CONTROL=0` and
`CLAUDE_CODE_OAUTH_TOKEN` is also set, the entrypoint logs a warning — run
`claude` interactively in that container instead.

## claude-run.sh

Runs one headless job and classifies the result, because 401 and 429 both look
like a nonzero exit:

```
claude-run.sh <prompt-file> [log-dir]

0   success
10  rate limited      -> defer until reset, retry
11  auth failed       -> stop, do not retry, alert a human
1   other             -> backoff, then fail the job
```

Prints `session_id=<uuid>` so a caller can store it and later
`claude --resume <uuid>` to continue that context interactively. The id is
pre-generated (via `/proc/sys/kernel/random/uuid`, falling back to `python3`)
and passed to `claude` with `--session-id`, rather than relying solely on
parsing it back out of the stream-json log after the fact.

## MCP servers

Put `claude mcp add ...` lines in `config/mcp-servers.txt`, then:

```bash
docker compose run --rm console install-mcp-servers.sh
docker compose run --rm console claude    # once, to complete /mcp OAuth
```

Add each server's domain to `config/firewall-allow.txt` first, or it will not
be reachable.

## Caveats

- The firewall resolves domains to addresses. Behind a CDN those rotate; set
  `FIREWALL_REFRESH_SECONDS` for long-running containers. The refresher is a
  background process, and if it dies the last-applied rules stay in force.
- `ENABLE_FIREWALL=0` is a real setting with a real consequence. It logs loudly.
- Missing `NET_ADMIN`/`NET_RAW` fails the container at boot rather than starting
  it unrestricted.
- The permission floor limits Claude's *tools*. It is not a sandbox for
  arbitrary code Claude writes and runs. Pair it with the firewall.
- A long-lived token is a bearer credential sitting in `.env`. `chmod 600`, and
  keep it out of any backup that leaves the machine. It expires in a year.
