$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
$script:CoreRepository = 'https://github.com/jaredfholgate/terraform.git'
$script:CoreCommit = '0c5e9bef8b6d76866b0f0ddedab5b72af51bcc27'
$script:GoVersion = '1.26.4'
$script:DocsCommit = '1281ae9db0b308bf26c12d157b105f189e6681db'
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
    $result = @{ TOPOLOGY = Get-RequiredEnvironment 'HARNESS_EXPECTED_TOPOLOGY' }
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
    $topology = $Expected.TOPOLOGY
    if ($topology -notin 'same-tenant', 'cross-tenant') { throw 'Unknown expected topology.' }
    foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
        foreach ($role in 'STATE', 'AZAPI') { Assert-Identifier $Expected["${role}_$field"] "${role}_$field" }
        $equal = [guid]$Expected["STATE_$field"] -eq [guid]$Expected["AZAPI_$field"]
        $mustDiffer = $field -eq 'CLIENT_ID' -or $topology -eq 'cross-tenant'
        if ($equal -eq $mustDiffer) {
            $relationship = if ($mustDiffer) { 'distinct' } else { 'equal' }
            throw "Backend and provider $field must be $relationship for $topology."
        }
    }
    $expectedObjectId = if ($Expected.Contains('AZAPI_OBJECT_ID')) {
        $Expected.AZAPI_OBJECT_ID
    } else {
        Get-RequiredEnvironment 'HARNESS_EXPECTED_AZAPI_OBJECT_ID'
    }
    Assert-Identifier $expectedObjectId 'AZAPI_OBJECT_ID'
    $provider = 'registry.terraform.io/azure/azapi'
    $address = 'data.azapi_client_config.current'
    $resources = @($Plan.planned_values.root_module.resources | Where-Object { $null -ne $_ })
    $priorValues = if ($Plan.prior_state) { $Plan.prior_state['values'] } else { @{} }
    $prior = @($priorValues.root_module.resources | Where-Object { $null -ne $_ })
    $allChanges = @($Plan.resource_changes | Where-Object { $null -ne $_ })
    if ($Plan.planned_values.root_module.child_modules -or $priorValues.root_module.child_modules) {
        throw 'The fixture must not contain child modules.'
    }
    $observed = [Collections.Generic.List[System.Collections.IDictionary]]::new()
    foreach ($section in @(
        @{ resources = $resources; prior = $false; changes = $false },
        @{ resources = $prior; prior = $true; changes = $false },
        @{ resources = $allChanges; prior = $false; changes = $true }
    )) {
        $identity = @($section.resources | Where-Object { $_.address -eq $address })
        if ($identity.Count -gt 1) { throw 'Duplicate azapi_client_config data source.' }
        foreach ($resource in $section.resources) {
            Assert-Equal $resource.provider_name $provider 'resource provider'
            if ($resource.address -eq $address) {
                Assert-Equal $resource.mode 'data' 'identity data mode'
                Assert-Equal $resource.type 'azapi_client_config' 'identity data type'
                if ($section.changes) {
                    if (@($resource.change.actions).Count -ne 1 -or $resource.change.actions[0] -ne 'no-op' -or
                        $resource.change.after_unknown.object_id -or $resource.change.after_unknown.tenant_id -or
                        $resource.change.after_unknown.subscription_id -or $resource.change.after_unknown -eq $true) {
                        throw 'Identity data must be resolved during planning, not deferred to apply.'
                    }
                    $observed.Add($resource.change.before)
                    $observed.Add($resource.change.after)
                } else {
                    $observed.Add($resource['values'])
                }
            } elseif ($section.prior -or $resource.address -ne 'azapi_resource.example' -or
                $resource.mode -ne 'managed' -or $resource.type -ne 'azapi_resource') {
                throw 'The fixture must plan only its one resource group and identity data source.'
            }
        }
    }
    if ($observed.Count -eq 0) {
        throw 'Expected exactly one resolved azapi_client_config data source.'
    }
    # Terraform can retain resolved data only in prior_state. AzAPI identifies the
    # authenticated principal by object_id, not client_id; both IDs must be pinned
    # from the same managed identity when configuring the harness.
    foreach ($values in $observed) {
        if ($null -eq $values) { throw 'Identity data values are missing.' }
        Assert-Equal $values['object_id'] $expectedObjectId 'provider object ID from plan'
        Assert-Equal $values['tenant_id'] $Expected.AZAPI_TENANT_ID 'provider tenant ID from plan'
        Assert-Equal $values['subscription_id'] $Expected.AZAPI_SUBSCRIPTION_ID 'provider subscription ID from plan'
        if ($values.Contains('client_id')) {
            Assert-Equal $values['client_id'] $Expected.AZAPI_CLIENT_ID 'provider client ID from plan'
        }
    }
    $values = $observed[0]

    $managed = @($resources | Where-Object { $_.mode -eq 'managed' })
    $changes = @($allChanges | Where-Object { $_.mode -eq 'managed' })
    if ($managed.Count -ne 1 -or $changes.Count -ne 1) {
        throw 'The fixture must plan only its one resource group and identity data source.'
    }
    $group = "rg-tf36922-e8195f-$Mode"
    Assert-Equal $managed[0].address 'azapi_resource.example' 'resource address'
    Assert-Equal $managed[0].type 'azapi_resource' 'resource Terraform type'
    foreach ($resourceValues in @($managed[0]['values'], $changes[0].change.after)) {
        Assert-Equal $resourceValues.type 'Microsoft.Resources/resourceGroups@2024-03-01' 'resource ARM type'
        Assert-Equal $resourceValues.name $group 'resource group name'
        Assert-Equal $resourceValues.location 'westeurope' 'resource location'
        Assert-Equal $resourceValues.parent_id "/subscriptions/$($Expected.AZAPI_SUBSCRIPTION_ID)" 'resource subscription'
    }
    Assert-Equal $changes[0].address 'azapi_resource.example' 'resource change address'
    if (@($changes[0].change.actions).Count -ne 1 -or $changes[0].change.actions[0] -ne 'create' -or
        $null -ne $changes[0].change.before) {
        throw 'Expected a create-only preview against an empty, unique backend key.'
    }
    if ($Plan.errored -eq $true -or $Plan.applyable -eq $false) { throw 'Plan is not a valid change preview.' }
    return [ordered]@{
        mode = $Mode
        topology = $topology
        coreCommit = $script:CoreCommit
        docsCommit = $script:DocsCommit
        result = 'passed'
        operations = @('init', 'plan', 'show-json-in-memory')
        applied = $false
        provider = [ordered]@{
            clientId = $Expected.AZAPI_CLIENT_ID
            clientIdSource = 'expected-client-to-object-id-mapping'
            objectId = $values['object_id']
            tenantId = $values['tenant_id']
            subscriptionId = $values['subscription_id']
        }
        backendExpected = [ordered]@{
            clientId = $Expected.STATE_CLIENT_ID
            tenantId = $Expected.STATE_TENANT_ID
            subscriptionId = $Expected.STATE_SUBSCRIPTION_ID
        }
        plannedResource = [ordered]@{
            address = 'azapi_resource.example'
            name = $group
            type = $managed[0]['values'].type
            parentId = $managed[0]['values'].parent_id
            action = 'create'
        }
    }
}
