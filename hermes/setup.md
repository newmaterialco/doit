# VM + Hermes + Composio setup

End-to-end runbook for provisioning the single cloud box that runs Hermes
(gateway + API server) and the doit runner.

> One VM total, not one per user. Each user is a **Hermes profile**.

## 1. Provision the VM

Pick a provider — Hetzner (cheapest) or DigitalOcean (friendliest UI). Specs:

- Ubuntu 22.04 or 24.04 LTS
- ~4 GB RAM, 2 vCPU for 1-5 users; resize to **8-16 GB RAM / 4 vCPU**
  before opening invite codes to 50-100 users (each user runs a Hermes
  gateway process — measure per-gateway RSS with the first few real users
  to validate headroom)
- 40 GB disk
- A non-root sudo user

SSH in and install basics:

```bash
sudo apt update && sudo apt install -y python3-venv python3-pip curl ufw
```

Lock down inbound: only SSH. The runner is outbound-only (Supabase, APNs,
loopback to Hermes), so no public port is required.

```bash
sudo ufw allow ssh && sudo ufw --force enable
```

## 2. Install Hermes

```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

Verify: `hermes --version`.

## 3. Connect a model + built-in tools via Nous Portal

```bash
hermes setup --portal
```

This handles OAuth in a browser (use SSH port-forward if you're SSH'd in, or
follow the paste-back instructions Hermes prints). One subscription covers the
LLM plus Hermes' built-in web / image / TTS / browser tools.

### Browserbase + browse.sh browser automation

Doit uses Browserbase for managed cloud browser sessions and browse.sh for
site-specific browser skills. Add your Browserbase credentials to the runner
`.env` first:

```bash
cd /path/to/repo/runner
read -rsp 'BROWSERBASE_API_KEY: ' BROWSERBASE_API_KEY; echo
read -rsp 'BROWSERBASE_PROJECT_ID: ' BROWSERBASE_PROJECT_ID; echo
{
  printf '\n# Browserbase (Hermes browser automation + browse.sh CLI)\n'
  printf 'BROWSERBASE_API_KEY=%s\n' "$BROWSERBASE_API_KEY"
  printf 'BROWSERBASE_PROJECT_ID=%s\n' "$BROWSERBASE_PROJECT_ID"
} >> .env
unset BROWSERBASE_API_KEY BROWSERBASE_PROJECT_ID
```

Then copy those keys into the global Hermes env file. Hermes gateways read
`~/.hermes/.env`; profile `.env` files are only for per-profile overrides.

```bash
cd /path/to/repo
python3 hermes/scripts/sync_browserbase_env.py --restart
```

Install the browser CLIs Hermes will use. `browse` is the Browserbase-backed CLI
referenced by browse.sh skills; `agent-browser` is Hermes' local sidecar for
private/loopback URLs when hybrid routing is enabled.

```bash
# Node.js 20+ if not already present
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Optional but useful for private-URL hybrid routing through agent-browser.
sudo apt install -y chromium-browser || true

npm install -g browse
npm install -g agent-browser

browse --version
agent-browser --version
```

Smoke-test Browserbase from a shell by sourcing the same env file Hermes reads.
Stop any existing browse daemon first so it restarts with the Browserbase
environment:

```bash
set -a; . ~/.hermes/.env; set +a
browse stop --force || true
browse open https://example.com --remote --timeout 45000
browse get title --remote
browse stop --force
```

Install the bundled `browse` CLI skill and Doit's browse.sh library guidance
skill. The Doit runner deploy script copies `hermes/skills/` to the VM and
installs those bundled skills into `~/.hermes/skills`, but first-time setup can
do it manually too:

```bash
# Generic browse CLI guidance (creates ~/.agents/skills/browse, symlinked by
# current Hermes installs into ~/.hermes/skills/browse).
browse skills install

mkdir -p ~/.hermes/skills
rsync -av /opt/doit/hermes/skills/ ~/.hermes/skills/
```

Install site-specific browse.sh skills with Doit's bridge instead of the broken
`hermes skills install browse-sh/...` source. It discovers catalog matches,
downloads the skill files, writes them into `~/.hermes/skills/<skill-name>/`,
and returns JSON for automation:

```bash
python3 /opt/doit/hermes/scripts/sync_browse_skill.py --query "cheap flights SFO JFK"
python3 /opt/doit/hermes/scripts/sync_browse_skill.py --slug google.com/search-flights-ts4g1f
```

Verify a profile exposes the expected tools after its config is copied and the
gateway restarts:

```bash
hermes -p <profile> tools list | grep -E 'browser|terminal|skills|delegation'
hermes skills list | grep -E 'browse|browse-sh-library|search-flights|browserbase'
```

The template enables Hermes' `browser` and `terminal` toolsets so the agent can
use native `browser_*` tools and execute `browse` CLI commands from browse.sh
skills. This is a meaningful security expansion: keep Hermes running as an
unprivileged user, keep profile `.env` files mode `600`, monitor Browserbase
session usage, and avoid adding delegation or broad filesystem access without a
separate review.

## 4. Create a Composio account

1. Sign up at <https://composio.dev> and grab your API key from the dashboard.
2. Save it: it goes into each user's profile `.env` and into the Supabase Edge
   Function as a secret.

Composio v3 uses sessions as the runtime boundary. The Supabase Edge Function
uses the backend project API key. Hermes should use a per-user session MCP URL
and headers generated from that same key:

```bash
python3 -m venv ~/composio-session-venv
~/composio-session-venv/bin/pip install composio
COMPOSIO_API_KEY=YOUR_COMPOSIO_API_KEY ~/composio-session-venv/bin/python - <<'PY'
from composio import Composio

# Keep in sync with supabase/functions/integrations/index.ts CATALOG and
# runner/runner/prepare.py CONNECTION_SLUGS.
TOOLKITS = [
    "gmail", "googlecalendar", "googledrive", "googledocs", "googlesheets",
    "slack", "notion", "linear", "github", "reddit", "hunter", "linkedin", "figma",
]

session = Composio().create(
    user_id="<supabase-user-uuid>",
    toolkits={"enable": TOOLKITS},
)
print(session.mcp.url)
print(session.mcp.headers)
PY
```

Paste `session.mcp.url` and `session.mcp.headers` into the profile
`config.yaml` template below. Do not use the static `connect.composio.dev/mcp`
URL for this app; it does not carry the per-user session context.

> **Adding a new integration later:** regenerate the session with the updated
> `TOOLKITS` list above, paste the new MCP URL/headers into the user's
> `config.yaml`, and restart their Hermes gateway (`sudo systemctl restart
> hermes@<profile>`). The iOS Connections sheet only handles OAuth; Hermes
> only sees toolkits that were enabled when the Composio session was created.
> The provisioner's toolkit list lives in `runner/runner/provision.py` —
> keep all three in sync.

You won't connect any apps yet — that happens per user once the iOS app is
running.

### Figma: Composio today, official MCP later

Doit currently enables Figma through the Composio `figma` toolkit. That path is
good for connected-account file/resource access: discover Figma resources, read
known files and nodes, render/download image exports, inspect styles/tokens, and
comment where Composio exposes those actions.

Figma's official remote MCP server (`https://mcp.figma.com/mcp`) is more
powerful: it exposes tools such as `use_figma`, `upload_assets`,
`create_new_file`, `get_design_context`, `get_screenshot`, `search_design_system`,
and Code Connect-related tools. Those can support native canvas editing and
design-system-aware workflows once authenticated.

Do not add the official Figma MCP URL directly to a Hermes profile yet. A direct
spike with:

```yaml
mcp_servers:
  figma:
    url: https://mcp.figma.com/mcp
```

started successfully but Hermes logged `401 Unauthorized` from Figma and did not
surface a usable OAuth flow. Figma currently documents the remote MCP server for
supported MCP clients such as Cursor, VS Code, Claude Code, and Codex. To use it
from Doit/Hermes, first add one of:

- native Hermes support for Figma MCP OAuth, or
- a small authenticated bridge MCP service that connects to Figma and exposes a
  Hermes-compatible endpoint.

Until then, keep the Composio Figma integration enabled and have Hermes return
durable Doit `image` artifacts for screenshots/exports instead of raw temporary
Figma image URLs.

## 5. Onboard a user (automated — mint an invite code)

Per-user onboarding is automated. Mint an invite code in the Supabase SQL
editor (see `../supabase/README.md`), give it to the user, and the
provisioner loop inside the runner does everything the old manual runbook
did: Hermes profile from `hermes/profiles/_template/`, model block, Composio
v3 session, unique API port, generated `API_SERVER_KEY`, systemd unit,
health check, and the `user_hermes` row.

One-time prerequisites on the VM:

1. **Install the `hermes@.service` template unit** (replaces hand-written
   per-user units; also migrates any existing `hermes-<profile>` units):

   ```bash
   sudo /opt/doit/scripts/install-hermes-template-unit.sh
   ```

   The template lives at `hermes/systemd/hermes@.service`; instances are
   `hermes@<profile>`. If the runner runs as a non-root user, pass
   `RUNNER_USER=<user>` to also install the scoped sudoers entry from
   `hermes/systemd/doit-hermes.sudoers` (allows only
   `systemctl start|stop|restart|enable|disable|is-active hermes@*`).

2. **Runner env** (`/opt/doit/runner/.env`): set `COMPOSIO_API_KEY`,
   and check `PROVISIONER_ENABLED`, `MAX_PROVISIONED_USERS`,
   `HERMES_PORT_RANGE_START`, and the `HERMES_MODEL_*` defaults
   (see `runner/.env.example`).

Manual repair path, if a user's provisioning fails and the in-app retry
doesn't clear it:

```bash
cd /opt/doit/runner
.venv/bin/python -m runner.provision_cli --user-id <supabase-user-uuid>
```

Verify a provisioned gateway by hand:

```bash
# port + key are in the user's user_hermes row / profile .env
curl -s http://127.0.0.1:<port>/health -H "Authorization: Bearer <API_SERVER_KEY>"
# -> {"status":"ok"}
systemctl is-active hermes@user_a1b2c3d4
```

### Profile memory notes

Hermes ships with built-in persistent memory and we rely on it directly — no
external provider yet.

- `~/.hermes/profiles/<profile>/memories/USER.md` — user profile (preferences,
  identity, communication style). Default cap ~1,375 chars.
- `~/.hermes/profiles/<profile>/memories/MEMORY.md` — agent notes
  (environment facts, project conventions, lessons learned). Default cap
  ~2,200 chars.
- `~/.hermes/profiles/<profile>/SOUL.md` — assistant persona/profile
  instructions (does not change between sessions).
- Both memory files are loaded as a frozen snapshot into the system prompt at
  every session start. The agent curates them with the `memory` tool
  (`add`/`replace`/`remove`).
- The agent can also call `session_search` to find content from prior
  conversations (FTS5 over `state.db`). This is what gives cross-todo recall
  without needing a single long-lived session.

Verify built-in memory is enabled after creating the profile:

```bash
hermes -p <profile> memory status
# Expect: built-in MEMORY.md + USER.md active, no external provider required.
```

The template `config.yaml` in this repo sets `memory.memory_enabled: true` and
`memory.user_profile_enabled: true` explicitly so the behavior is obvious to
anyone reading the profile.

How this lines up with the app:

- The Doit runner uses a **per-todo** Hermes `session_id`
  (`doit-todo-<todo-uuid>` for execution, `doit-prep-<todo-uuid>` for the
  preparation pass). This is intentional: Hermes' docs are explicit that
  `USER.md` and `MEMORY.md` are injected as a *frozen* snapshot at session
  start and never refreshed mid-session. A new session per todo means the
  next run always sees the latest memory writes (the agent's own
  `memory.add(...)` calls *and* anything the runner just staged from
  Settings > Memory).
- Cross-todo recall still works: `session_search` queries every prior
  session in the profile's `state.db`, independent of the active
  `session_id`. The memory files themselves are per-profile and persist
  across all sessions.
- Each run also forwards a stable per-user
  `X-Hermes-Session-Key: doit-user:<uuid>` header. Hermes uses this to
  scope long-term memory providers (Honcho, Mem0, …) independently of the
  transcript-scoped `session_id`. We send it from day one so memory stays
  per-user once an external provider is enabled.
- The runner mirrors `memories/USER.md` and `memories/MEMORY.md` into the
  Supabase `memories` table after every run, so Settings > Memory shows
  what Hermes has actually learned.
- When the user adds or edits a memory in the app, the runner writes that
  entry into the matching Hermes file before the next run *and* surfaces
  the entry in that run's prompt so the agent curates it via its own
  `memory` tool (dedupe, replace older notes, etc.).
- We are not enabling an external memory provider (Mem0, Honcho, etc.) in
  this phase; built-in memory + `session_search` is the source of truth.

### Backfilling Settings > Memory from existing profiles

The reverse mirror runs after every todo, so Settings populates itself in
normal operation. For an existing profile that's been chatting with Hermes
before the mirror code shipped, you can backfill manually:

```bash
# From the runner directory on the VM, with the runner venv active.
. .venv/bin/activate
python -m runner.mirror_memory_cli --user-id <doit-user-uuid>
# or do every provisioned user in one go:
python -m runner.mirror_memory_cli --all
```

The CLI reads `~/.hermes/profiles/<profile>/memories/{USER,MEMORY}.md`,
upserts entries it doesn't already know about, and deletes any
`source='hermes'` rows whose fingerprints are gone from disk. It never
deletes user-pinned rows.

Use it as a quick diagnostic for "did Hermes actually remember anything
about me?" without having to run a todo end-to-end.

### Looking ahead: external memory providers (do not enable yet)

The built-in `USER.md` / `MEMORY.md` files default to **4,000 / 8,000
characters** (raised from Hermes' stock ~1,375 / ~2,200). The runner and
each profile's `config.yaml` must agree on `user_char_limit` /
`memory_char_limit`. New profiles pick up the template values; existing
profiles need a one-time patch::

    ./scripts/patch-hermes-memory-limits.sh

Runner env (also in `runner/.env.example`):

    HERMES_USER_CHAR_LIMIT=4000
    HERMES_MEMORY_CHAR_LIMIT=8000

When a file nears capacity, the runner evicts oldest **agent-authored**
entries before user-pinned facts and runs a deterministic near-duplicate
merge pass after each todo mirror. Rows that failed with "memory is full"
can be re-queued once::

    python -m runner.requeue_failed_memories_cli --all

That's plenty for the kind of facts we care about in Phase 1, but
eventually you'll want richer semantic recall (older threads, larger
preference graphs, "find me the doc I shared with X last month") — that's
what Hermes' external providers are for. Add them only after the built-in
path is boring and reliable. The expected upgrade is roughly:

```bash
# pick ONE provider per profile; mem0 is the simplest to set up.
hermes -p <profile> memory setup mem0
# verify it took
hermes -p <profile> memory status
```

When that day comes, keep `USER.md` / `MEMORY.md` as the durable compact
source of critical facts (personal email, default tone, recurring people)
and let the external store handle the long tail. The runner's
`X-Hermes-Session-Key` header is already in place to scope that
external recall per-user, so no code change is required to plug in a
provider — only the profile-level `memory setup` step above.

## 6. user_hermes mapping (automated)

The provisioner upserts the `user_hermes` row (profile name, port, API key,
Composio entity) as the final step of onboarding — no SQL editor needed.
The legacy manual insert still works for emergency repairs:

```sql
insert into user_hermes (user_id, profile_name, api_port, api_key, composio_entity)
values ('<user-uuid>', '<profile>', <port>, '<API_SERVER_KEY>', '<user-uuid>')
on conflict (user_id) do update
  set profile_name = excluded.profile_name,
      api_port = excluded.api_port,
      api_key = excluded.api_key;
```

Note `(api_host, api_port)` is unique — two gateways can never share a port.

## 7. Verify Gmail OAuth end-to-end (optional but recommended)

Before turning the app loose, sanity-check that Composio's OAuth flow works
from a Hermes session for alice:

```bash
# Open an interactive Hermes session for alice (Composio MCP loads on startup)
hermes -p alice chat
```

In the chat, ask:

> Connect my Gmail account and then list my last 3 emails.

Hermes (via Composio's `COMPOSIO_MANAGE_CONNECTIONS` meta-tool) will print an
OAuth URL. Open it in your browser, sign in to Google, approve. Back in chat,
Hermes will continue and list the emails.

If this works, the same flow will work end-to-end from the iOS app — the only
difference is that the URL surfaces as a todo step with `kind = 'oauth_needed'`
and the app opens it with `ASWebAuthenticationSession`.

## 8. Deploy the runner

See `../runner/README.md`. The short version:

```bash
cd /path/to/repo/runner
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # fill in SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, APNS_*
# Also set HERMES_PROFILES_DIR to the profile directory owner, for example:
# HERMES_PROFILES_DIR=/home/doit/.hermes/profiles
# Add Doit's global provider keys here too:
# OPENAI_API_KEY=YOUR_OPENAI_API_KEY
# ANTHROPIC_API_KEY=YOUR_ANTHROPIC_API_KEY
# OPENROUTER_API_KEY=YOUR_OPENROUTER_API_KEY
# Add Browserbase keys, then sync them to ~/.hermes/.env:
# BROWSERBASE_API_KEY=YOUR_BROWSERBASE_API_KEY
# BROWSERBASE_PROJECT_ID=...
# Enable on-demand browse.sh preflight:
# BROWSE_SKILL_AUTO_INSTALL=true
# BROWSE_SKILL_INSTALL_TIMEOUT_SECS=30
#
# If the runner user needs sudo to manage per-user Hermes services, install
# the scoped sudoers entry (RUNNER_USER=<user> install-hermes-template-unit.sh),
# then keep:
# HERMES_RESTART_COMMAND_TEMPLATE=sudo systemctl restart hermes@{profile}
# HERMES_START_COMMAND_TEMPLATE=sudo systemctl enable --now hermes@{profile}
sudo tee /etc/systemd/system/doit-runner.service >/dev/null <<EOF
[Unit]
Description=doit runner
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
EnvironmentFile=$(pwd)/.env
ExecStart=$(pwd)/.venv/bin/python -m runner
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now doit-runner
journalctl -u doit-runner -f   # watch it pick up requested todos
```

To add or rotate the OpenRouter key later without putting it directly in shell
history:

```bash
ssh root@YOUR_VM_IP
cd /opt/doit/runner
cp .env ".env.backup.$(date +%Y%m%d%H%M%S)"
read -rsp 'OPENROUTER_API_KEY: ' OPENROUTER_API_KEY; echo
export OPENROUTER_API_KEY
python3 - <<'PY'
from pathlib import Path
import os

path = Path(".env")
key = os.environ["OPENROUTER_API_KEY"]
lines = path.read_text().splitlines()
out = [line for line in lines if not line.startswith("OPENROUTER_API_KEY=")]
out.append(f"OPENROUTER_API_KEY={key}")
path.write_text("\n".join(out).rstrip() + "\n")
PY
unset OPENROUTER_API_KEY
systemctl restart doit-runner
systemctl status doit-runner --no-pager
```

## Onboarding more users

Mint another invite code (`../supabase/README.md`) and send it over. The
provisioner allocates the next free port, generates a fresh API key, and the
runner picks up the new `user_hermes` mapping on its next poll. The only
hard limit is `MAX_PROVISIONED_USERS` in the runner env — raise it
deliberately as you validate VM capacity.

## Watchdog (run occasionally)

```bash
# gateways down?
systemctl list-units 'hermes@*' --state=failed
# runner alive?
systemctl is-active doit-runner && journalctl -u doit-runner -n 20 --no-pager
```

Plus the SQL watchdog queries in `../supabase/README.md` (stuck
provisioning rows, todos running past their lease).
