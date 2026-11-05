# Running Calisto

Calisto rates an organisation against ASD Essentials for enterprise IT (the October 2026
successor to the Essential Eight) from read-only evidence in Azure, Microsoft 365 and,
optionally, AWS (a preview in this release), plus the assessor's findings for what no API can see. It deploys into the
agency's own Azure tenancy and writes nothing to the environments it assesses.

## What gets deployed

`deploy/install.sh` deploys `deploy/main.bicep` (compiled to `deploy/azuredeploy.json`) as a
resource-group deployment stack, by default `calisto` in `rg-calisto`:

| Resource | Notes |
|---|---|
| User-assigned managed identity `calisto-mi` | The app's only credential. Used for ARM, Resource Graph, Microsoft Graph, Postgres sign-in, user sign-in (as a federated credential) and AWS (web identity). |
| Container Apps environment `calisto-env` | Workload-profiles environment (Consumption profile) in a VNet subnet, so user-defined routes to a hub firewall apply. Internal or external ingress. |
| Container App `calisto-app` | One replica at all times. Scans and schedules run in-process, so it neither scales to zero nor out. |
| Postgres Flexible Server 16, Burstable B1ms | VNet-integrated (no public endpoint), Microsoft Entra authentication only (password authentication disabled), the managed identity as its Entra administrator. 35-day backups, geo-redundant to the paired Australian region. |
| Log Analytics `calisto-logs` | Container Apps logs and Postgres server logs (connections, disconnections). 90-day retention by default. |
| Private DNS zones | The Postgres zone (unless the hub supplies one) and, for internal ingress, the environment's default domain (unless the hub hosts it). |
| VNet `calisto-vnet` | Only when no subnets are supplied (trial). Two subnets with NSGs. |

There are no secrets anywhere in the deployment: no database password, no client secret,
no AWS key. Regions are limited to `australiaeast` and `australiasoutheast`; Container Apps
is not offered in Australia Central or Central 2. Postgres geo-redundant backups go to the
paired region, which is the other of the two, so backup copies stay in Australia.

### Standing cost

Calisto itself is free to use for Azure and Microsoft 365, with no licence fee or subscription
(AWS will be a paid option once it leaves preview). These Azure resources are what the agency
pays for.

The Container App runs one replica at all times, the Postgres server is billed while it
exists, Log Analytics bills per GB ingested, and geo-redundant backup storage is billed for
the copy. VNets, NSGs and private DNS zones in the trial layout cost little or nothing. Tear
the stack down when it is not needed ([Teardown](#teardown)).

## Before you install

Everyone needs Azure Cloud Shell (Bash) signed in to the subscription Calisto will live in,
with Contributor on it (or on a pre-created resource group, with `--resource-group`), and the
right to create an Entra app registration (or an app registration created for them, passed
with `--app-id`). The installer needs no privileged Entra role: Calisto's read-only grants are
made afterwards on its Permissions page, by an administrator signed in with their own roles
([Permissions](#permissions)).

### Agency A: Azure landing zone, hub and spoke

Calisto goes into an application landing-zone spoke subscription. Ask the platform and
network teams for:

1. **Two subnets in the spoke VNet**, both empty:
   - app subnet: /27 or larger, delegated to `Microsoft.App/environments`;
   - database subnet: /28 or larger, delegated to `Microsoft.DBforPostgreSQL/flexibleServers`.

   The landing zone's UDR (0.0.0.0/0 to the hub firewall) can stay on the app subnet. On the
   database subnet, either leave the UDR off, or keep it and add a route for the
   `AzureActiveDirectory` service tag with next hop `Internet` (the server validates Entra
   tokens itself) or allow that tag on the firewall (the shipped rules do). The server's WAL
   archive to Azure Storage uses the `Microsoft.Storage` service endpoint the platform adds to
   the subnet and does not cross the firewall; do not remove that endpoint.
2. **A private DNS zone for Postgres** in the connectivity subscription, named
   `private.postgres.database.azure.com` (any name ending `.postgres.database.azure.com`
   works), linked to the VNet that holds the hub's DNS resolver. The subscription holding the
   zone must have the `Microsoft.DBforPostgreSQL` resource provider registered, and the
   installer needs `Private DNS Zone Contributor` on the zone (the server writes its own A
   record). Do not reuse `privatelink.postgres.database.azure.com`: that zone is for private
   endpoints and is usually managed by the landing zone's DNS policy.
3. **Private DNS for the app**: with internal ingress the installer creates a zone for the
   environment's default domain and links it to the spoke VNet. If the spoke uses the hub's
   DNS resolver, also link it to the resolver's VNet (`--dns-link-vnet <hub-vnet-id>`, which
   needs join rights on that VNet) or have the network team host the zone centrally
   (`--no-environment-dns-zone`, then create `<default-domain>` with `*` and `@` A records
   pointing at the environment's static IP, both printed by the installer).
4. **Firewall rules** from [`deploy/hub-firewall-rules.bicep`](#egress-through-the-hub-firewall)
   applied to the hub's firewall policy before the install, so the image pull and sign-in
   succeed. Calisto cannot serve them before it can reach the internet, so the first set comes
   from the repository with the subnets given by hand. Later sets, after AWS is connected,
   come from the Permissions page.
5. **An image source**: either the firewall allows `ghcr.io` and
   `pkg-containers.githubusercontent.com`, or the agency's ACR is used (`--acr`; the
   installer needs Contributor on the registry to import, and Owner or RBAC Administrator on
   it to grant the app `AcrPull`).
6. **Azure Policy**: the deployment creates no public endpoints in BYO mode, so a "deny
   public network access" assignment does not block it. A policy that requires NSGs on
   subnets applies to your subnets, not Calisto's resources.

Install:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy/install.sh | bash -s -- --subscription <subscription-id> --region australiaeast \
  --infrastructure-subnet /subscriptions/<spoke>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<app-subnet> \
  --db-subnet /subscriptions/<spoke>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<db-subnet> \
  --db-dns-zone /subscriptions/<connectivity>/resourceGroups/<dns-rg>/providers/Microsoft.Network/privateDnsZones/private.postgres.database.azure.com \
  --scope <management-group-id> --verify
```

Ingress defaults to internal with your subnets. Users reach Calisto over the agency network
(ExpressRoute or VPN into the hub, then the spoke).

### Agency A: Virtual WAN secured hub

The same as hub and spoke, with these differences:

- The spoke VNet is connected to the virtual hub. Routing intent (private and internet
  traffic policies) sends the spoke's egress through the secured hub's Azure Firewall, so no
  UDR is needed on the app subnet. If routing intent is not configured, add the 0.0.0.0/0
  route through the hub's route table.
- The firewall is driven by a Firewall Policy just as in hub and spoke, so
  `deploy/hub-firewall-rules.bicep` applies unchanged: deploy it to the resource group that
  holds the secured hub's policy.
- A virtual hub cannot hold a private DNS zone link or a DNS resolver. Private DNS zones are
  linked to a shared-services spoke that runs the DNS Private Resolver, and the spokes use
  that resolver. Link Calisto's zones to that VNet (`--dns-link-vnet`) or host them centrally.
- The Postgres subnet with routing intent: the private traffic policy does not affect
  traffic within the spoke, but the internet policy sends the server's Entra calls to the
  firewall. The shipped rules allow them (the `AzureActiveDirectory` tag and the Entra FQDNs
  from the database subnet).

### Agency B: AWS Organizations, Azure and Microsoft 365

AWS is a preview in this release (see [AWS](#aws)).

Install into Azure as Agency A (or the trial layout), then connect AWS on Calisto's
Permissions page ([AWS](#aws)):

1. Download the hub role template there (your tenant and Calisto's identity are already
   filled in) and create the stack in the management account.
2. Paste the stack's RoleArn output, download the member role template and deploy it across
   the organisation as a service-managed StackSet.
3. Choose regions (for an egress-filtered spoke, the regions allowed on the firewall) and
   **Test and save**. The next scan includes AWS; nothing is redeployed.

### Trial

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy/install.sh | bash -s -- --subscription <subscription-id> --region australiaeast
```

With no subnets given, the template creates `calisto-vnet` (10.42.0.0/24; change it with
`--managed-vnet-prefix`) with an app subnet and a database subnet, and gives the app
external ingress so it can be reached from a browser. Postgres is still VNet-integrated
with no public endpoint, so the database is never exposed. Sign-in is required and limited
to users assigned a Calisto role. Narrow the app further to the agency's egress addresses
with `--allowed-ingress 203.0.113.0/24,198.51.100.10/32`.

Postgres is kept private in the trial because the alternatives are worse: a Consumption
environment's outbound address is not stable, so a server firewall rule for "the app" either
breaks or has to admit all of Azure (the old `0.0.0.0` rule). VNet integration costs nothing
and needs no rule.

## Network design

```
                         Agency network (on-premises / ExpressRoute / VPN)
                                          |
 Connectivity subscription                v
 +--------------------------------------------------------------------------------+
 | Hub VNet (or vWAN secured hub)                                                  |
 |   Azure Firewall  <-- Firewall Policy + rule collection group "calisto"         |
 |   DNS Private Resolver (or a shared-services spoke when vWAN)                   |
 |   Private DNS zones: private.postgres.database.azure.com, <env default domain>   |
 +--------------------------------------------------------------------------------+
          ^ 0.0.0.0/0 (UDR or routing intent)            | peering / hub connection
          |                                              v
 Application landing zone (spoke subscription), resource group rg-calisto
 +--------------------------------------------------------------------------------+
 | Spoke VNet                                                                      |
 |  app subnet /27 (Microsoft.App/environments)                                    |
 |    Container Apps environment, internal load balancer (static IP)               |
 |      calisto-app (1 replica) -- managed identity calisto-mi                     |
 |          |  5432, TLS verify-full, Entra token as password                      |
 |          v                                                                      |
 |  db subnet /28 (Microsoft.DBforPostgreSQL/flexibleServers)                      |
 |    Postgres Flexible Server, no public endpoint                                 |
 +--------------------------------------------------------------------------------+
 Egress from the app subnet through the firewall to:
   Entra ID, Microsoft Graph, ARM (Azure + M365 reads), Log Analytics ingestion,
   container registry, and, when AWS is enabled, AWS STS and read-only service APIs.
```

Traffic between the app and Postgres stays inside the spoke VNet. The app's outbound
calls go through the firewall. Inbound, users reach the internal load balancer through the
hub; nothing in the spoke is published to the internet.

## Install options

| Option | Purpose |
|---|---|
| `--subscription` | the subscription to install into (default: the shell's current one, which in Cloud Shell may not be the one you expect) |
| `--region` | `australiaeast` (default) or `australiasoutheast` |
| `--resource-group` | target resource group (default `rg-calisto`) |
| `--infrastructure-subnet`, `--db-subnet` | bring your own subnets (both together); checked for delegation and size before deploying |
| `--db-dns-zone` | existing private DNS zone id for Postgres (hub-owned). Without it a zone `calisto.private.postgres.database.azure.com` is created in the resource group and linked to the VNet |
| `--ingress internal\|external` | default internal with your subnets, external for the trial |
| `--no-environment-dns-zone` | internal ingress: do not create the environment's DNS zone; the hub hosts it |
| `--dns-link-vnet <id>` | also link the created zones to this VNet (repeatable), for example the resolver's VNet |
| `--managed-vnet-prefix` | trial VNet address space (/24) |
| `--allowed-ingress` | external ingress: comma-separated CIDRs allowed to reach the app |
| `--image` | `ghcr.io/abhijitsghosh/calisto:<version>` or `...@sha256:<digest>` (default `:latest`) |
| `--verify` | verify the image's cosign signature before deploying |
| `--acr <name or id>` | import the image into this ACR and pull from it with the managed identity |
| `--skip-reader-grant` | make no Azure role assignment on the install subscription; leave Reader to the Permissions page |
| `--app-id` | use an existing app registration instead of creating `Calisto`. A second install in the same tenant gets its own app, `Calisto (<subscription name>)`, so it never takes over the first one's sign-in |
| `--log-retention-days` | Log Analytics retention (default 90) |
| `--template-file` | deploy a local `azuredeploy.json` instead of the published one |

The installer fetches `azuredeploy.json` from `$CALISTO_BASE`
(default `https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy`, the public [calisto-install](https://github.com/abhijitsghosh/calisto-install) repository), or uses the copies beside it when run from a checkout.
`deploy/azuredeploy.json` is the compiled `deploy/main.bicep` and is published with each
release.

## Egress through the hub firewall

[`deploy/hub-firewall-rules.bicep`](deploy/hub-firewall-rules.bicep) creates one rule
collection group, `calisto`, in an existing Azure Firewall Policy. The same policy drives a hub
VNet firewall and a Virtual WAN secured hub.

**First install.** Calisto needs these rules before it can pull its image or sign anyone in, so the
network team deploys them from the repository with Calisto's subnets:

```bash
az deployment group create -g <hub-policy-rg> --template-file deploy/hub-firewall-rules.bicep \
  --parameters firewallPolicyName=<policy-name> \
               appSubnetCidrs='["10.20.1.0/27"]' dbSubnetCidrs='["10.20.1.32/28"]'
```

**After that**, download them from Calisto's Permissions page (Network reach, **Download hub
firewall rules**).
It comes filled in with the deployment's app and database subnets, image source (GHCR, or the
agency's registry), Log Analytics workspace, and the AWS home region and every AWS region the
next scan reaches. The network team supplies only the policy name:

```bash
az deployment group create -g <hub-policy-rg> --template-file calisto-hub-firewall-rules.bicep \
  --parameters firewallPolicyName=<policy-name>
```

After changing the AWS connection's regions, download the rules again and redeploy; the group
is replaced. With no regions set on the AWS connection, a scan covers every region enabled in
the hub account, and so do the rules.

Every rule is scoped to Calisto's subnets as sources, on TCP 443.

| Rule | Destinations | Why |
|---|---|---|
| entra-identity | `login.microsoftonline.com`, `*.login.microsoftonline.com`, `login.microsoft.com`, `*.login.microsoft.com`, `*.identity.azure.net` | user sign-in, managed identity tokens, the federated client assertion; from the database subnet too (Entra token validation) |
| microsoft-graph | `graph.microsoft.com` | Entra, Intune, Secure Score and Microsoft 365 reads |
| azure-resource-manager | `management.azure.com` | ARM and Resource Graph reads |
| container-apps-platform | `mcr.microsoft.com`, `*.data.mcr.microsoft.com` | the environment's system containers |
| log-analytics-ingestion | `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com` (or the one workspace, with `logAnalyticsWorkspaceId`) | Container Apps logs |
| container-image | `ghcr.io`, `pkg-containers.githubusercontent.com`; or the ACR FQDNs given in `acrFqdns` | image pull. None needed for an ACR behind a private endpoint |
| aws-global | `sts.<home>.amazonaws.com`, `sts.amazonaws.com`, `iam.amazonaws.com`, `cloudfront.amazonaws.com`, `organizations.us-east-1.amazonaws.com`, `*.s3-control.<home>.amazonaws.com` | federation, IAM, Organizations (served only from us-east-1), CloudFront, account-level S3 Block Public Access |
| aws-regional | `<service>.<region>.amazonaws.com` for each scanned region and these services: ec2, rds, elasticfilesystem, dynamodb, lambda, ecs, eks, elasticloadbalancing, apigateway, workspaces, secretsmanager, sso, cloudtrail, backup, ssm, guardduty, inspector2, config, securityhub, access-analyzer, wafv2, route53resolver, network-firewall, tagging | the read-only collectors |
| aws-s3 | `s3.<region>.amazonaws.com` and `*.s3.<region>.amazonaws.com` for the scanned regions, us-east-1 and `awsS3ExtraRegions`; `s3.amazonaws.com`, `*.s3.amazonaws.com` | bucket configuration (never object contents); a bucket is read in its own region |
| network rules (service tags) | `AzureActiveDirectory`, `AzureResourceManager`, `AzureMonitor`, `MicrosoftContainerRegistry` + `AzureFrontDoor.FirstParty` | platform traffic the Container Apps documentation lists by tag; turn off with `includeServiceTagRules=false` |

Notes:

- **Postgres needs no rule.** App-to-database traffic stays in the spoke VNet.
- **AWS regions must match.** Set `--aws-regions` on the installer to the same list as
  `awsRegions`. Left empty, Calisto scans every enabled region, and the regions the firewall
  blocks time out and report no visibility.
- **S3 wildcards.** Virtual-hosted bucket addresses need `*.s3.<region>.amazonaws.com`, which
  also matches buckets outside the agency's organisation. Calisto's role can only read; the
  residual risk is exfiltration from a compromised app container to an attacker's bucket in
  an allowed region. Where that matters, use the firewall's TLS inspection with an S3 bucket
  allow-list, or leave S3 out (`awsS3ExtraRegions` empty and remove the rule) and accept no
  visibility for the S3 checks.
- **TLS inspection.** Calisto's JVM trusts the public CA set only. If the firewall
  (Premium) inspects TLS, exclude these destinations from inspection, or add the agency's
  inspection CA to the image (not supported by the published image).

## Private DNS

| Zone | Default | Hub-hosted alternative |
|---|---|---|
| Postgres (VNet integration) | `calisto.private.postgres.database.azure.com`, created in `rg-calisto`, linked to the VNet (and `--dns-link-vnet` VNets) | pass `--db-dns-zone <zone id>`; the zone name must end `.postgres.database.azure.com` and must not equal the server name. The server writes its own A record |
| Container Apps environment default domain (internal ingress) | a zone named after the environment's default domain (`<unique>.australiaeast.azurecontainerapps.io`) with `*` and `@` A records to the environment's static IP, created and linked like the Postgres zone | `--no-environment-dns-zone`, and the hub creates the same zone and records |

If the agency uses its own DNS servers, they forward `postgres.database.azure.com` and
`azurecontainerapps.io` to 168.63.129.16 through a resolver whose VNet is linked to the zones.

## Permissions

Everything Calisto asks for is read-only. `RequiredPermission.all()` in `au.calisto.azure`
(and in `au.calisto.aws` for AWS) is the source of truth, and the console's Permissions page
shows the same list.

### What the managed identity is granted

| Grant | Where | What Calisto reads with it |
|---|---|---|
| Reader | management group given by `--scope` (default: tenant root group), plus the install subscription | Resource Graph and ARM: resources and management groups, network rules, Defender for Cloud pricings and assessments, Sentinel analytics rules, diagnostic settings, policy states, Key Vault and Backup control-plane settings |
| Policy.Read.All | Microsoft Graph application | Conditional Access policies, authentication strengths, security defaults |
| Directory.Read.All | Microsoft Graph application | users, the tenant's licensed Microsoft 365 services |
| AuditLog.Read.All | Microsoft Graph application | last sign-in times; authentication-method registration |
| RoleManagement.Read.Directory | Microsoft Graph application | Entra role assignments, PIM eligible and time-bound assignments |
| DeviceManagementManagedDevices.Read.All | Microsoft Graph application | Intune managed devices and compliance state |
| SecurityEvents.Read.All | Microsoft Graph application | Microsoft Secure Score (Defender for Office 365 controls) |
| Application.Read.All | Microsoft Graph application | new collectors (in development): app registrations and service principals |
| DelegatedPermissionGrant.Read.All | Microsoft Graph application | new collectors (in development): delegated OAuth2 permission grants |
| SharePointTenantSettings.Read.All | Microsoft Graph application | new collectors (in development): SharePoint and OneDrive tenant sharing settings |
| Security Reader | Entra directory role | the tenant diagnostic settings that export Entra sign-in and audit logs |
| Entra administrator | Calisto's own Postgres server | the app's database sign-in; nothing outside that server |

Reader covers every Azure read the checks make: they are all `*/read` actions on the
control plane. No Sentinel, Log Analytics, Key Vault or storage data-plane role is needed,
and Calisto is never given User Access Administrator, Owner or any write role.

A missing grant never reads as a pass: the checks that need it report **no visibility** and
name the exact permission. Some reads also need licensing (sign-in activity and
registration details need Entra ID P1, PIM schedules need P2) and say so when refused.

### Making the grants

An administrator of Calisto (the Calisto.Admin role) opens **Permissions**. The page shows each
grant as held, missing, or granted but not yet in effect, read live as Calisto's managed
identity. Where something is missing:

1. **Sign in for Microsoft Graph.** Entra asks you to consent, for yourself, to Calisto acting
   as you to assign app roles and directory roles.
2. **Sign in for Azure Resource Manager** and choose where Reader goes: a management group
   (it covers every subscription under it, including later ones; the tenant root group covers
   the tenant) or a single subscription.
3. **Grant.** Calisto makes each missing grant with your token and shows the result per grant.

Calisto's own identity holds no right to change permissions. Entra and Azure apply your roles,
so a grant your roles do not allow is refused, and the page names the role it needs:

| Grant | Role needed (least privilege) |
|---|---|
| Reader at a management group or subscription | Role Based Access Control Administrator (can be constrained to Reader), User Access Administrator or Owner, at that scope |
| Graph application permissions | Privileged Role Administrator or Global Administrator |
| Security Reader directory role | Privileged Role Administrator |
| Assigning users to Calisto roles | owner of the Calisto enterprise application, or Cloud Application Administrator |

Under PIM, activate the role before step 1. If the person who holds it is not a Calisto user,
assign them Calisto.Admin for the occasion. Your Graph and Resource Manager tokens are kept in
your browser session only, and are dropped as soon as the grants are made (or when you choose
**Cancel and sign out**). Every grant made or refused is on the record of changes.

Entra can take up to 24 hours to issue the managed identity a token carrying a new Microsoft
Graph permission. The page shows those as granted, not yet in effect, and scans until then
report the checks that need them as no visibility.

Sign-in itself needs only `openid`, `profile` and `email`, which users can normally consent to.
In a tenant that has switched user consent off, the first administrator to sign in is asked to
consent for the organisation.

## Sign-in and roles

The `Calisto` app registration is a confidential client with no client secret. Its
credential is a federated identity credential that trusts Calisto's managed identity:

| Field | Value |
|---|---|
| issuer | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| subject | the managed identity's object (principal) id |
| audience | `api://AzureADTokenExchange` |

At sign-in the app asks its managed identity for a token for `api://AzureADTokenExchange`
and presents it to Entra's token endpoint as `client_assertion`. Nothing expires or needs
rotating. An earlier install's client secrets are deleted by the installer.

The app defines four roles. Only users or groups assigned one can sign in
(`appRoleAssignmentRequired` is set on the enterprise application); the installer assigns
you `Calisto.Admin`. Roles reach the app in the ID token's `roles` claim.

| Role | Purpose |
|---|---|
| `Calisto.Viewer` | read assessments, ratings, evidence and reports |
| `Calisto.Assessor` | plan assessments, run scans, record findings, maintain the asset register |
| `Calisto.Approver` | approve plans and finalise outcomes |
| `Calisto.Admin` | settings, scopes and everything above |

Assign roles in the portal (Entra ID > Enterprise applications > Calisto > Users and groups >
Add user/group) or with Graph; the installer prints the exact command and role ids:

```bash
az rest --method POST \
  --uri https://graph.microsoft.com/v1.0/servicePrincipals/<calisto-sp-object-id>/appRoleAssignedTo \
  --body '{"principalId":"<user-or-group-object-id>","resourceId":"<calisto-sp-object-id>","appRoleId":"<role-id>"}'
```

Assigning groups needs Entra ID P1. Calisto is never run with `calisto.auth.enabled=false`
in a deployment.

## Image supply chain

Releases are built by Calisto's release workflow, pushed to `ghcr.io/abhijitsghosh/calisto`
and signed with cosign keyless signing (the signing certificate names the release workflow
at the release tag; the signature is logged in the public Rekor transparency log). Each
release's digest is listed in
[RELEASES.md](https://github.com/abhijitsghosh/calisto-install/blob/main/RELEASES.md), and
the installer and template for that release are tagged with its version in the
calisto-install repository.

- The installer always resolves the tag to a digest and deploys `image@sha256:...`, so a
  re-tag cannot change what runs.
- `--verify` downloads cosign v3.1.3 from its GitHub release, checks it against a SHA-256
  pinned in the installer, and verifies the image's signature and signer identity before
  deploying. Needs internet access from Cloud Shell.
- `--acr <registry>` imports the verified digest into the agency's registry (`az acr
  import`, a server-side copy) and deploys it from there; the app pulls with its managed
  identity, which gets `AcrPull` on that registry only. Use this when the firewall should not
  allow GitHub.

To verify by hand:

```bash
cosign verify ghcr.io/abhijitsghosh/calisto@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/abhijitsghosh/calisto/\.github/workflows/release\.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Data protection

- Postgres has no public endpoint and password authentication is disabled. The app signs in
  as its managed identity (user name `calisto-mi`) with a short-lived Entra token per
  connection, over TLS with full certificate and host-name verification.
- Backups are kept 35 days and geo-redundant to the paired region in Australia. Geo-redundancy
  is fixed when the server is created.
- `log_connections` and `log_disconnections` are on, and the server's logs go to Log
  Analytics. pgaudit is not enabled: it needs a server restart and an extension; enable it
  if the agency's logging policy calls for statement-level audit.
- Log Analytics retention is 90 days by default (`--log-retention-days`).
- All data, backups and logs stay in Australian regions.

## AWS

**AWS is a preview in this release.** The AWS checks pass Calisto's automated tests but have
not yet been tested against a live AWS Organization. Treat AWS ratings as indicative, and
confirm them by hand before they go into a finalised assessment. Full support is planned for
the next release. Azure and Microsoft 365 are fully supported.

AWS is off by default. Turning it on adds AWS assets and 32 AWS checks to the same
inventory, ratings and reports. Calisto stays hosted in Azure and reaches AWS with its own
managed identity through Entra-to-AWS web identity federation, so no AWS access key is
created or stored.

### How federation works

1. Calisto's managed identity asks Entra for a token with audience
   `api://AzureADTokenExchange`. It is a v2.0 token: issuer
   `https://login.microsoftonline.com/<tenant-id>/v2.0`, subject the managed identity's object
   id. (This is the same token Entra accepts when the identity is a federated credential on
   an app registration, for which Microsoft documents the v2.0 issuer. The v1 issuer
   `https://sts.windows.net/<tenant-id>/` applies to app registrations that accept v1 tokens,
   not to this audience.)
2. Calisto presents the token to AWS STS `AssumeRoleWithWebIdentity` for `CalistoHubRole` in
   the management account. The role trusts an IAM OIDC identity provider for that issuer, and
   its trust policy pins both `aud` and `sub`, so no other identity in the tenant can use it.
3. From the hub, Calisto lists the organisation's accounts and assumes `CalistoMemberRole` in
   each with `sts:AssumeRole`. The member role trusts only the hub role; the hub role may
   assume it only in accounts of the organisation (`aws:ResourceOrgID`).

The management account itself is read with the hub role (it carries the same read-only
policies), because a service-managed StackSet never deploys to the management account.

### Connect AWS

On **Permissions**, an administrator of Calisto:

1. **Downloads the hub role template.** Calisto fills in your Entra tenant id and its managed
   identity's object id as the parameter defaults. In the **management account** (or the
   delegated administrator account Calisto lists the organisation from): CloudFormation,
   Create stack, Upload a template file, accept the defaults (set `OrganizationId` to limit
   the hub to your organisation), acknowledge IAM resources, Create.
2. **Pastes the stack's RoleArn output.**
3. **Downloads the member role template**, which then names your hub account, and deploys it
   from the management account as a StackSet: service-managed permissions, automatic
   deployment on, targeting the organisation root (or the OUs to assess), one region (IAM is
   global). Activate trusted access for StackSets first if the organisation has not.
4. **Chooses regions and accounts** (blank means all) and selects **Test and save**. Calisto
   assumes the hub role, lists the organisation and reports what it can and cannot reach. It
   saves the connection only if it can assume the hub role, and the next scan includes AWS. No
   redeploy or restart is involved, and changing or disconnecting works the same way.

Behind a hub firewall, choose the same regions as the firewall rules' `awsRegions`.

If the account already has an IAM OIDC provider for
`https://login.microsoftonline.com/<tenant-id>/v2.0`, set `CreateOidcProvider` to `false` and
make sure its client id list includes `api://AzureADTokenExchange`. To require an external id
on member roles, set `ExternalId` on the StackSet and the same value in Calisto.

If the test says `InvalidIdentityToken`, the issuer does not match: compare the `iss` claim of
a token from the app's identity with the hub stack's `OidcIssuer` output. The template's
`IssuerVersion=v1` switches the provider and trust to `https://sts.windows.net/<tenant-id>/`.

If the hub is a delegated administrator account rather than the management account, register
it as a delegated administrator for Organizations, or the scan covers the hub account alone
and says why.

Turn on CloudTrail, AWS Config, Security Hub, GuardDuty, Inspector, IAM Access Analyzer,
Systems Manager and AWS Backup where the agency uses them. Where one is off, the checks that
depend on it report no visibility and say what to enable; no IAM policy can make a service
report that is switched off.

### AWS configuration

The connection lives in Calisto's database, set on the Permissions page. An install from
before v0.4 that set it with environment variables (`CALISTO_AWS_ROLE_ARN`,
`CALISTO_AWS_MEMBER_ROLE`, `CALISTO_AWS_MEMBER_EXTERNAL_ID`, `CALISTO_AWS_HOME_REGION`,
`CALISTO_AWS_REGIONS`, `CALISTO_AWS_ACCOUNTS`, `CALISTO_AWS_TOKEN_AUDIENCE`) keeps working;
a connection saved on the page takes precedence.

| Environment variable | Purpose |
|---|---|
| `CALISTO_AWS_ENABLED` | `false` leaves AWS out of this deployment entirely (default `true`; AWS takes part once connected) |
| `CALISTO_AWS_SELF_STACK` | a CloudFormation stack whose resources are left out of the assessment |

## Upgrade

To move to the latest release, run this in Cloud Shell in the subscription Calisto is installed in:

```bash
curl -sL https://calisto.run/upgrade.sh | bash
```

To move to a particular version, re-run the installer with it:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy/install.sh | bash -s -- --subscription <subscription-id> --region australiaeast \
  --image ghcr.io/abhijitsghosh/calisto:<version> --verify
```

It reads the existing stack's parameters and keeps the network mode, subnets, DNS zone and
its links, ingress and the allowed ingress addresses, registry, app registration and AWS
settings, so only the image changes. The
database is kept; Flyway migrates the schema on start. The image is again pinned by digest.

Upgrading from 0.3 or earlier: re-running the installer adds the two sign-in return addresses the
Permissions page's grant flow needs (`/grant/callback/grant-graph` and `/grant/callback/grant-arm`)
to the app registration. Until it is re-run, the Sign in buttons there fail with a redirect URI
mismatch.

Upgrading from 0.2 or earlier: assessments open at the upgrade are kept, but domain placements
made against Entra directory-role or IAM-user assets no longer apply, because those are no longer
assets (users and roles are counted as evidence). Re-place anything that mattered, then scan and have
open plans approved again; the scope comparison shows what moved.

Installs made with the earlier template (public Postgres with a password) cannot be
upgraded in place, because a server cannot be moved into a VNet. The installer detects this
and stops. Export with `pg_dump` from a machine allowed by the old server's firewall, tear
the old stack down, install, and restore with `psql` as the managed identity (the restore
can run from a VM or Cloud Shell attached to the VNet).

## Teardown

```bash
MI_OBJ=$(az identity show -g rg-calisto -n calisto-mi --query principalId -o tsv)
# Role assignments made on the Permissions page (Reader at a management group) are outside the
# stack; remove every one the identity holds while it still exists.
az role assignment list --assignee "$MI_OBJ" --all --query "[].id" -o tsv \
  | xargs -r -n1 az role assignment delete --ids
az stack group delete --name calisto -g rg-calisto --action-on-unmanage deleteAll --yes
az group delete -n rg-calisto --yes
az ad app delete --id <sign-in app id printed by the installer>
```

Deleting the stack removes the subscription Reader assignment, the AcrPull assignment and
the private DNS zones it created. Graph app-role assignments and the Entra role go with the
managed identity.

The firewall rule collection group is removed by the network team
(`az network firewall policy rule-collection-group delete`). If AWS was set up, delete the
StackSet instances and the `calisto-member-role` StackSet, then the `calisto-hub` stack.

## Checking network reach

On the Permissions page, **Test connections** resolves, connects to and makes one HTTPS request to
every endpoint the enabled collectors call (Entra, Graph, Resource Manager, AWS STS, Organizations
and each regional service), from where Calisto runs, honouring any JVM proxy settings. AWS
endpoints are probed in every region the next scan reaches; with no regions set on the AWS
connection, that is every region enabled in the hub account. A failure names the cause (DNS, TLS,
timeout, refused, proxy) and the host to allow on the hub firewall, and the page lists any AWS
region that cannot be reached, since scans report no visibility there. The same report is at
`GET /api/connectivity`.

## Environments

A portfolio department, or an agency reshaped by machinery-of-government changes, can assess each
environment separately. Name environments in configuration by management group, subscription, AWS
account or organisational unit, or tag resources (or their subscription or account)
`essentials-environment`; a resource tag wins, then the subscription or account tag, then the nearest
mapped management group or OU.

```yaml
calisto:
  environments:
    - name: Portfolio department
      management-groups: [mg-portfolio]
      aws-organizational-units: [ou-ab12-portfolio]
    - name: Statutory agency
      subscriptions: [00000000-0000-0000-0000-000000000000]
      aws-accounts: ["111122223333"]
```

The console then offers an environment picker; each environment has its own assessments of each chapter.

## Domain placement

Calisto proposes Essentials domains for every asset and records why. Add domains on the
resource with an `essentials-domain` tag holding comma-separated ASD domain slugs (a tag adds
to Calisto's proposal), or place the asset in the console, giving the reason:

```
essentials-domain = critical-processes-and-services,business-systems
```

Valid slugs: `identity-services`, `boundary-services`, `critical-processes-and-services`,
`privileged-environments`, `business-systems`, `user-devices`. Critical processes and
services are only ever reached by tag or operator override — only the organisation knows
what is critical.

## Configuration

| Environment variable | Purpose |
|---|---|
| `CALISTO_SUBSCRIPTIONS` | subscriptions to assess; empty = all readable |
| `CALISTO_SELF_RESOURCE_GROUP` | Calisto's own resource group, excluded from every scan (set by the template) |
| `AZURE_CLIENT_ID` | which user-assigned identity `DefaultAzureCredential` uses (set by the template) |
| `CALISTO_DB_URL`, `CALISTO_DB_USER` | Postgres connection (set by the template; the user is the managed identity's name) |
| `CALISTO_DB_PASSWORDLESS` | `true` (set by the template): sign in to Postgres with an Entra token for `AZURE_CLIENT_ID` instead of `CALISTO_DB_PASSWORD` |
| `CALISTO_DB_PASSWORD` | local runs only |
| `CALISTO_ENTRA_TENANT_ID`, `CALISTO_ENTRA_CLIENT_ID` | sign-in (set by the template) |
| `CALISTO_AUTH_CLIENT_ASSERTION` | `managed-identity` (set by the template): authenticate the sign-in client with a managed-identity token as `client_assertion` |
| `CALISTO_MI_OBJECT_ID`, `CALISTO_MI_NAME` | the managed identity's object id and name (set by the template) |
| `CALISTO_AZURE_ENABLED` | `false` to leave Azure and Microsoft 365 out (default `true`) |
| `CALISTO_CHECK_TIMEOUT_SECONDS` | per-check timeout across every cloud (default 300); a check that runs over reports no visibility |
| `CALISTO_AWS_*` | AWS, see [AWS configuration](#aws-configuration) |
