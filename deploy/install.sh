#!/usr/bin/env bash
# Calisto installer. Run in Azure Cloud Shell (Bash), signed in to the subscription Calisto
# should live in (for a landing zone: the application landing-zone spoke subscription).
#
#   Trial (creates a small VNet; public app ingress; Postgres private):
#     curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy/install.sh | bash -s -- --subscription <id> --region australiaeast
#
#   Landing zone (your spoke subnets; internal ingress; hub DNS zone; image from your ACR):
#     curl -sL https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy/install.sh | bash -s -- --subscription <id> --region australiaeast \
#       --infrastructure-subnet <subnet-id> --db-subnet <subnet-id> \
#       --db-dns-zone <private-dns-zone-id> --acr <registry-name> --verify
#
# What it does:
#   1. resolves the image tag to a digest (optionally verifies its cosign signature, and
#      imports it into your ACR) and deploys image@sha256:...;
#   2. creates or updates the "Calisto" Entra app registration: app roles, no client secret;
#   3. deploys deploy/main.bicep as a deployment stack;
#   4. adds a federated credential so the app signs users in with its managed identity;
#   5. assigns you Calisto.Admin;
#   6. prints the URL. The managed identity's read-only grants (Reader at a management group,
#      Microsoft Graph permissions, Security Reader) and the AWS connection are made in the
#      console, on the Permissions page, by an administrator signed in with their own roles.
# Re-running upgrades in place: the database and the earlier network settings are kept.
set -euo pipefail

REGION="australiaeast"
SUBSCRIPTION=""
RG="rg-calisto"
STACK="calisto"
IMAGE="ghcr.io/abhijitsghosh/calisto:latest"
BASE="${CALISTO_BASE:-https://raw.githubusercontent.com/abhijitsghosh/calisto-install/main/deploy}"
TEMPLATE=""
GRANT_READER="true"
APP_ID=""
ACR=""
VERIFY="false"
INFRA_SUBNET=""; DB_SUBNET=""; DB_DNS_ZONE=""; INGRESS=""; ENV_DNS=""; DNS_LINKS=()
MANAGED_PREFIX=""; ALLOWED_INGRESS=""; LOG_RETENTION=""
AWS_ROLE_ARN=""; AWS_ACCOUNTS=""; AWS_REGIONS=""; AWS_MEMBER_ROLE=""

COSIGN_VERSION="v3.1.3"
COSIGN_SHA256_LINUX_AMD64="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"
COSIGN_SHA256_LINUX_ARM64="c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"
SIGNER_IDENTITY_REGEXP='^https://github\.com/abhijitsghosh/calisto/\.github/workflows/release\.yml@refs/tags/v.*$'
SIGNER_ISSUER="https://token.actions.githubusercontent.com"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "    $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --subscription) SUBSCRIPTION="$2"; shift 2;;
    --resource-group) RG="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --template-file) TEMPLATE="$2"; shift 2;;
    # You cannot write role assignments: leave Reader to the console's Permissions page.
    --skip-reader-grant) GRANT_READER="false"; shift;;
    # Use an app registration an Application Administrator created for you.
    --app-id) APP_ID="$2"; shift 2;;
    # Pull the image from your Azure Container Registry (name or resource id).
    --acr) ACR="$2"; shift 2;;
    # Verify the image's cosign signature before deploying.
    --verify) VERIFY="true"; shift;;
    # Bring your own network (both subnets together).
    --infrastructure-subnet) INFRA_SUBNET="$2"; shift 2;;
    --db-subnet) DB_SUBNET="$2"; shift 2;;
    --db-dns-zone) DB_DNS_ZONE="$2"; shift 2;;
    --ingress) INGRESS="$2"; shift 2;;
    --no-environment-dns-zone) ENV_DNS="false"; shift;;
    --dns-link-vnet) DNS_LINKS+=("$2"); shift 2;;
    --managed-vnet-prefix) MANAGED_PREFIX="$2"; shift 2;;
    --allowed-ingress) ALLOWED_INGRESS="$2"; shift 2;;
    --log-retention-days) LOG_RETENTION="$2"; shift 2;;
    # Assess AWS too (deploy/aws-hub-role.yaml; see RUNNING.md).
    --aws-role-arn) AWS_ROLE_ARN="$2"; shift 2;;
    --aws-accounts) AWS_ACCOUNTS="$2"; shift 2;;
    --aws-regions) AWS_REGIONS="$2"; shift 2;;
    --aws-member-role) AWS_MEMBER_ROLE="$2"; shift 2;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

# Agencies keep assessment data onshore. Container Apps is offered in these two Australian
# regions only (not Australia Central / Central 2).
case "$REGION" in
  australiaeast|australiasoutheast) ;;
  *) die "Calisto installs only in australiaeast or australiasoutheast; got '$REGION'.";;
esac
case "$INGRESS" in ""|internal|external) ;; *) die "--ingress is internal or external";; esac

command -v az >/dev/null || die "the Azure CLI is required (use Azure Cloud Shell)."
command -v jq >/dev/null || die "jq is required (Azure Cloud Shell has it)."
if [[ -n "$SUBSCRIPTION" ]]; then
  az account set --subscription "$SUBSCRIPTION" >/dev/null 2>&1 || die "subscription '$SUBSCRIPTION' not found or not accessible."
fi
TENANT=$(az account show --query tenantId -o tsv) || die "run 'az login' first."
SUB=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Calisto install: subscription $SUB_NAME ($SUB), region $REGION, resource group $RG"
[[ -z "$SUBSCRIPTION" ]] && note "the shell's current subscription; pass --subscription to choose another"

# ---------------------------------------------------------------------------------------
# Earlier install: keep its network and image-source settings unless new ones are given.
# Postgres cannot move subnet and geo-backup cannot change after creation, so an upgrade
# must deploy with the same network parameters.
# ---------------------------------------------------------------------------------------
STACK_JSON=$(az stack group show -g "$RG" -n "$STACK" -o json 2>/dev/null || echo '{}')
prev() { jq -r --arg k "$1" '.parameters[$k].value // empty | if type == "array" or type == "object" then tojson else . end' <<<"$STACK_JSON"; }
PREV_MODE=$(prev networkMode)
if [[ -n "$PREV_MODE" && -z "$INFRA_SUBNET$DB_SUBNET" ]]; then
  if [[ "$PREV_MODE" == "byo" ]]; then
    INFRA_SUBNET=$(prev infrastructureSubnetId); DB_SUBNET=$(prev dbDelegatedSubnetId)
    [[ -z "$DB_DNS_ZONE" ]] && DB_DNS_ZONE=$(prev dbPrivateDnsZoneId)
  fi
  [[ -z "$INGRESS" ]] && INGRESS=$(prev ingress)
  [[ -z "$MANAGED_PREFIX" ]] && MANAGED_PREFIX=$(prev managedVnetPrefix)
  note "keeping the network settings of the existing install ($PREV_MODE, ingress ${INGRESS:-default})"
fi
[[ -z "$ACR" ]] && ACR=$(prev acrResourceId)
# Access rules and DNS choices carry over too: an upgrade must never reopen an app that was
# limited to the agency's addresses, or recreate a DNS zone the hub hosts.
PREV_ALLOWED=$(prev allowedIngressCidrs)
PREV_DNS_LINKS=$(prev dnsZoneLinkVnetIds)
[[ -z "$ENV_DNS" ]] && ENV_DNS=$(prev createEnvironmentDnsZone)
[[ -z "$ENV_DNS" ]] && ENV_DNS="true"
[[ -z "$APP_ID" ]] && APP_ID=$(prev entraClientId)

# The previous template ran Postgres with a public endpoint and password auth. Its network
# mode cannot be changed in place; say so rather than failing half-way.
if [[ -z "$PREV_MODE" ]]; then
  LEGACY=$(az postgres flexible-server list -g "$RG" --query "[?network.publicNetworkAccess=='Enabled'].name | [0]" -o tsv 2>/dev/null || true)
  if [[ -n "$LEGACY" ]]; then
    die "resource group $RG holds an earlier Calisto install whose Postgres server ($LEGACY) has a public
       endpoint. A server cannot be moved into a VNet in place. Export the data (pg_dump), tear the old
       stack down (RUNNING.md, Teardown), re-run this installer, and restore. See RUNNING.md, Upgrade."
  fi
fi

# ---------------------------------------------------------------------------------------
# Network parameters
# ---------------------------------------------------------------------------------------
NET_PARAMS=()
if [[ -n "$INFRA_SUBNET$DB_SUBNET" ]]; then
  [[ -n "$INFRA_SUBNET" && -n "$DB_SUBNET" ]] || die "bring-your-own network needs both --infrastructure-subnet and --db-subnet."
  # Check the subnets now: a wrong delegation or size otherwise fails deep in the deployment.
  check_subnet() {
    local id="$1" want="$2" min="$3" js deleg prefix bits
    js=$(az network vnet subnet show --ids "$id" -o json 2>/dev/null) || die "cannot read subnet $id (does it exist, and can you read it?)"
    deleg=$(jq -r '[.delegations[]?.serviceName] | join(",")' <<<"$js")
    prefix=$(jq -r '.addressPrefix // .addressPrefixes[0]' <<<"$js")
    bits=${prefix#*/}
    [[ "$deleg" == "$want" ]] || die "subnet $id must be delegated to $want (it has '${deleg:-none}')."
    (( bits <= min )) || die "subnet $id is /$bits; it must be /$min or larger."
    echo "$prefix"
  }
  APP_CIDR=$(check_subnet "$INFRA_SUBNET" Microsoft.App/environments 27)
  DB_CIDR=$(check_subnet "$DB_SUBNET" Microsoft.DBforPostgreSQL/flexibleServers 28)
  if [[ -n "$DB_DNS_ZONE" ]]; then
    ZONE_NAME="${DB_DNS_ZONE##*/}"
    [[ "$ZONE_NAME" == *.postgres.database.azure.com ]] \
      || die "--db-dns-zone must be a private DNS zone ending in .postgres.database.azure.com (got $ZONE_NAME)."
    if [[ "$ZONE_NAME" == privatelink.postgres.database.azure.com ]]; then
      note "WARNING: privatelink.postgres.database.azure.com is the private-endpoint zone. A VNet-integrated"
      note "         server is better given its own zone (for example private.postgres.database.azure.com)."
    fi
  fi
  NET_PARAMS+=(networkMode=byo infrastructureSubnetId="$INFRA_SUBNET" dbDelegatedSubnetId="$DB_SUBNET")
  [[ -n "$DB_DNS_ZONE" ]] && NET_PARAMS+=(dbPrivateDnsZoneId="$DB_DNS_ZONE")
  NET_PARAMS+=(ingress="${INGRESS:-internal}")
else
  APP_CIDR=""; DB_CIDR=""
  NET_PARAMS+=(networkMode=managed ingress="${INGRESS:-external}")
  [[ -n "$MANAGED_PREFIX" ]] && NET_PARAMS+=(managedVnetPrefix="$MANAGED_PREFIX")
fi
NET_PARAMS+=(createEnvironmentDnsZone="$ENV_DNS")
if [[ ${#DNS_LINKS[@]} -gt 0 ]]; then
  NET_PARAMS+=(dnsZoneLinkVnetIds="$(printf '%s\n' "${DNS_LINKS[@]}" | jq -R . | jq -sc .)")
elif [[ -n "$PREV_DNS_LINKS" && "$PREV_DNS_LINKS" != "[]" ]]; then
  NET_PARAMS+=(dnsZoneLinkVnetIds="$PREV_DNS_LINKS")
fi
if [[ -n "$ALLOWED_INGRESS" ]]; then
  NET_PARAMS+=(allowedIngressCidrs="$(tr ',' '\n' <<<"$ALLOWED_INGRESS" | jq -R . | jq -sc .)")
elif [[ -n "$PREV_ALLOWED" && "$PREV_ALLOWED" != "[]" ]]; then
  NET_PARAMS+=(allowedIngressCidrs="$PREV_ALLOWED")
  note "keeping the allowed ingress addresses: $(jq -r 'join(", ")' <<<"$PREV_ALLOWED")"
fi

# ---------------------------------------------------------------------------------------
# Rights check: say up front what will need a privileged administrator.
# ---------------------------------------------------------------------------------------
echo "==> [1/5] Checking your rights"
ME=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -n "$ME" && "$GRANT_READER" == "true" ]]; then
  CAN_ASSIGN=$(az role assignment list --assignee "$ME" --scope "/subscriptions/$SUB" --include-inherited --include-groups \
    --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='User Access Administrator' || roleDefinitionName=='Role Based Access Control Administrator'] | length(@)" \
    -o tsv 2>/dev/null || echo 0)
  if [[ "${CAN_ASSIGN:-0}" == "0" ]]; then
    GRANT_READER="false"
    note "you cannot write role assignments on this subscription (no active Owner, User Access Administrator"
    note "or RBAC Administrator role). Reader on this subscription is left to the Permissions page."
  fi
fi

for ns in Microsoft.App Microsoft.DBforPostgreSQL Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.Network; do
  az provider register -n "$ns" -o none 2>/dev/null || note "could not register resource provider $ns; ask a subscription Owner if the deployment reports it."
done

# ---------------------------------------------------------------------------------------
# Image: resolve to a digest, verify, import.
# ---------------------------------------------------------------------------------------
echo "==> [2/5] Container image"
[[ "$IMAGE" == ghcr.io/* ]] || die "--image must be a ghcr.io reference (use --acr to run from your own registry)."
REPO_REF="${IMAGE#ghcr.io/}"
if [[ "$REPO_REF" == *@sha256:* ]]; then
  REPO="${REPO_REF%@*}"; DIGEST="${REPO_REF#*@}"; TAG="${REPO##*:}"; [[ "$TAG" == "$REPO" ]] && TAG=""; REPO="${REPO%:*}"
else
  REPO="${REPO_REF%:*}"; TAG="${REPO_REF##*:}"; [[ "$TAG" == "$REPO_REF" ]] && TAG="latest"
  TOKEN=$(curl -sf "https://ghcr.io/token?scope=repository:${REPO}:pull&service=ghcr.io" | jq -r .token) \
    || die "could not get an anonymous pull token for ghcr.io/$REPO (is the package public, and is ghcr.io reachable?)."
  DIGEST=$(curl -sfI -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${REPO}/manifests/${TAG}" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
  [[ "$DIGEST" == sha256:* ]] || die "could not resolve ghcr.io/$REPO:$TAG to a digest."
fi
SOURCE="ghcr.io/${REPO}@${DIGEST}"
note "image $SOURCE${TAG:+ (tag $TAG)}"

if [[ "$VERIFY" == "true" ]]; then
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)  CS_ARCH=amd64; CS_SUM="$COSIGN_SHA256_LINUX_AMD64";;
    Linux/aarch64) CS_ARCH=arm64; CS_SUM="$COSIGN_SHA256_LINUX_ARM64";;
    *) die "--verify downloads a Linux cosign build; run it from Azure Cloud Shell.";;
  esac
  curl -sfL -o "$WORK/cosign" "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${CS_ARCH}" \
    || die "could not download cosign $COSIGN_VERSION."
  echo "$CS_SUM  $WORK/cosign" | sha256sum -c --quiet - || die "cosign download failed its checksum; not using it."
  chmod +x "$WORK/cosign"
  "$WORK/cosign" verify "$SOURCE" \
    --certificate-identity-regexp "$SIGNER_IDENTITY_REGEXP" --certificate-oidc-issuer "$SIGNER_ISSUER" >/dev/null \
    || die "signature verification failed for $SOURCE; not deploying it."
  note "signature verified: signed by the Calisto release workflow"
fi

DEPLOY_IMAGE="$SOURCE"
ACR_ID=""
if [[ -n "$ACR" ]]; then
  if [[ "$ACR" == /subscriptions/* ]]; then ACR_ID="$ACR"; else ACR_ID=$(az acr show -n "$ACR" --query id -o tsv) || die "registry $ACR not found in this subscription; pass its resource id."; fi
  ACR_NAME="${ACR_ID##*/}"
  ACR_SUB=$(cut -d/ -f3 <<<"$ACR_ID")
  LOGIN_SERVER=$(az acr show --ids "$ACR_ID" --query loginServer -o tsv)
  IMPORT_TAG="${TAG:-pinned-${DIGEST#sha256:}}"; IMPORT_TAG="${IMPORT_TAG:0:40}"
  # Import is a server-side copy (the registry fetches from ghcr.io, not Cloud Shell or the
  # app), so it works for a registry behind a private endpoint too. The digest is preserved.
  az acr import -n "$ACR_NAME" --subscription "$ACR_SUB" --source "$SOURCE" --image "calisto:${IMPORT_TAG}" --force -o none \
    || die "az acr import into $ACR_NAME failed (needs Contributor on the registry)."
  # Reading the tag back is a data-plane call, which a private-only registry refuses from
  # Cloud Shell; the source digest is then used, which import preserves.
  ACR_DIGEST=$(az acr repository show -n "$ACR_NAME" --subscription "$ACR_SUB" --image "calisto:${IMPORT_TAG}" --query digest -o tsv 2>/dev/null || true)
  if [[ -z "$ACR_DIGEST" ]]; then
    ACR_DIGEST="$DIGEST"
  elif [[ "$ACR_DIGEST" != "$DIGEST" ]]; then
    note "WARNING: the registry reports digest $ACR_DIGEST for the import (source $DIGEST); deploying the registry's."
  fi
  DEPLOY_IMAGE="${LOGIN_SERVER}/calisto@${ACR_DIGEST}"
  note "imported into $LOGIN_SERVER; the app pulls with its managed identity (AcrPull)"
fi

# ---------------------------------------------------------------------------------------
# Entra sign-in app: app roles, no secret.
# ---------------------------------------------------------------------------------------
echo "==> [3/5] Entra sign-in app registration"
cat > "$WORK/roles.json" <<'EOF'
[
  {"id":"c2dccb69-9161-42a4-ae26-7d4677f9c781","value":"Calisto.Viewer","displayName":"Calisto Viewer","description":"Read assessments, ratings, evidence and reports. Cannot record findings or change anything.","allowedMemberTypes":["User"],"isEnabled":true},
  {"id":"35a7a1e3-add8-48c0-a496-40abfaf0d214","value":"Calisto.Assessor","displayName":"Calisto Assessor","description":"Plan assessments, run scans, record findings and conclusions, maintain the asset register.","allowedMemberTypes":["User"],"isEnabled":true},
  {"id":"abbccc5d-290d-43dc-ac56-5f6f89c0888b","value":"Calisto.Approver","displayName":"Calisto Approver","description":"Approve assessment plans and finalise outcomes, as well as everything a Viewer can do.","allowedMemberTypes":["User"],"isEnabled":true},
  {"id":"45665900-81c2-4cbc-bd5b-003c0b7a8c41","value":"Calisto.Admin","displayName":"Calisto Administrator","description":"Administer Calisto: settings, scopes and every action of the other roles.","allowedMemberTypes":["User"],"isEnabled":true}
]
EOF
# Delegated openid, profile and email on Microsoft Graph: sign-in only.
cat > "$WORK/rra.json" <<'EOF'
[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[
  {"id":"37f7f235-527c-4136-accd-4a02d197296e","type":"Scope"},
  {"id":"14dad69e-099b-42c9-810b-d002981feec1","type":"Scope"},
  {"id":"64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0","type":"Scope"}]}]
EOF
APP_NAME="Calisto"
# --display-name matches by prefix; an exact OData match keeps "Calisto (...)" apart from "Calisto".
app_named() { local q="'"; az ad app list --filter "displayName eq '${1//$q/$q$q}'" --query "[0].appId" -o tsv 2>/dev/null || true; }
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(app_named "$APP_NAME")
  # The app named Calisto may already sign in another install in this tenant (a test and a
  # production one, say). Taking it over would repoint its sign-in here and lock that one out,
  # so this install gets its own app instead.
  if [[ -n "$APP_ID" ]]; then
    OTHER_MI=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='calisto-managed-identity'].subject | [0]" -o tsv 2>/dev/null || true)
    if [[ -n "$OTHER_MI" ]] && az ad sp show --id "$OTHER_MI" >/dev/null 2>&1; then
      OTHER_URL=$(az ad app show --id "$APP_ID" --query "web.redirectUris[?ends_with(@, '/login/oauth2/code/entra')] | [0]" -o tsv 2>/dev/null || true)
      note "the app named Calisto already signs in another install (${OTHER_URL%/login/oauth2/code/entra}); leaving it alone"
      APP_NAME="Calisto ($SUB_NAME)"
      APP_ID=$(app_named "$APP_NAME")
    fi
  fi
fi
# A name lookup can return a soft-deleted app that no longer resolves; only reuse a live one.
if [[ -n "$APP_ID" ]] && ! az ad app show --id "$APP_ID" >/dev/null 2>&1; then
  APP_ID=""
fi
if [[ -z "$APP_ID" ]]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "https://localhost/login/oauth2/code/entra" \
    --app-roles @"$WORK/roles.json" --required-resource-accesses @"$WORK/rra.json" --query appId -o tsv) \
    || die "could not create the app registration (your tenant may restrict app registration). Ask an
       Application Administrator to create an app named Calisto and re-run with --app-id <its client id>."
else
  az ad app update --id "$APP_ID" --app-roles @"$WORK/roles.json" --required-resource-accesses @"$WORK/rra.json" \
    || note "WARNING: could not update app roles on $APP_ID (are you an owner of it?)."
fi
az ad sp create --id "$APP_ID" -o none 2>/dev/null || true
APP_SP=$(az ad sp show --id "$APP_ID" --query id -o tsv)
# Only users (or groups) assigned an app role may sign in.
az ad sp update --id "$APP_ID" --set appRoleAssignmentRequired=true -o none \
  || note "WARNING: could not require assignment on the Calisto enterprise app; set 'Assignment required' in the portal."
# Consent to the sign-in scopes (openid profile email) for the whole organisation, so assigned
# users are not asked for admin approval when user consent is off, as it is in hardened tenants.
GRAPH_SP=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv 2>/dev/null || true)
if [[ -n "$GRAPH_SP" ]]; then
  SIGNIN_GRANT=$(az rest --method get --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$APP_SP' and resourceId eq '$GRAPH_SP' and consentType eq 'AllPrincipals'" \
    --query "value[0].id" -o tsv 2>/dev/null || true)
  if [[ -n "$SIGNIN_GRANT" ]]; then
    az rest --method patch --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$SIGNIN_GRANT" \
      --body '{"scope":"openid profile email"}' -o none 2>/dev/null || true
  elif ! az rest --method post --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
      --body "{\"clientId\":\"$APP_SP\",\"consentType\":\"AllPrincipals\",\"resourceId\":\"$GRAPH_SP\",\"scope\":\"openid profile email\"}" -o none 2>/dev/null; then
    note "WARNING: could not consent to Calisto's sign-in for your organisation. Grant admin consent on the"
    note "         Calisto app's API permissions page, or other users will be asked for admin approval."
  fi
fi
APP_NAME=$(az ad app show --id "$APP_ID" --query displayName -o tsv 2>/dev/null || echo "$APP_NAME")
note "app $APP_NAME ($APP_ID)"

# ---------------------------------------------------------------------------------------
# Deploy the stack.
# ---------------------------------------------------------------------------------------
echo "==> [4/5] Deploying the Calisto stack (Container App, Postgres, network, logs)"
az group create -n "$RG" -l "$REGION" -o none
if [[ -z "$TEMPLATE" ]]; then
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/azuredeploy.json" ]]; then
    TEMPLATE="$SCRIPT_DIR/azuredeploy.json"
  else
    TEMPLATE="$WORK/azuredeploy.json"
    curl -sfL "$BASE/azuredeploy.json" -o "$TEMPLATE" || die "could not download $BASE/azuredeploy.json"
  fi
fi

# Keep AWS settings across an upgrade unless new ones are given.
[[ -z "$AWS_ROLE_ARN" ]] && AWS_ROLE_ARN=$(prev awsRoleArn)
[[ -z "$AWS_ACCOUNTS" ]] && AWS_ACCOUNTS=$(prev awsAccounts)
[[ -z "$AWS_REGIONS" ]] && AWS_REGIONS=$(prev awsRegions)
[[ -z "$AWS_MEMBER_ROLE" ]] && AWS_MEMBER_ROLE=$(prev awsMemberRole)
[[ -z "$LOG_RETENTION" ]] && LOG_RETENTION=$(prev logRetentionDays)

PARAMS=(location="$REGION" entraTenantId="$TENANT" entraClientId="$APP_ID" image="$DEPLOY_IMAGE"
        grantSubscriptionReader="$GRANT_READER" "${NET_PARAMS[@]}")
[[ -n "$ACR_ID" ]] && PARAMS+=(acrResourceId="$ACR_ID")
[[ -n "$LOG_RETENTION" ]] && PARAMS+=(logRetentionDays="$LOG_RETENTION")
if [[ -n "$AWS_ROLE_ARN" ]]; then
  PARAMS+=(awsEnabled=true awsRoleArn="$AWS_ROLE_ARN" awsAccounts="$AWS_ACCOUNTS" awsRegions="$AWS_REGIONS")
  [[ -n "$AWS_MEMBER_ROLE" ]] && PARAMS+=(awsMemberRole="$AWS_MEMBER_ROLE")
fi

az stack group create --name "$STACK" --resource-group "$RG" \
  --template-file "$TEMPLATE" --parameters "${PARAMS[@]}" \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes -o none

OUT=$(az stack group show -g "$RG" -n "$STACK" --query outputs -o json)
out() { jq -r --arg k "$1" '.[$k].value // empty' <<<"$OUT"; }
APP_URL=$(out appUrl)
MI_OBJ=$(out managedIdentityPrincipalId)
INGRESS_MODE=$(out ingressMode)

# ---------------------------------------------------------------------------------------
# Sign-in: federated credential (managed identity as the app's credential), redirect URI,
# remove any client secret an earlier install created, assign the installer Calisto.Admin.
# ---------------------------------------------------------------------------------------
echo "==> [5/5] Sign-in without a client secret"
cat > "$WORK/fic.json" <<EOF
{"name":"calisto-managed-identity","issuer":"https://login.microsoftonline.com/$TENANT/v2.0","subject":"$MI_OBJ",
 "audiences":["api://AzureADTokenExchange"],"description":"Calisto's user-assigned managed identity signs the app in (client assertion)."}
EOF
if [[ -n "$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='calisto-managed-identity'].name" -o tsv 2>/dev/null)" ]]; then
  az ad app federated-credential update --id "$APP_ID" --federated-credential-id calisto-managed-identity --parameters @"$WORK/fic.json" -o none
else
  az ad app federated-credential create --id "$APP_ID" --parameters @"$WORK/fic.json" -o none
fi
az ad app update --id "$APP_ID" --web-redirect-uris "$APP_URL/login/oauth2/code/entra" \
  "$APP_URL/grant/callback/grant-graph" "$APP_URL/grant/callback/grant-arm" \
  || note "WARNING: could not set the redirect URI on app $APP_ID"
for key in $(az ad app credential list --id "$APP_ID" --query "[].keyId" -o tsv 2>/dev/null); do
  az ad app credential delete --id "$APP_ID" --key-id "$key" -o none && note "removed client secret $key"
done

ADMIN_ROLE="45665900-81c2-4cbc-bd5b-003c0b7a8c41"
ADMIN_ASSIGNED="false"
if [[ -n "$ME" ]]; then
  ERR="$WORK/err"
  if az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP/appRoleAssignedTo" \
       --headers Content-Type=application/json \
       --body "{\"principalId\":\"$ME\",\"resourceId\":\"$APP_SP\",\"appRoleId\":\"$ADMIN_ROLE\"}" -o none 2>"$ERR" \
     || grep -qi "already exists" "$ERR"; then
    ADMIN_ASSIGNED="true"; note "you are assigned Calisto.Admin"
  fi
fi

# ---------------------------------------------------------------------------------------
cat <<EOF

==> Calisto is deployed.
    URL:       $APP_URL  (ingress: $INGRESS_MODE)
    Image:     $DEPLOY_IMAGE
    Identity:  managed identity object id $MI_OBJ
    Sign-in:   app $APP_ID; only users assigned a Calisto role can sign in.
EOF
if [[ "$INGRESS_MODE" == internal ]]; then
  cat <<EOF
    Network:   internal. The app resolves through the private DNS zone $(out environmentDefaultDomain)
               (-> $(out environmentStaticIp)). If your spokes use a central DNS resolver, link that zone
               to the resolver's VNet (--dns-link-vnet <hub-vnet-id>) or host the zone in the hub.
EOF
fi
cat <<EOF

    Assign roles (Calisto.Viewer, Calisto.Assessor, Calisto.Approver, Calisto.Admin):
      Portal: Entra ID > Enterprise applications > $APP_NAME > Users and groups > Add user/group
      CLI:    az rest --method POST \\
                --uri https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP/appRoleAssignedTo \\
                --body '{"principalId":"<user-or-group-object-id>","resourceId":"$APP_SP","appRoleId":"<role-id>"}'
              role ids: Viewer c2dccb69-9161-42a4-ae26-7d4677f9c781, Assessor 35a7a1e3-add8-48c0-a496-40abfaf0d214,
                        Approver abbccc5d-290d-43dc-ac56-5f6f89c0888b, Admin 45665900-81c2-4cbc-bd5b-003c0b7a8c41
EOF
if [[ "$ADMIN_ASSIGNED" != "true" ]]; then
  echo "      You were NOT assigned Calisto.Admin (needs owner of the Calisto enterprise app or Cloud Application"
  echo "      Administrator). Have one assign it with the command above (role id 45665900-...)."
fi
cat <<EOF

    Next, in Calisto: Permissions. An administrator makes Calisto's read-only grants there, signed in
    with their own roles (Privileged Role Administrator for Microsoft Graph and Security Reader; Owner,
    User Access Administrator or RBAC Administrator where Reader goes), and connects AWS if the agency
    runs it. Until then the checks that need a missing grant report "no visibility" and name it.
EOF
if [[ -n "$APP_CIDR" ]]; then
  echo
  echo "    Egress through a hub firewall: deploy/hub-firewall-rules.bicep with"
  echo "      appSubnetCidrs='[\"$APP_CIDR\"]' dbSubnetCidrs='[\"$DB_CIDR\"]'"
  echo "    After connecting AWS, download the rules again from the Permissions page: they then"
  echo "    include every AWS region Calisto scans."
fi
cat <<EOF

    Teardown (first remove the identity's role assignments, including Reader at a management group,
    which sit outside the stack and would otherwise be left orphaned):
      az role assignment list --assignee $MI_OBJ --all --query "[].id" -o tsv | xargs -r -n1 az role assignment delete --ids
      az stack group delete --name $STACK -g $RG --action-on-unmanage deleteAll --yes \\
        && az group delete -n $RG --yes && az ad app delete --id $APP_ID
EOF
