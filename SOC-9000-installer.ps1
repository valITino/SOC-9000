# SOC-9000 installer entry point
<#!
.SYNOPSIS
    Bootstrap SOC-9000 VMware networking.
.DESCRIPTION
    Wrapper that invokes configure-vmnet.ps1 followed by
    verify-networking.ps1. Accepts and forwards any parameters to the
    configure script.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ConfigureArgs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root   = Split-Path -Parent $PSCommandPath
$cfg    = Join-Path $root 'scripts/configure-vmnet.ps1'
$verify = Join-Path $root 'scripts/verify-networking.ps1'

& $cfg @ConfigureArgs
& $verify @ConfigureArgs
