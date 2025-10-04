[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
    try {
        if ($script:PSScriptRoot) {
            $leaf = Split-Path -Leaf $script:PSScriptRoot
            if ($leaf -ieq 'scripts') {
                return (Split-Path -Parent $script:PSScriptRoot)
            } else {
                return $script:PSScriptRoot
            }
        }
    } catch { }

    $def = $MyInvocation.MyCommand.Definition
    if ($def -and (Test-Path $def)) {
        $dir  = Split-Path -Parent $def
        $leaf = Split-Path -Leaf $dir
        if ($leaf -ieq 'scripts') {
            return (Split-Path -Parent $dir)
        } else {
            return $dir
        }
    }

    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $exeDir  = [System.IO.Path]::GetDirectoryName($exePath)
    return $exeDir
}

$ProjectRoot = Get-ProjectRoot
$ScriptsDir  = Join-Path $ProjectRoot 'scripts'

Write-Host "ProjectRoot: $ProjectRoot"
Write-Host "ScriptsDir : $ScriptsDir"

if (-not (Test-Path $ScriptsDir)) { throw "Scripts dir not found at $ScriptsDir" }
Write-Host "Smoke test OK." -ForegroundColor Green
