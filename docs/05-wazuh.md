# Chunk 5 — Wazuh on k3s

This chunk deploys the Wazuh stack (indexer, manager, dashboard) into namespace `soc`,
fronted by Traefik with TLS and a friendly hostname.

## Deploy
```powershell
pwsh -File .\scripts\wazuh-vendor-and-deploy.ps1
kubectl get pods -n soc -w
```

### Access

- URL: `https://wazuh.lab.local`
- Default login: `admin` / `SecretPassword`

### Notes

- The official `wazuh-kubernetes` repository (tag **v4.12.0**) is vendored under `third_party/`.
- Certificates are generated with the upstream scripts and loaded via `secretGenerator`.
- The ingress configuration points `wazuh.lab.local` at Traefik (already a LoadBalancer with TLS from earlier chunks).
