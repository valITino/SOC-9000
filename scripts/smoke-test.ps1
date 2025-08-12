[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
    if ($script:PSScriptRoot) {
        $leaf = Split-Path -Leaf $script:PSScriptRoot
        if ($leaf -ieq 'scripts') { return (Split-Path -Parent $script:PSScriptRoot) }
        return $script:PSScriptRoot
    }
    $def = $MyInvocation.MyCommand.Definition
    if ($def -and (Test-Path $def)) {
        $dir = Split-Path -Parent $def
        $leaf = Split-Path -Leaf $dir
        return ($leaf -ieq 'scripts') ? (Split-Path -Parent $dir) : $dir
    }
    $exeDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    return $exeDir
}

$ProjectRoot = Get-ProjectRoot
$ScriptsDir  = Join-Path $ProjectRoot 'scripts'

Write-Output "ProjectRoot: $ProjectRoot"
Write-Output "ScriptsDir : $ScriptsDir"

if (-not (Test-Path $ScriptsDir)) {
    throw "Scripts dir not found at $ScriptsDir"
}

Write-Output "Smoke test OK."
