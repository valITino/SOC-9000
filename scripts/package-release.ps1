<# 
    package-release.ps1: Creates SOC-9000-starter.zip and SHA256SUMS.txt.

    This script packages the repository for distribution, excluding large or transient directories
    such as `.git`, `artifacts`, `isos`, `temp` and existing zip files.  It also computes SHA256
    checksums for the installer and starter zip to allow users to verify integrity.

    Run this from the repository root:
        pwsh -File .\scripts\package-release.ps1
    or via the Makefile:
        make package
#>
[CmdletBinding()] param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$zipName = "SOC-9000-starter.zip"
$sumName = "SHA256SUMS.txt"

# Remove any previous artifacts
Remove-Item -ErrorAction SilentlyContinue -Force $zipName, $sumName

# Define exclusion list (omit large/transient directories and zip files)
$exclude = @(".git","artifacts","isos","temp","*.zip")

# Create the starter zip
Write-Host "Packaging starter zip: $zipName" -ForegroundColor Cyan
Compress-Archive -Path * -DestinationPath $zipName -Force -CompressionLevel Optimal -Exclude $exclude

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