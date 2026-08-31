# Code signing policy

**Free code signing provided by SignPath.io, certificate by SignPath Foundation.**

Coco Minecraft Updater is an open-source Windows launcher. The canonical source
repository is [Franco-Caballero/CocoMinecraftUpdater](https://github.com/Franco-Caballero/CocoMinecraftUpdater).
The launcher source and its build scripts are distributed under the MIT License.
Third-party modpacks, mods, and game assets kept in this repository retain their
own upstream licenses; they are not submitted to SignPath or signed with this
project's certificate. This policy applies to the Coco launcher binaries only.

## Team roles

- Committer and reviewer: Franco-Caballero (repository owner).
- Approver: Franco-Caballero.

Changes from anyone other than the committer are reviewed through a GitHub pull
request before they are included in a release. Every release signing request is
manually reviewed and approved by the approver. GitHub and SignPath accounts
used for release work must have multi-factor authentication enabled.

## Build and signing rules

- Signed files are built only from this repository and its versioned build
  scripts; third-party binaries are not signed with this project's certificate.
- A release is built and retained as a candidate until its assets, manifest
  hashes, and Authenticode signature have been checked.
- The signed `CocoUpdater.exe` must be uploaded without post-signing changes.
- The public release manifest must contain the SHA-256 and size of the signed
  file, not the unsigned build.
- A release is never published merely because a signing job started. It is
  published only after the signing request succeeds and the signed asset and
  manifest have been verified.

## Privacy

This program will not transfer any information to other networked systems unless
specifically requested by the user or the person installing or operating it.
The launcher has no telemetry service. Network traffic is limited to requested
release/mod downloads and the explicitly configured ZeroTier/LAN operation.

## Current status

As of 2026-08-31, the public launcher executable is not yet signed with a
trusted production certificate. The SignPath Foundation application must be
submitted by the project owner. Until that is approved and connected to the
release policy, no release may claim to be signed or SmartScreen-warning-free.
