# VM + Hermes + Composio setup

End-to-end runbook for provisioning the single cloud box that runs Hermes
(gateway + API server) and the doit runner.

> One VM total, not one per user. Each user is a **Hermes profile**.

## 1. Provision the VM

Pick a provider — Hetzner (cheapest) or DigitalOcean (friendliest UI). Specs:

- Ubuntu 22.04 or 24.04 LTS
- ~4 GB RAM, 2 vCPU
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
COMPOSIO_API_KEY=ak_... ~/composio-session-venv/bin/python - <<'PY'
from composio import Composio

session = Composio().create(user_id="<supabase-user-uuid>")
print(session.mcp.url)
print(session.mcp.headers)
PY
```

Paste `session.mcp.url` and `session.mcp.headers` into the profile
`config.yaml` template below. Do not use the static `connect.composio.dev/mcp`
URL for this app; it does not carry the per-user session context.

You won't connect any apps yet — that happens per user once the iOS app is
running.

## 5. Onboard a user (create their Hermes profile)

For each friend, do this once on the VM. Using `alice` as the example name.

```bash
# 1. Create the profile
hermes profile create alice

# 2. Generate a random API server key for the runner -> Hermes auth
API_KEY=$(openssl rand -hex 32)
echo "API key for alice: $API_KEY"   # save this; you'll insert it into Supabase too

# 3. Copy template config + env
PROFILE_DIR=~/.hermes/profiles/alice
cp /path/to/repo/hermes/profiles/_template/config.yaml "$PROFILE_DIR/config.yaml"
cp /path/to/repo/hermes/profiles/_template/.env.example "$PROFILE_DIR/.env"
cp /path/to/repo/hermes/profiles/_template/SOUL.md "$PROFILE_DIR/SOUL.md"

# 3b. Edit config.yaml and replace the Composio MCP placeholders with
#     session.mcp.url and session.mcp.headers from step 4 above.
#
# 3c. If this profile was created after `hermes setup --portal`, make sure it
#     has the same Nous model routing as ~/.hermes/config.yaml. A minimal block:
python3 - <<'PY'
from pathlib import Path
p = Path.home() / ".hermes/profiles/alice/config.yaml"
s = p.read_text()
if not s.lstrip().startswith("model:"):
    p.write_text(
        "model:\n"
        "  default: anthropic/claude-opus-4.6\n"
        "  provider: nous\n"
        "  base_url: https://openrouter.ai/api/v1\n\n"
        + s
    )
PY

# 4. Edit ~/.hermes/profiles/alice/.env and fill in:
#       API_SERVER_PORT=8643   (unique per user)
#       API_SERVER_KEY=<the API_KEY you just generated>
#       COMPOSIO_API_KEY=ck_...
#       COMPOSIO_ENTITY_ID=<alice's Supabase user uuid>

# 5. Start the gateway under systemd so it auto-restarts
sudo tee /etc/systemd/system/hermes-alice.service >/dev/null <<EOF
[Unit]
Description=Hermes gateway for alice
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=/usr/local/bin/hermes -p alice gateway run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hermes-alice
```

Verify the API server is up:

```bash
curl -s http://127.0.0.1:8643/health -H "Authorization: Bearer $API_KEY"
# -> {"status":"ok"}
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
  conversations (FTS5 over `state.db`).

Verify built-in memory is enabled after creating the profile:

```bash
hermes -p <profile> memory status
# Expect: built-in MEMORY.md + USER.md active, no external provider required.
```

The template `config.yaml` in this repo sets `memory.memory_enabled: true` and
`memory.user_profile_enabled: true` explicitly so the behavior is obvious to
anyone reading the profile.

How this lines up with the app:

- The Doit runner uses a stable per-user Hermes `session_id` (`doit-user-<uuid>`)
  for every `/v1/runs` call, so the agent's memory files and session search
  span all of the user's todos instead of resetting per task.
- The runner mirrors `memories/USER.md` and `memories/MEMORY.md` into the
  Supabase `memories` table after every run, so Settings > Memory shows what
  Hermes has actually learned.
- When the user adds or edits a memory in the app, the runner writes that
  entry into the matching Hermes file before the next run so it lands in the
  next frozen snapshot.
- We are not enabling an external memory provider (Mem0, Honcho, etc.) in
  this phase; built-in memory + session search is the source of truth.

## 6. Insert the user_hermes mapping into Supabase

From the Supabase SQL editor (uses service_role):

```sql
insert into user_hermes (user_id, profile_name, api_port, api_key, composio_entity)
values (
  '<alice-supabase-user-uuid>',
  'alice',
  8643,
  '<the API_KEY from step 5>',
  '<alice-supabase-user-uuid>'
);
```

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
# OPENAI_API_KEY=sk-proj-...
# ANTHROPIC_API_KEY=sk-ant-...
#
# If the runner user needs sudo to restart per-user Hermes services, allow only
# the hermes-* restart command in sudoers, then keep:
# HERMES_RESTART_COMMAND_TEMPLATE=sudo systemctl restart hermes-{profile}
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

## Onboarding a second user (Bob)

Repeat step 5 with:

- profile name `bob`
- a new random API key
- `API_SERVER_PORT=8644` (or any unused port)
- Bob's Supabase user uuid for `COMPOSIO_ENTITY_ID`

Then insert his `user_hermes` row (step 6) and you're done. The runner picks
up the new mapping on its next poll.
