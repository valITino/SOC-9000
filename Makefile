SHELL := pwsh

help:
	@Write-Host "Targets: init, env, check, up-all, down-all, status"

init:
	@Copy-Item .env.example .env -Force
	@Write-Host "Edit .env before continuing."

env:
	@Get-Content .env | ? {$_ -and $_ -notmatch ^\s*#}

check:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File orchestration/up.ps1 -CheckOnly

up-all:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/lab-up.ps1

down-all:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/lab-down.ps1

status:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/lab-status.ps1

backup:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/backup-run.ps1

reset:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/reset-lab.ps1

reset-hard:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/reset-lab.ps1 -Hard

download-isos:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/download-isos.ps1

smoke:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/smoke-test.ps1

# One-click installer (downloads ISOs, clones repo and runs up-all)
installer:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/standalone-installer.ps1


# Install prerequisites (Git and PowerShell 7) via winget
prereqs:
	@powershell -ExecutionPolicy Bypass -File scripts/install-prereqs.ps1

# Build an executable version of the installer (requires PS2EXE).  Use Windows PowerShell as a fallback
build-exe:
	@pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build-standalone-exe.ps1

# Install prerequisites and build the EXE in one step
install-all:
	make prereqs
	make build-exe

# Package the starter zip and checksums
package:
	@powershell -ExecutionPolicy Bypass -File scripts/package-release.ps1
