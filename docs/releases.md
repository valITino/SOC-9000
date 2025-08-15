# SOC‑9000 Releases and Packaging

## Why releases?

While cloning the repository works fine for contributors, many users simply want to download a ready‑to‑run package.  GitHub releases provide versioned archives with release notes and attached binaries, making it easier to distribute SOC‑9000.

Releases allow you to:

- Download a single `.zip` file containing the repository (excluding large ISOs)
- Include pre‑built artifacts such as `scripts/setup-soc9000.ps1`
- Provide checksums to verify integrity
- Tag specific versions (e.g. `v0.1.0`) with changelogs

We recommend creating a release for each major update.  See the suggested workflow in the repository root `README.md` for details.

## Packages vs. releases

GitHub Packages (GHCR) are useful for hosting container images and Helm charts.  Since SOC‑9000 relies on upstream images and manifests, there is little benefit in publishing our own packages at this time.  Releases remain the preferred distribution mechanism.

## Suggested release contents

- Source zip: the repository (minus large assets) for those who wish to browse or contribute
- `SHA256SUMS.txt`: checksums for the release assets
- A brief `BEGINNER-README.txt` pointing to the beginner guide in `docs/`

Contributors should still fork and clone the repository directly; releases are aimed at end‑users who want minimal friction.

## Building release assets

To prepare a new release, use the helper script provided in the repository:

- Package the repository and compute checksums:

  ```powershell
  pwsh -File .\scripts\package-release.ps1
  ```

These scripts install Git and PowerShell 7 if needed, produce `scripts/setup-soc9000.ps1`, and create `SOC-9000-starter.zip` along with `SHA256SUMS.txt`. Attach these files to your GitHub release.
