# Auditing Calisto

Calisto runs inside an agency's own tenancy with read access across its estate, so the agency
should be able to check exactly what it does. Agencies, their IRAP assessors and their security
teams are welcome to audit the code.

## What you can review

- **The full source code** of the application, the console and the installer.
- **The tests.** 283 automated tests, including end-to-end journeys through the console that
  sign in as each role.
- **The build pipeline.** The GitHub Actions workflows that test every change, build the
  container image and sign it.
- **The dependencies**, declared in the Maven build file with fixed versions.
- **ASD source material.** ASD's OSCAL release of the enterprise IT chapter ships unchanged. The
  cloud and OT chapters are transcribed by a script you can rerun against ASD's pages.

Ask for read access by opening an issue in the
[calisto-install](https://github.com/abhijitsghosh/calisto-install) repository, and we will
arrange a review of the full repository.

## What you can check without access

- **The image is the one the pipeline built.** Every release image is signed with cosign by the
  release workflow's own GitHub identity, and the installer's `--verify` option refuses an image
  whose signature does not match. The digest for each release is in `RELEASES.md`.
- **The installer and templates.** `install.sh`, the ARM template and the hub firewall rules are
  published in full in calisto-install. They are what deploys Calisto.
- **What Calisto is allowed to read.** Its managed identity holds Reader in Azure, read-only
  Microsoft Graph application permissions and the Security Reader directory role. The
  Permissions page in the console lists each grant and what it reads. `RUNNING.md` has the same
  list.
- **What it writes.** Calisto writes only to its own resource group: its database, its logs and
  its container app. It makes no changes to the environments it assesses, and none of its
  grants would let it.
- **Where data goes.** The app makes no outbound calls apart from Entra sign-in and the cloud APIs it reads. All
  data, backups and logs stay in the agency's tenancy in an Australian region.
- **The record of changes.** Every change in Calisto is written to an append-only audit trail.
  The database refuses any update, delete or truncate of it.
