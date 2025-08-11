# Chunk 9 — Orchestration & Final Docs

## One‑command bring‑up

To bring up the entire lab in one go, run:

```powershell
make up-all
```

The `make up-all` target performs these steps in order:

1. Host preparation and ISO checks.
2. Build the base images with Packer.
3. Wire VMX networks and assign static MAC addresses.
4. Apply a netplan to the ContainerHost.
5. Pause for the manual pfSense install, then automatically configure pfSense, k3s, MetalLB, and Portainer.
6. Generate TLS certificates, bootstrap Traefik and platform apps.
7. Deploy Wazuh.
8. Install TheHive and Cortex (with RWX storage).
9. Deploy Nessus (container or VM depending on `.env`).
10. Expose the Wazuh manager for agents and bootstrap telemetry (syslog, agents, Atomic, CALDERA).
11. Refresh host entries and display the status.

**Note:** The pfSense base install remains a one‑time manual step; the script pauses for you and then continues with auto‑configuration.

### Tear down (stop VMs)

```powershell
make down-all
```

### Status & URLs

```powershell
make status
```

### Troubleshooting

- Hosts not resolving → run `pwsh -File scripts/hosts-refresh.ps1`.
- Traefik has no IP → ensure MetalLB is running and that the MGMT pool is not exhausted.
- Wazuh agents not connecting → confirm that `wazuh-manager-lb` has an IP and that ports 1514/1515 are open.
- TheHive↔Cortex issues → verify the Cortex API key and the URL `http://cortex.soc.svc:9001`.
- Nessus (container) resets → the container is intentionally ephermal; use the Chunk 7B VM for persistence.
