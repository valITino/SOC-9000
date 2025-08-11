# Chunk 4 — Platform TLS & first workloads

This chunk:
- Sets Traefik as a **LoadBalancer** with fixed IP `172.22.10.60` (MetalLB).
- Installs a default TLS cert (our wildcard `*.lab.local`) via a Traefik **TLSStore**.
- Deploys **Caldera** (namespace `soc`), **DVWA** (`victim`), and **Kali CLI** (`red`).
- Updates Windows **hosts** for clean URLs.

## Apply
```powershell
pwsh -File .\scripts\gen-ssl.ps1
pwsh -File .\scripts\apply-k8s.ps1
```

### URLs

- `https://caldera.lab.local` (login: `admin`/`admin`)
- `https://dvwa.lab.local`
- `https://portainer.lab.local:9443` (once the Portainer LoadBalancer IP appears, check with `kubectl -n portainer get svc portainer`)
