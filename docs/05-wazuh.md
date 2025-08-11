# Chunk 5 — Wazuh on k3s

This chunk deploys the Wazuh stack (indexer, manager, dashboard) into namespace `soc`,
fronted by Traefik with TLS and a friendly hostname.

## Deploy
```powershell
pwsh -File .\scripts\wazuh-vendor-and-deploy.ps1
kubectl get pods -n soc -w
```

Access

    URL: https://wazuh.lab.local

    Default login: admin / SecretPassword

Notes

    We vendor the official wazuh-kubernetes repo (tag v4.12.0) under third_party/.

    Certificates are generated with the upstream scripts and loaded via secretGenerator.

    Ingress points wazuh.lab.local to Traefik (already LB + TLS from earlier chunks).
