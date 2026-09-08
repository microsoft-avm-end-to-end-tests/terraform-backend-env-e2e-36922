[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('default', 'strict')]
    [string] $Mode,
    [Parameter(Mandatory)]
    [string] $YamlPath
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$organization = 'https://dev.azure.com/microsoft-avm-end-to-end-tests'
$project = 'terraform-backend-env-e2e-36922'
$subscription = '121e2ce8-c399-4fea-958a-09d15ed949c4'
$name = "tf36922-ado-$Mode"
$existing = @(az pipelines list --organization $organization --project $project `
    --name $name -o json | ConvertFrom-Json)
if ($existing.Count) { throw "Pipeline $name already exists; inspect before updating." }
$definition = az pipelines create --name $name --repository $project `
    --repository-type tfsgit --branch main --yaml-path $YamlPath --skip-first-run `
    --organization $organization --project $project -o json | ConvertFrom-Json
$token = az account get-access-token --subscription $subscription `
    --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token" }
$base = "$organization/$project"
foreach ($endpointId in 'a772cbab-ead7-4c84-93bf-24a22ec6ab3c', 'bbfc21fb-7bc1-47b2-9578-89a4445edb31') {
    $body = @{ pipelines = @(@{ id = $definition.id; authorized = $true }) } | ConvertTo-Json -Depth 5
    $null = Invoke-RestMethod -Method Patch -Headers $headers -ContentType 'application/json' `
        -Uri "$base/_apis/pipelines/pipelinepermissions/endpoint/${endpointId}?api-version=7.1-preview.1" -Body $body
}
$definition | Select-Object id, name, url | ConvertTo-Json
