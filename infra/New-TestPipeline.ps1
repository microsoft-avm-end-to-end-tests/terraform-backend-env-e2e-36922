[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('default', 'strict')]
    [string] $Mode,
    [Parameter(Mandatory)]
    [string] $YamlPath,
    [ValidateSet('same-tenant', 'cross-tenant')]
    [string] $Topology = 'same-tenant',
    [string] $CsutfClientId,
    [string] $CsutfObjectId,
    [string] $CsutfConnectionId,
    [switch] $ConfigureExisting
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$organization = 'https://dev.azure.com/microsoft-avm-end-to-end-tests'
$project = 'terraform-backend-env-e2e-36922'
$subscription = '121e2ce8-c399-4fea-958a-09d15ed949c4'
$name = "tf36922-ado-$Mode"
if ($Topology -eq 'cross-tenant') {
    if (-not $CsutfClientId -or -not $CsutfObjectId -or -not $CsutfConnectionId) {
        throw 'Cross-tenant pipelines require the newly provisioned CSUTF client, object and connection IDs.'
    }
    $name = "tf36922-ado-cross-$Mode"
}
$existing = @(az pipelines list --organization $organization --project $project `
    --name $name -o json | ConvertFrom-Json)
if ($ConfigureExisting) {
    if ($existing.Count -ne 1) { throw "Expected exactly one prepared pipeline named $name." }
    $definition = $existing[0]
} else {
    if ($existing.Count) { throw "Pipeline $name already exists; inspect before updating." }
    $definition = az pipelines create --name $name --repository $project `
        --repository-type tfsgit --branch main --yaml-path $YamlPath --skip-first-run `
        --organization $organization --project $project -o json | ConvertFrom-Json
}
$token = az account get-access-token --subscription $subscription `
    --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token" }
$base = "$organization/$project"
$definitionUri = "$base/_apis/build/definitions/$($definition.id)?api-version=7.1"
$definition = Invoke-RestMethod -Headers $headers -Uri $definitionUri
if ($definition.repository.id -ne 'df3508b4-890d-40b0-890b-8a39b0660f64' -or
    $definition.process.yamlFilename -ne $YamlPath) {
    throw 'Pipeline repository or YAML does not match this isolated harness.'
}
$values = @{
    AZAPI_CLIENT_ID = 'b1c4b1f6-46bc-43ff-8109-55f4d2b6cc33'
    AZAPI_OBJECT_ID = '4018377b-0c35-4934-8498-23d83f0fa11a'
    AZAPI_TENANT_ID = '13b2a159-de04-4835-a3ad-fd814c6adb4f'
    AZAPI_SUBSCRIPTION_ID = $subscription
    STATE_CLIENT_ID = '4387b74e-0954-4630-a230-4c3a766c2b34'
    STATE_TENANT_ID = '13b2a159-de04-4835-a3ad-fd814c6adb4f'
    STATE_SUBSCRIPTION_ID = $subscription
    STATE_STORAGE_ACCOUNT_NAME = 'sttf36922e8195f'
    STATE_CONTAINER_NAME = 'tfstate'
    STATE_KEY = 'tf36922'
}
$variables = @{}
if ($Topology -eq 'cross-tenant') {
    $values.CSUTF_AZAPI_CLIENT_ID = $CsutfClientId
    $values.CSUTF_AZAPI_OBJECT_ID = $CsutfObjectId
    $values.CSUTF_AZAPI_TENANT_ID = 'dac8feee-8768-4fbd-9cf9-9d96d4718018'
    $values.CSUTF_AZAPI_SUBSCRIPTION_ID = '66bd4c09-0b95-49f7-9db1-a8f69c54e827'
}
foreach ($key in $values.Keys) {
    $variables[$key] = @{ value = $values[$key]; isSecret = $false; allowOverride = $false }
}
$definition | Add-Member -NotePropertyName variables -NotePropertyValue $variables -Force
$definition = Invoke-RestMethod -Method Put -Headers $headers -ContentType 'application/json' `
    -Uri $definitionUri -Body ($definition | ConvertTo-Json -Depth 100)
$providerConnectionId = if ($Topology -eq 'cross-tenant') { $CsutfConnectionId } else { 'bbfc21fb-7bc1-47b2-9578-89a4445edb31' }
foreach ($endpointId in 'a772cbab-ead7-4c84-93bf-24a22ec6ab3c', $providerConnectionId) {
    $body = @{ pipelines = @(@{ id = $definition.id; authorized = $true }) } | ConvertTo-Json -Depth 5
    $null = Invoke-RestMethod -Method Patch -Headers $headers -ContentType 'application/json' `
        -Uri "$base/_apis/pipelines/pipelinepermissions/endpoint/${endpointId}?api-version=7.1-preview.1" -Body $body
}
if ($ConfigureExisting) {
    $definition = Invoke-RestMethod -Headers $headers -Uri $definitionUri
    $definition.queueStatus = 'enabled'
    $definition = Invoke-RestMethod -Method Put -Headers $headers -ContentType 'application/json' `
        -Uri $definitionUri -Body ($definition | ConvertTo-Json -Depth 100)
}
$definition | Select-Object id, name, url | ConvertTo-Json
