# Chunk 10 — Backups, Reset & Smoke Test

## Backup

Run the backup script to create a timestamped snapshot:

```powershell
pwsh -File .\scripts\backup-run.ps1
```

This command creates a ZIP archive in `BACKUP_DIR` (default: `E:\SOC-9000\backups`) and trims old files according to `SNAPSHOT_RETENTION`.

The ZIP contains:

- `cluster-version.yaml`, `namespaces.yaml`, `resources.yaml`
- `secrets-list.json` (only names and types)
- `cluster-storage.tgz` (PV data from local‑path and NFS, if present)

To restore a lab from a backup, bring the cluster back up with `pwsh -File .\scripts\lab-up.ps1`, review `resources.yaml` to re‑apply any deltas, and extract `cluster-storage.tgz` to repopulate data on the ContainerHost if needed.

## Reset

To perform a **soft reset** (purge application namespaces and re‑apply workloads):

```powershell
pwsh -File .\scripts\reset-lab.ps1
```

To perform a **hard reset** that also wipes persistent volume data on the ContainerHost:

```powershell
pwsh -File .\scripts\reset-lab.ps1 -Hard
```

## Smoke Test

Verify basic reachability of the main URLs:

```powershell
pwsh -File .\scripts\smoke-test.ps1
```

This script performs `HEAD` requests against each service URL and reports the HTTP status codes.

