<# 
    package-release.ps1: Creates SOC-9000-starter.zip and SHA256SUMS.txt.

    This script packages the repository for distribution, excluding large or transient directories
    such as `.git`, `artifacts`, `isos`, `temp` and existing zip files.  It also computes SHA256
    checksums for the installer and starter zip to allow users to verify integrity.

    Run this from the repository root:
        pwsh -File .\scripts\package-release.ps1
#>
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$zipName = "SOC-9000-starter.zip"
$sumName = "SHA256SUMS.txt"

# Remove any previous artifacts
Remove-Item -ErrorAction SilentlyContinue -Force $zipName, $sumName

<#
    Compress-Archive in Windows PowerShell 5.1 does not support the -Exclude parameter.  To ensure
    compatibility across PowerShell versions, we stage the files to be zipped in a temporary
    directory while manually filtering out excluded directories and file patterns.
#>

# Define exclusion lists (omit large/transient directories and certain patterns)
$excludeDirs    = @(".git", "artifacts", "isos", "temp")
$excludePatterns = @("*.zip", "*.exe")

# Create a temporary staging directory
$tempDir = Join-Path $env:TEMP "soc9000_packaging"
if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Path $tempDir | Out-Null

Write-Host "Packaging starter zip: $zipName" -ForegroundColor Cyan

# Copy all items except excluded ones into the staging directory
Get-ChildItem -LiteralPath . -Force | ForEach-Object {
    # Skip directories that are in the exclusion list
    if ($excludeDirs -contains $_.Name) {
        return
    }
    # Skip items matching excluded patterns
    foreach ($pattern in $excludePatterns) {
        if ($_.Name -like $pattern) {
            return
        }
    }
    Copy-Item -Path $_.FullName -Destination $tempDir -Recurse -Force -Container
}

# Create the zip from the staging directory
Compress-Archive -Path (Join-Path $tempDir '*') -DestinationPath $zipName -Force -CompressionLevel Optimal

# Clean up staging directory
Remove-Item -Recurse -Force $tempDir

# Compute SHA256 checksums for the installer and starter zip
Write-Host "Computing checksums..." -ForegroundColor Cyan
function Append-Checksum($fileName) {
    if (Test-Path $fileName) {
        $hash = (Get-FileHash $fileName -Algorithm SHA256).Hash
        "$hash  $fileName" | Out-File $sumName -Encoding ASCII -Append
    }
}

Append-Checksum "SOC-9000-installer.exe"
Append-Checksum $zipName

Write-Host "Packaging complete. Generated files:" -ForegroundColor Green
Write-Host "  - $zipName"
Write-Host "  - $sumName"