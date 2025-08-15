# Chunk 7 — Nessus Essentials on k3s

We run the official Tenable Nessus container in the `soc` namespace and expose it
via a LoadBalancer at `172.22.10.61:8834` with a hosts entry for `nessus.lab.local`.

## Deploy
```powershell
pwsh -File .\scripts\deploy-nessus-essentials.ps1
kubectl -n soc get pods -w
```
Optionally register automatically by creating `k8s/nessus-activation-secret.yaml` and patching the deployment:

```powershell
kubectl apply -f k8s/nessus-activation-secret.yaml
kubectl patch deploy nessus --type merge -p "$(cat k8s/nessus-deployment-patch.yaml)"
```

### Usage

1. Obtain an Essentials or Pro activation code from Tenable.
2. Either set `NESSUS_ACTIVATION_CODE` in `.env` or enter it when prompted by `scripts/nessus-vm-build-and-config.ps1`.
3. Open `https://nessus.lab.local:8834` and complete initial setup if not auto-registered.
