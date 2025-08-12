# SOC‑9000 Releases and Packaging

## Why releases?

While cloning the repository works fine for contributors, many users simply want to download a ready‑to‑run package.  GitHub releases provide versioned archives with release notes and attached binaries, making it easier to distribute SOC‑9000.

Releases allow you to:

- Download a single `.zip` file containing the repository (excluding large ISOs)
- Include pre‑built artifacts such as `SOC-9000-installer.exe`
- Provide checksums to verify integrity
- Tag specific versions (e.g. `v0.1.0`) with changelogs

We recommend creating a release for each major update.  See the suggested workflow in the repository root `README.md` for details.

## Packages vs. releases

GitHub Packages (GHCR) are useful for hosting container images and Helm charts.  Since SOC‑9000 relies on upstream images and manifests, there is little benefit in publishing our own packages at this time.  Releases remain the preferred distribution mechanism.

## Suggested release contents

- Source zip: the repository (minus large assets) for those who wish to browse or contribute
- `SOC-9000-installer.exe`: the compiled standalone installer for easy one‑click installation (built via `scripts/build-standalone-exe.ps1`)
- `SHA256SUMS.txt`: checksums for the release assets
- A brief `BEGINNER-README.txt` pointing to the beginner guide in `docs/`

Contributors should still fork and clone the repository directly; releases are aimed at end‑users who want minimal friction.

## Building release assets

To prepare a new release, you can use the helper scripts provided in the repository:

- Install prerequisites and build the standalone installer EXE:

  ```powershell
  pwsh -File .\scripts\install-prereqs.ps1
  pwsh -File .\scripts\build-standalone-exe.ps1
  ```

- Package the repository and compute checksums:

  ```powershell
  pwsh -File .\scripts\package-release.ps1
  ```

These scripts install Git and PowerShell 7 if needed, produce `SOC-9000-installer.exe`, and create `SOC-9000-starter.zip` along with `SHA256SUMS.txt`. Attach these files to your GitHub release.