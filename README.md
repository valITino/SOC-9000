# SOC-9000

A pfSense-routed, k3s-managed SOC lab on VMware Workstation 17 Pro (Windows 11).

**VMs:** pfSense (edge), ContainerHost (k3s+Portainer+Traefik+MetalLB), Windows victim, optional Nessus VM.  
**Apps:** Wazuh, TheHive, Cortex, CALDERA, DVWA, Kali (CLI), Nessus Essentials.

## Quickstart
```powershell
git clone <repo-url> E:\SOC-9000\SOC-9000
cd E:\SOC-9000\SOC-9000
make init             # creates .env — edit it
make up-all           # end-to-end bring-up (VMs, k3s, apps, telemetry)
make status           # show IPs/URLs

    First-time: you still perform a short manual pfSense install (Chunk 3), then the scripts auto-configure it.

URLs (after make up-all)

    https://portainer.lab.local:9443

    https://wazuh.lab.local

    https://thehive.lab.local

    https://cortex.lab.local

    https://caldera.lab.local

    https://dvwa.lab.local

    https://nessus.lab.local:8834 (container or VM)

Topology

flowchart LR
  INET(Internet) --> VMnet8[VMnet8 NAT]
  VMnet8 --> PFS[pfSense]
  subgraph Segments
    PFS ---|VMnet20| MGMT[172.22.10.0/24]
    PFS ---|VMnet21| SOC[172.22.20.0/24]
    PFS ---|VMnet22| VICTIM[172.22.30.0/24]
    PFS ---|VMnet23| RED[172.22.40.0/24]
  end
  CH[(ContainerHost\nk3s+Portainer+Traefik+MetalLB)] --- MGMT
  CH --- SOC
  CH --- VICTIM
  CH --- RED
  WIN[(Windows Victim)] --- VICTIM
  NESSUS[(Nessus VM - optional)] --- SOC
  subgraph k3s Apps
    WZ[Wazuh]:::svc
    TH[TheHive]:::svc
    CX[Cortex]:::svc
    CA[CALDERA]:::svc
    DV[DVWA]:::svc
    KL[Kali CLI]:::svc
  end
  classDef svc fill:#eef,stroke:#66f
  CH -->|Ingress/TLS| WZ & TH & CX & CA & DV & KL

Docs

See docs/00-prereqs.md → 08-atomic-caldera-wazuh.md. This repo is chunked so you can run pieces or the whole thing.
