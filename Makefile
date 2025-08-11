SHELL := pwsh

help:
@Write-Host "Targets: init, env, check, up, down"

init:
@Copy-Item .env.example .env -Force
@Write-Host "Edit .env before continuing."

env:
@Get-Content .env | ? {$_ -and $_ -notmatch '^\s*#'}

check:
@pwsh -NoProfile -ExecutionPolicy Bypass -File orchestration/up.ps1 -CheckOnly

up:
@pwsh -NoProfile -ExecutionPolicy Bypass -File orchestration/up.ps1

down:
@pwsh -NoProfile -ExecutionPolicy Bypass -File orchestration/down.ps1
