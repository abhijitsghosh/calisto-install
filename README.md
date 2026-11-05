# Calisto installer

Calisto assesses an agency against ASD's Essentials: enterprise IT, cloud and operational
technology. It runs in the agency's own Azure subscription and reads Azure and Microsoft 365
with read-only access. AWS is a preview in this release and will be fully supported in the next.

Calisto is free to use for Azure and Microsoft 365, with no licence fee and no subscription. The
agency pays only for the Azure resources Calisto runs on in its own subscription
([standing cost](RUNNING.md#standing-cost)). AWS assessment is free while it is a preview and
will be a paid option once it is fully supported.

This repository holds what an agency needs to install and run it:

| File | Purpose |
|---|---|
| [deploy/install.sh](deploy/install.sh) | installs or upgrades Calisto from Azure Cloud Shell |
| [deploy/azuredeploy.json](deploy/azuredeploy.json) | the ARM template the installer deploys |
| [deploy/hub-firewall-rules.bicep](deploy/hub-firewall-rules.bicep) | egress rules for a hub Azure Firewall |
| [RUNNING.md](RUNNING.md) | installation, network design, permissions, upgrade and teardown |
| [RELEASES.md](RELEASES.md) | each release's image digest |
| [AUDIT.md](AUDIT.md) | how to audit Calisto's code and what you can check without access |

Calisto's source code is not published, but agencies and their security assessors are welcome
to audit it ([AUDIT.md](AUDIT.md)). Ask for read access and we will arrange a review of the full source, build
pipeline and tests. The container image is `ghcr.io/abhijitsghosh/calisto`, signed by the
release pipeline so you can check it was built from that source (see below).

## Install

In Azure Cloud Shell (Bash), signed in to the subscription Calisto should live in:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy/install.sh | bash -s -- --subscription <subscription-id> --region australiaeast --verify
```

That is the trial layout: a small VNet, a public app address that requires an Entra sign-in,
and a private database. For a landing zone with your own subnets, internal ingress and a hub
firewall, see [RUNNING.md](RUNNING.md).

To pin a release, use the installer from its tag and name the image:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/v0.4.21/deploy/install.sh \
  | CALISTO_BASE=https://raw.githubusercontent.com/abhijitsghosh/calisto-install/v0.4.21/deploy \
    bash -s -- --subscription <subscription-id> --region australiaeast --image ghcr.io/abhijitsghosh/calisto:0.4.21 --verify
```

## Verify the image yourself

```bash
cosign verify ghcr.io/abhijitsghosh/calisto@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/abhijitsghosh/calisto/\.github/workflows/release\.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The digest for each release is in [RELEASES.md](RELEASES.md). `--verify` runs the same check
before the installer deploys anything.
