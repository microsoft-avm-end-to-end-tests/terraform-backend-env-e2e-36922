$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
$script:CoreRepository = 'https://github.com/jaredfholgate/terraform.git'
$script:CoreCommit = 'e8195f605d24299788cdf36738915d84563e4c58'
$script:GoVersion = '1.26.4'
$script:DocsCommit = 'd55950c86e2dc3757df3b7bd2279b0cf96fe1679'
$script:DocsRelativePath = 'content/terraform/v1.16.x/docs/language/backend/azurerm.mdx'
$script:Modes = [ordered]@{
    'gh-default' = 'GitHub Actions with separate identities in non-strict mode'
    'gh-strict' = 'GitHub Actions with separate identities in strict mode'
    'ado-default' = 'Azure Pipelines with separate identities in non-strict mode'
    'ado-strict' = 'Azure Pipelines with separate identities in strict mode'
}

function ConvertTo-Lf([string] $Text) {
    return $Text.Replace("`r`n", "`n")
}

function Get-TextHash([string] $Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Write-Utf8([string] $Path, [string] $Text) {
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Lf $Text), [Text.UTF8Encoding]::new($false))
}

function Get-RequiredEnvironment([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^\$\(' -or $value -match '[\r\n]') {
        throw "Missing or invalid environment variable: $Name"
    }
    return $value
}

function Assert-Identifier([string] $Value, [string] $Name) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref] $parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be a non-empty GUID."
    }
}

function Assert-Equal([string] $Actual, [string] $Expected, [string] $Label) {
    if ([string]::IsNullOrWhiteSpace($Actual) -or $Actual -ine $Expected) {
        throw "Assertion failed: $Label"
    }
}

function Get-ExpectedIdentities {
    $result = @{}
    foreach ($role in 'AZAPI', 'STATE') {
        foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
            $name = "${role}_${field}"
            $result[$name] = Get-RequiredEnvironment "HARNESS_EXPECTED_$name"
        }
    }
    return $result
}

function Assert-PlanData([System.Collections.IDictionary] $Plan, [System.Collections.IDictionary] $Expected, [string] $Mode) {
    if (-not $script:Modes.Contains($Mode)) { throw 'Unknown fixture mode.' }
    if ($Expected.STATE_CLIENT_ID -ieq $Expected.AZAPI_CLIENT_ID) { throw 'The two identities must differ.' }
    $resources = @($Plan.planned_values.root_module.resources)
    $identity = @($resources | Where-Object { $_.address -eq 'data.azapi_client_config.current' })
    if ($identity.Count -ne 1 -or $identity[0].mode -ne 'data' -or $identity[0].type -ne 'azapi_client_config') {
        throw 'Expected exactly one resolved azapi_client_config data source.'
    }
    $values = $identity[0].values
    Assert-Equal $values.client_id $Expected.AZAPI_CLIENT_ID 'provider client ID from plan'
    Assert-Equal $values.tenant_id $Expected.AZAPI_TENANT_ID 'provider tenant ID from plan'
    Assert-Equal $values.subscription_id $Expected.AZAPI_SUBSCRIPTION_ID 'provider subscription ID from plan'

    $managed = @($resources | Where-Object { $_.mode -eq 'managed' })
    $changes = @($Plan.resource_changes | Where-Object { $_.mode -eq 'managed' })
    if ($managed.Count -ne 1 -or $changes.Count -ne 1 -or $resources.Count -ne 2 -or
        $Plan.planned_values.root_module.child_modules) {
        throw 'The fixture must plan only its one resource group and identity data source.'
    }
    $group = "rg-tf36922-e8195f-$Mode"
    Assert-Equal $managed[0].address 'azapi_resource.example' 'resource address'
    Assert-Equal $managed[0].type 'azapi_resource' 'resource Terraform type'
    Assert-Equal $managed[0].values.type 'Microsoft.Resources/resourceGroups@2024-03-01' 'resource ARM type'
    Assert-Equal $managed[0].values.name $group 'resource group name'
    Assert-Equal $managed[0].values.location 'westeurope' 'resource location'
    Assert-Equal $managed[0].values.parent_id "/subscriptions/$($Expected.AZAPI_SUBSCRIPTION_ID)" 'resource subscription'
    Assert-Equal $changes[0].address 'azapi_resource.example' 'resource change address'
    if (@($changes[0].change.actions).Count -ne 1 -or $changes[0].change.actions[0] -ne 'create') {
        throw 'Expected a create-only preview against an empty, unique backend key.'
    }
    if ($Plan.errored -eq $true -or $Plan.applyable -eq $false) { throw 'Plan is not a valid change preview.' }
    return [ordered]@{
        mode = $Mode
        coreCommit = $script:CoreCommit
        docsCommit = $script:DocsCommit
        result = 'passed'
        operations = @('init', 'plan', 'show-json-in-memory')
        applied = $false
        provider = [ordered]@{
            clientId = $values.client_id
            tenantId = $values.tenant_id
            subscriptionId = $values.subscription_id
        }
        backendExpected = [ordered]@{
            clientId = $Expected.STATE_CLIENT_ID
            tenantId = $Expected.STATE_TENANT_ID
            subscriptionId = $Expected.STATE_SUBSCRIPTION_ID
        }
        plannedResource = [ordered]@{
            address = 'azapi_resource.example'
            name = $group
            type = $managed[0].values.type
            parentId = $managed[0].values.parent_id
            action = 'create'
        }
    }
}
