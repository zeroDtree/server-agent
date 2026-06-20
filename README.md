# server-agent

GPU host agents for gsad: account provisioning and GPU metrics reporting.

| Agent | Role |
|-------|------|
| [account-provisioner](account-provisioner/) | Polls grant/revoke tasks, runs `isolation/` scripts |
| [gpu-server-report](gpu-server-report/) | `nvidia-smi` metrics → gsad report API |

Production uses **systemd on the GPU host** (not Docker). Provisioner needs host `sudo`, `DATA_ROOT`, NetBird, and the `isolation` submodule.

Keep the clone at a **stable path**; re-run `install.sh` after moving it.

## Install

```bash
git clone --recursive git@github.com:zeroDtree/server-agent.git server-agent && cd server-agent

sudo REPORT_API_URL=https://api.example \
     AGENT_PSK=your-psk \
     AGENT_SERVER_ID=gpu-node-01 \
     ./deploy/install.sh
```

Installer writes systemd units pointing at this repo, ensures `deploy/env/*.env`, runs `uv sync`.

On upgrade: set `REPORT_API_URL` in `deploy/env/common.env` (rename from legacy `GSAD_API_URL`), then re-run `install.sh`.

| File | Purpose |
|------|---------|
| `deploy/env/common.env` | `REPORT_API_URL`, `AGENT_PSK`, `AGENT_SERVER_ID` |
| `deploy/env/provisioner.env` | `DATA_ROOT`, `PROVISION_*`, health `:9091` |
| `deploy/env/reporter.env` | `AGENT_REPORT_INTERVAL`, health `:9092` |

## Operations

```bash
sudo systemctl restart gsad-account-provisioner gsad-gpu-server-report
journalctl -u gsad-account-provisioner -u gsad-gpu-server-report -f
git pull && git submodule update --init --recursive && sudo ./deploy/install.sh
sudo ./deploy/uninstall.sh --purge    # remove units and deploy/env/*.env
```

Health: `http://127.0.0.1:9091/health` (provisioner), `:9092` (reporter). Set `AGENT_HEALTH_PORT=0` to disable.

## Development

```bash
cd account-provisioner && uv sync && cp .env.example .env && uv run python provision_loop.py
cd gpu-server-report   && uv sync && cp .env.example .env && uv run python reporter.py
```

See component READMEs for API and CLI details.
