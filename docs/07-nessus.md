# Chunk 7 — Nessus Essentials on k3s

We run the official Tenable Nessus container in the `soc` namespace and expose it
via a LoadBalancer at `172.22.10.61:8834` with a hosts entry for `nessus.lab.local`.

## Deploy
```powershell
pwsh -File .\scripts\deploy-nessus-essentials.ps1
kubectl -n soc get pods -w
```

### Usage

1. Open `https://nessus.lab.local:8834`.
2. Select **Nessus Essentials**, enter or obtain an activation code, and create the admin user.
