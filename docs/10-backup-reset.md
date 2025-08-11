# Chunk 10 — Backups, Reset & Smoke Test

## Backup
```powershell
pwsh -File .\scripts\backup-run.ps1

Creates a timestamped ZIP in BACKUP_DIR (default E:\SOC-9000\backups), trims old files per SNAPSHOT_RETENTION.

What’s inside

    cluster-version.yaml, namespaces.yaml, resources.yaml

    secrets-list.json (names/types only)

    cluster-storage.tgz (PV data from local-path and NFS, if present)

    Restore note (lab-level): bring the cluster back with make up-all, then you can
    review resources.yaml to re-apply deltas, and extract PV files from cluster-storage.tgz
    to repopulate data on the ContainerHost if needed.
```

## Reset

```powershell
# Soft reset: purge app namespaces, re-apply workloads
pwsh -File .\scripts\reset-lab.ps1

# Hard reset (also wipes PV data on ContainerHost)
pwsh -File .\scripts\reset-lab.ps1 -Hard
```

## Smoke Test

```powershell
pwsh -File .\scripts\smoke-test.ps1
```

Shows quick reachability for the main URLs.

