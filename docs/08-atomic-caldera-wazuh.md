# Chunk 8 — Atomic Red Team, CALDERA, and pfSense → Wazuh

This chunk wires blue-team telemetry and gives you ready red-team signals.

## Steps
```powershell
# 1) Expose Wazuh manager for agents
pwsh -File .\scripts\expose-wazuh-manager.ps1

# 2) Set WINDOWS_VICTIM_IP in .env
# 3) Bootstrap telemetry, agents, Atomic, CALDERA
pwsh -File .\scripts\telemetry-bootstrap.ps1
```

### What it does

- pfSense sends logs to the ContainerHost (rsyslog), which forwards them to Wazuh via the Wazuh agent on the ContainerHost.
- The Windows victim sends logs directly to Wazuh via the Windows agent.
- **Atomic Red Team** runs a handful of safe tests (with cleanup).
- The **CALDERA Sandcat** agent installs and phones home; you can run a small operation from the UI if desired.

### URLs

- **Wazuh:** `https://wazuh.lab.local`
- **CALDERA:** `https://caldera.lab.local`
- **Nessus:** `https://nessus.lab.local:8834` (from Chunk 7/7B). If your pfSense UI or CALDERA agent paths differ, adjust the role URLs accordingly.

