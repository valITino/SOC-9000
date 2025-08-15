# path: scripts/host-prepare.ps1
[CmdletBinding()]
param([switch]$WhatIf,[switch]$Verbose)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p =New-Object Security.Principal.WindowsPrincipal $id
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Cyan
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $MyInvocation.UnboundArguments
        Start-Process pwsh -Verb RunAs -ArgumentList $args | Out-Null; exit 0
    }
}

Ensure-Admin

$logDir = Join-Path $PSScriptRoot "..\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
try{ Stop-Transcript | Out-Null }catch{}
$ts  = Get-Date -Format "yyyyMMdd-HHmmss"
$log = Join-Path $logDir "host-prepare-$ts.log"
Start-Transcript -Path $log -Force | Out-Null

try {
    $cfg = Join-Path $PSScriptRoot 'configure-vmnet.ps1'
    if(-not (Test-Path $cfg)){ throw "Missing $cfg" }
    $args = @()
    if($WhatIf){ $args += '-WhatIf' }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $cfg @args -Verbose
    if ($LASTEXITCODE -ne 0) { throw "configure-vmnet.ps1 exited with code $LASTEXITCODE" }
    Write-Host "Host preparation: OK" -ForegroundColor Green
    Stop-Transcript | Out-Null
    exit 0
}
catch {
    Write-Error "Host preparation FAILED: $($_.Exception.Message)"
    Write-Host  "See transcript: $log" -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    exit 1
}
