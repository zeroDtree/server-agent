# server-agent

GPU host agents for gsad: account provisioning and GPU metrics reporting.

| Agent                                       | Role                                                |
| ------------------------------------------- | --------------------------------------------------- |
| [account-provisioner](account-provisioner/) | Polls grant/revoke tasks, runs `isolation/` scripts |
| [gpu-server-report](gpu-server-report/)     | `nvidia-smi` metrics → gsad report API              |

Production uses **systemd on the GPU host** (not Docker). Provisioner needs host `sudo`, `DATA_ROOT`, and the `isolation` submodule. Grant `serverIp` comes from `hooks/ipv4.sh` (NetBird by default) or `PROVISION_IPV4_CALLBACK`.

Keep the clone at a **stable path**; re-run `install.sh` after moving it.

## Install

```bash
git clone --recursive git@github.com:zeroDtree/server-agent.git server-agent && cd server-agent

sudo REPORT_API_URL=http://10.0.0.1:8080 \
     AGENT_PSK=replace-with-agent-psk \
     AGENT_SERVER_ID=gpu-node-01 \
     ./deploy/install.sh
```

Installer writes systemd units pointing at this repo, merges `deploy/env/*.env` from the matching `*.env.example` files, and runs `uv sync`.

Existing assignments in `deploy/env/*.env` are kept. Keys present in an example but missing from the dest file are added. Any key declared in those examples (including commented `KEY=value` lines) can be set on the install command and is written into each matching env file, including an explicit empty value. `UPSTREAM_API_URL` is optional; the provisioner falls back to `REPORT_API_URL` when it is unset. Restart the units after editing env files by hand.

| File                         | Purpose                                                                                      |
| ---------------------------- | -------------------------------------------------------------------------------------------- |
| `deploy/env/common.env`      | `REPORT_API_URL`, `AGENT_PSK`, `AGENT_SERVER_ID`; optional `UPSTREAM_API_URL`                |
| `deploy/env/provisioner.env` | `DATA_ROOT`, `PROVISION_*`, health `:9091`                                                   |
| `deploy/env/reporter.env`    | `AGENT_REPORT_INTERVAL`, health `:9092`                                                      |

## Upgrade

```bash
git pull && git submodule update --init --recursive && sudo ./deploy/install.sh
```

## Uninstall

```
sudo ./deploy/uninstall.sh --purge    # remove units and deploy/env/*.env
```

##  Restart the agents

```bash
sudo systemctl restart gsad-account-provisioner gsad-gpu-server-report
```
or
```bash
sudo ./deploy/install.sh
```

## Docs

See [account-provisioner/README.md](account-provisioner/README.md) and [gpu-server-report/README.md](gpu-server-report/README.md) for agent-specific options.