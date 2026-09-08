[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$subscription = '121e2ce8-c399-4fea-958a-09d15ed949c4'
$tenant = '13b2a159-de04-4835-a3ad-fd814c6adb4f'
$organization = 'https://dev.azure.com/microsoft-avm-end-to-end-tests'
$project = 'terraform-backend-env-e2e-36922'
$projectId = '15943cc9-7f9d-439c-9b86-24944906e81c'
$group = 'rg-tf36922-e8195f-state'
$endpoints = @{}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
foreach ($purpose in 'state', 'provider') {
    $identity = az identity show --subscription $subscription --resource-group $group `
        --name "id-tf36922-$purpose" -o json | ConvertFrom-Json
    if ($identity.tenantId -ne $tenant) { throw 'Unexpected identity tenant.' }
    $name = "sc-tf36922-$purpose"
    $existing = @(az devops service-endpoint list --organization $organization `
        --project $project -o json | ConvertFrom-Json | Where-Object name -EQ $name)
    if ($existing.Count -gt 1) { throw "Multiple service connections named $name." }
    if ($existing.Count -eq 1) {
        $endpoint = az devops service-endpoint show --id $existing[0].id `
            --organization $organization --project $project -o json | ConvertFrom-Json
        if ($endpoint.authorization.parameters.serviceprincipalid -ne $identity.clientId) {
            throw "Existing connection $name points to another identity."
        }
    } else {
        $config = @{
            data = @{
                subscriptionId = $subscription
                subscriptionName = 'sub-avm-tf-testing-021'
                environment = 'AzureCloud'
                scopeLevel = 'Subscription'
                creationMode = 'Manual'
            }
            name = $name
            type = 'AzureRM'
            url = 'https://management.azure.com/'
            authorization = @{
                scheme = 'WorkloadIdentityFederation'
                parameters = @{ tenantid = $tenant; serviceprincipalid = $identity.clientId }
            }
            isShared = $false
            isReady = $true
            serviceEndpointProjectReferences = @(@{
                projectReference = @{ id = $projectId; name = $project }
                name = $name
            })
        }
        $configPath = Join-Path $OutputDirectory "$purpose-connection-request.json"
        $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
        $endpoint = az devops service-endpoint create --service-endpoint-configuration $configPath `
            --organization $organization --project $project -o json | ConvertFrom-Json
    }
    $auth = $endpoint.authorization.parameters
    if (-not $auth.workloadIdentityFederationIssuer -or -not $auth.workloadIdentityFederationSubject) {
        throw "No federation issuer/subject returned for $name."
    }
    $endpoints[$purpose] = @{
        id = $endpoint.id
        name = $name
        clientId = $identity.clientId
        issuer = $auth.workloadIdentityFederationIssuer
        subject = $auth.workloadIdentityFederationSubject
    }
}
$endpoints | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'connections.json')
$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        stateIssuer = @{ value = $endpoints.state.issuer }
        stateSubject = @{ value = $endpoints.state.subject }
        providerIssuer = @{ value = $endpoints.provider.issuer }
        providerSubject = @{ value = $endpoints.provider.subject }
    }
}
$parameters | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'ado-federation.parameters.json')
$endpoints | ConvertTo-Json -Depth 5
