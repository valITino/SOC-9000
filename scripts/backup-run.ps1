# Creates a timestamped backup under BACKUP_DIR; trims old snapshots.
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest

# Load env
if (Test-Path ".env") {
  (Get-Content ".env" | ? {$_ -and $_ -notmatch '^\s*#'}) | % {
    if ($_ -match '^\s*([^=]+)=(.*)$'){ $env:$($matches[1].Trim())=$matches[2].Trim() }
  }
}
$backupDir = $env:BACKUP_DIR; if(-not $backupDir){ $backupDir="E:\\SOC-9000\\backups" }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path $backupDir "SOC-9000-$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# Run the Ansible snapshot (WSL)
$inv = "/mnt/e/SOC-9000/SOC-9000/ansible/inventory.ini"
$play= "/mnt/e/SOC-9000/SOC-9000/ansible/site-backup.yml"
wsl bash -lc "ansible-playbook -i '$inv' '$play'"

# Move fetched files into the right timestamped folder and zip them
# (Ansible 'fetch' created nested dirs; collect them)
Get-ChildItem -Path (Join-Path $backupDir "SOC-9000") -Recurse -File | % { Copy-Item $_.FullName $out -Force }
Compress-Archive -Path (Join-Path $out "*") -DestinationPath (Join-Path $backupDir "SOC-9000-$stamp.zip")
Remove-Item $out -Recurse -Force

# Retention
$ret = [int]($env:SNAPSHOT_RETENTION ?? "5")
$zips = Get-ChildItem $backupDir -Filter "SOC-9000-*.zip" | Sort-Object LastWriteTime -Descending
if ($zips.Count -gt $ret) { $zips[$ret..($zips.Count-1)] | Remove-Item -Force }

Write-Host "Backup written: $(Join-Path $backupDir "SOC-9000-$stamp.zip")"

