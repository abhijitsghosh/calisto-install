// Egress rules for Calisto, for the agency's network team to apply to the hub's Azure
// Firewall Policy. Download it from Calisto's Permissions page (Network reach): the subnets,
// image source, workspace and AWS regions of that deployment are filled in as the parameter
// defaults, so only the policy name is needed. Deploy into the resource group that holds the
// firewall policy:
//
//   az deployment group create -g <hub-rg> --template-file calisto-hub-firewall-rules.bicep \
//     --parameters firewallPolicyName=<policy>
//
// Re-download and re-deploy when the AWS connection's regions change: the group is replaced.
//
// Works the same for a hub VNet firewall and a Virtual WAN secured hub with routing intent:
// both are driven by a Firewall Policy, and routing intent sends the spoke's internet and
// private traffic through it. Creates one rule collection group and nothing else; it does
// not change the policy's other groups.
//
// What is NOT here, on purpose:
//   - Postgres. The app reaches the server inside the spoke VNet (VNet integration), so the
//     traffic never leaves the VNet and never reaches the firewall. No rule needed. The
//     server's own WAL archive to Azure Storage goes through the Microsoft.Storage service
//     endpoint the platform adds to the delegated subnet, which also bypasses the firewall.
//   - Inbound. Users reach an internal-ingress Calisto through the agency's routed network;
//     that is the hub's existing east-west/on-premises policy.
targetScope = 'resourceGroup'

@description('Name of the existing Azure Firewall Policy (in this resource group).')
param firewallPolicyName string

@description('Name of the rule collection group to create.')
param ruleCollectionGroupName string = 'calisto'

@description('Priority of the rule collection group (100-65000). Pick one that fits the policy\'s existing ordering.')
@minValue(100)
@maxValue(65000)
param priority int = 3000

@description('CIDR(s) of Calisto\'s Container Apps environment subnet. Every rule is scoped to these sources.')
param appSubnetCidrs array

@description('CIDR(s) of Calisto\'s Postgres delegated subnet. The server itself calls Entra to validate tokens.')
param dbSubnetCidrs array = []

@description('Image source: ghcr = GitHub Container Registry (default install); acr = the agency\'s Azure Container Registry.')
@allowed(['ghcr', 'acr'])
param imageSource string = 'ghcr'

@description('imageSource=acr without a private endpoint: the registry FQDNs, for example ["myacr.azurecr.io", "myacr.australiaeast.data.azurecr.io"]. Leave empty when the registry is reached through a private endpoint (no firewall rule needed).')
param acrFqdns array = []

@description('Optional. Log Analytics workspace id (customer id GUID) of Calisto\'s workspace, to narrow ingestion to it. Empty allows any workspace\'s ingestion endpoint.')
param logAnalyticsWorkspaceId string = ''

@description('Allow AWS endpoints (Calisto assesses AWS).')
param awsEnabled bool = false

@description('AWS region Calisto treats as home (STS and S3 Control): the home region of the AWS connection on Calisto\'s Permissions page.')
param awsHomeRegion string = 'ap-southeast-2'

@description('AWS regions Calisto scans: the regions of the AWS connection on Calisto\'s Permissions page (every region enabled in the hub account when none are set there). A region that is scanned but not allowed here times out and reports no visibility; Test connections on the same page names it.')
param awsRegions array = ['ap-southeast-2']

@description('Extra AWS regions where the organisation has S3 buckets (bucket-level reads go to the bucket\'s own region). us-east-1 is always included because S3 reports legacy buckets there.')
param awsS3ExtraRegions array = []

@description('Also add network rules for Azure service tags (AzureActiveDirectory, AzureResourceManager, AzureMonitor, MicrosoftContainerRegistry, AzureFrontDoor.FirstParty). The application rules alone are enough when the firewall can see SNI; the tags cover platform traffic that is not plain HTTPS-by-FQDN.')
param includeServiceTagRules bool = true

// --- FQDN sets -------------------------------------------------------------------------

// Entra sign-in, managed-identity token issue, and the federated client assertion.
var entraFqdns = [
  'login.microsoftonline.com'
  '*.login.microsoftonline.com'
  'login.microsoft.com'
  '*.login.microsoft.com'
  '*.identity.azure.net'
]

// Container Apps system containers (Envoy, log agents) come from Microsoft Artifact Registry.
var platformFqdns = [
  'mcr.microsoft.com'
  '*.data.mcr.microsoft.com'
]

var registryFqdns = imageSource == 'ghcr' ? [
  'ghcr.io'
  'pkg-containers.githubusercontent.com'
] : acrFqdns

// Container Apps ships console and system logs to Log Analytics over the ingestion API.
var monitorFqdns = empty(logAnalyticsWorkspaceId) ? [
  '*.ods.opinsights.azure.com'
  '*.oms.opinsights.azure.com'
] : [
  '${logAnalyticsWorkspaceId}.ods.opinsights.azure.com'
  '${logAnalyticsWorkspaceId}.oms.opinsights.azure.com'
]

// AWS services the collectors call per region (src/main/java/au/calisto/aws/AwsClients.java).
// Endpoint prefixes, which are not always the SDK client name: EFS is elasticfilesystem,
// SSO Admin is sso, ELBv2 is elasticloadbalancing, API Gateway v1 and v2 share apigateway, SageMaker is api.sagemaker,
// the Resource Groups Tagging API is tagging.
var awsRegionalServices = [
  'ec2'
  'rds'
  'elasticfilesystem'
  'dynamodb'
  'lambda'
  'ecs'
  'eks'
  'elasticloadbalancing'
  'apigateway'
  'workspaces'
  'secretsmanager'
  'sso'
  'cloudtrail'
  'backup'
  'ssm'
  'guardduty'
  'inspector2'
  'config'
  'securityhub'
  'access-analyzer'
  'wafv2'
  'route53resolver'
  'network-firewall'
  'tagging'
  // AI assets: Bedrock control plane, Bedrock Agents and SageMaker (endpoint prefix api.sagemaker).
  'bedrock'
  'bedrock-agent'
  'api.sagemaker'
]

var awsRegionalFqdns = flatten(map(awsRegions, r => map(awsRegionalServices, s => '${s}.${r}.amazonaws.com')))

var awsS3Regions = union(awsRegions, awsS3ExtraRegions, ['us-east-1'])
// Bucket reads are virtual-hosted (<bucket>.s3.<region>.amazonaws.com), hence the wildcard.
var awsS3Fqdns = concat(
  flatten(map(awsS3Regions, r => ['s3.${r}.amazonaws.com', '*.s3.${r}.amazonaws.com'])),
  ['s3.amazonaws.com', '*.s3.amazonaws.com']
)

var awsGlobalFqdns = [
  // AssumeRoleWithWebIdentity (hub) and AssumeRole (members) use the regional endpoint; the
  // global one is kept for SDK fallbacks.
  'sts.${awsHomeRegion}.amazonaws.com'
  'sts.amazonaws.com'
  // IAM and CloudFront are global services.
  'iam.amazonaws.com'
  'cloudfront.amazonaws.com'
  // Organizations is served only from us-east-1 in the aws partition.
  'organizations.us-east-1.amazonaws.com'
  // S3 Control (account-level Block Public Access): <account-id>.s3-control.<home>.
  '*.s3-control.${awsHomeRegion}.amazonaws.com'
]

var https = [{ protocolType: 'Https', port: 443 }]

var appRules = concat([
  {
    ruleType: 'ApplicationRule'
    name: 'entra-identity'
    description: 'Entra sign-in, managed identity tokens, federated client assertion.'
    sourceAddresses: union(appSubnetCidrs, dbSubnetCidrs)
    protocols: https
    targetFqdns: entraFqdns
  }
  {
    ruleType: 'ApplicationRule'
    name: 'microsoft-graph'
    description: 'Microsoft Graph reads (Entra, Intune, Secure Score, M365).'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: ['graph.microsoft.com']
  }
  {
    ruleType: 'ApplicationRule'
    name: 'azure-resource-manager'
    description: 'ARM and Resource Graph reads.'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: ['management.azure.com']
  }
  {
    ruleType: 'ApplicationRule'
    name: 'container-apps-platform'
    description: 'Container Apps system images.'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: platformFqdns
  }
  {
    ruleType: 'ApplicationRule'
    name: 'log-analytics-ingestion'
    description: 'Container Apps console and system logs to Log Analytics.'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: monitorFqdns
  }
], empty(registryFqdns) ? [] : [
  {
    ruleType: 'ApplicationRule'
    name: 'container-image'
    description: 'Calisto image pull.'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: registryFqdns
  }
], awsEnabled ? [
  {
    ruleType: 'ApplicationRule'
    name: 'aws-global'
    description: 'AWS STS, IAM, Organizations, CloudFront, S3 Control.'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: awsGlobalFqdns
  }
  {
    ruleType: 'ApplicationRule'
    name: 'aws-regional'
    description: 'AWS read-only service APIs in the scanned regions.'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: awsRegionalFqdns
  }
  {
    ruleType: 'ApplicationRule'
    name: 'aws-s3'
    description: 'S3 bucket configuration reads (never object contents).'
    sourceAddresses: appSubnetCidrs
    protocols: https
    targetFqdns: awsS3Fqdns
  }
] : [])

var tagRules = [
  {
    ruleType: 'NetworkRule'
    name: 'tag-entra'
    sourceAddresses: union(appSubnetCidrs, dbSubnetCidrs)
    destinationAddresses: ['AzureActiveDirectory']
    destinationPorts: ['443']
    ipProtocols: ['TCP']
  }
  {
    ruleType: 'NetworkRule'
    name: 'tag-arm'
    sourceAddresses: appSubnetCidrs
    destinationAddresses: ['AzureResourceManager']
    destinationPorts: ['443']
    ipProtocols: ['TCP']
  }
  {
    ruleType: 'NetworkRule'
    name: 'tag-monitor'
    sourceAddresses: appSubnetCidrs
    destinationAddresses: ['AzureMonitor']
    destinationPorts: ['443']
    ipProtocols: ['TCP']
  }
  {
    ruleType: 'NetworkRule'
    name: 'tag-mcr'
    sourceAddresses: appSubnetCidrs
    destinationAddresses: ['MicrosoftContainerRegistry', 'AzureFrontDoor.FirstParty']
    destinationPorts: ['443']
    ipProtocols: ['TCP']
  }
]

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' existing = {
  name: firewallPolicyName
}

resource rcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: ruleCollectionGroupName
  properties: {
    priority: priority
    // Network rules are evaluated before application rules within a policy.
    ruleCollections: concat(includeServiceTagRules ? [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'calisto-network'
        priority: 100
        action: { type: 'Allow' }
        rules: tagRules
      }
    ] : [], [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'calisto-application'
        priority: 200
        action: { type: 'Allow' }
        rules: appRules
      }
    ])
  }
}

output allowedFqdns array = flatten(map(appRules, r => r.targetFqdns))
