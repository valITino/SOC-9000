[CmdletBinding()]
param(
    [string]$IsoDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvOrDefault($key,$def){
    if ($env:$key) { return $env:$key }
    $envPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\.env'
    if (Test-Path $envPath) {
        $line = Select-String -Path $envPath -Pattern "^\s*$key=(.+)$" -ErrorAction SilentlyContinue
        if ($line) { return $line.Matches.Value.Split('=')[1].Trim() }
    }
    return $def
}

if (-not $IsoDir) { $IsoDir = Get-EnvOrDefault 'ISO_DIR' (Join-Path (Split-Path -Parent $PSScriptRoot) '..\isos') }
$IsoDir = [IO.Path]::GetFullPath($IsoDir)

Write-Host "ISO dir: $IsoDir" -ForegroundColor Cyan
if (-not (Test-Path $IsoDir)) { Write-Error "Missing folder: $IsoDir"; exit 1 }

$targets = @(
  'ubuntu-22.04.iso',
  'pfsense.iso',
  'win11-eval.iso',
  'nessus_latest_amd64.deb'
) | ForEach-Object { Join-Path $IsoDir $_ }

foreach ($f in $targets) {
    if (Test-Path $f) {
        $h = Get-FileHash -Algorithm SHA256 -Path $f
        "{0,-22}  {1}" -f (Split-Path -Leaf $f), $h.Hash
    } else {
        "{0,-22}  (missing)" -f (Split-Path -Leaf $f)
    }
}
