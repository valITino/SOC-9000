# Chunk 9 — Orchestration & Final Docs

## One-command bring-up
```powershell
make up-all
```

This runs: host prep → Packer images → network wiring → netplan → pfSense config + k3s/MetalLB/Portainer → TLS → base apps → Wazuh → TheHive + Cortex → Nessus (container or VM) → telemetry bootstrap → hosts refresh → status.

    pfSense base install is still manual once; the script pauses for you and continues with auto-config.

Tear down (stop VMs)
```powershell
make down-all
```

Status & URLs
```powershell
make status
```

Troubleshooting

    Hosts not resolving → pwsh -File scripts/hosts-refresh.ps1

    Traefik has no IP → ensure MetalLB is running and MGMT pool is not exhausted.

    Wazuh agents not connecting → confirm wazuh-manager-lb has IP and ports 1514/1515 open.

    TheHive⇄Cortex → verify Cortex API key and URL http://cortex.soc.svc:9001.

    Nessus (container) reset → container is ephemeral by design. Use Chunk 7B VM for persistence.
