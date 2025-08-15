This bundle installs:
- scripts\generate-vmnet-profile.ps1 (builds artifacts\network\vmnet-profile.txt from .env)
- scripts\setup-soc9000.ps1 (import-only vnetlib flow; manual fallback)
- scripts\host-prepare.ps1 (uses the same import-only flow)
- ansible\roles\nessus_vm\tasks\main.yml (reads NESSUS_* from env; auto-registers if activation code provided)
- tests\*.ps1 (Pester unit & integration tests; CI runs unit only)
- .github\workflows\windows-ci.yml (Windows CI with Pester)

Run:
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\SOC-9000-patch-applier.ps1