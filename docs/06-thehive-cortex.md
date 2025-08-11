# Chunk 6 — TheHive + Cortex on k3s

Installs TheHive and Cortex via Helm, exposes them behind Traefik with TLS,
and provides RWX storage (NFS provisioner) for Cortex analyzer jobs.

## Apply
```powershell
pwsh -File .\scripts\install-rwx-storage.ps1
pwsh -File .\scripts\install-thehive-cortex.ps1
pwsh -File .\scripts\storage-defaults-reset.ps1   # optional
kubectl get pods -n soc -w
```

### URLs

- `https://thehive.lab.local`
- `https://cortex.lab.local`

### Post‑install

1. In **Cortex**, create an admin user and generate an API key.
2. In **TheHive**, navigate to **Admin → Cortex** and add a new Cortex connection with:
   - **URL:** `http://cortex.soc.svc:9001`
   - **API key:** (the key you created in Cortex)
3. Run a test analyzer from a case or observable to validate the integration.
