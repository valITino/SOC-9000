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

What it does

    pfSense → ContainerHost (rsyslog) → Wazuh using the Wazuh agent on the ContainerHost.

    Windows Victim → Wazuh via the Windows agent.

    Atomic Red Team runs a handful of safe tests (with cleanup).

    CALDERA Sandcat agent installs and phones home; run a small operation from the UI if desired.

URLs

    Wazuh: https://wazuh.lab.local

    CALDERA: https://caldera.lab.local

    Notes: Nessus (Chunk 7/7B) remains available at https://nessus.lab.local:8834. If your pfSense UI or CALDERA agent paths differ, adjust the role URLs accordingly.

