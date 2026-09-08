[CmdletBinding()]
param([string] $DocsPath)

. "$PSScriptRoot\Harness.Common.ps1"
& "$PSScriptRoot\Export-Fixtures.ps1" -DocsPath $DocsPath -Check

function Assert-Parses([string] $Text, [string] $Label) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($Text, [ref] $tokens, [ref] $errors)
    if ($errors.Count) {
        throw "$Label does not parse: $(($errors | ForEach-Object Message) -join '; ')"
    }
}

function Get-InlineScripts([string] $Yaml) {
    $lines = $Yaml -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)(?:- )?(?:run|inlineScript|pwsh): \|\s*$') {
            $indent = $Matches[1].Length
            $body = [Collections.Generic.List[string]]::new()
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j].Trim().Length -and ($lines[$j] -notmatch "^ {$($indent + 1)}")) { break }
                $body.Add($lines[$j].TrimStart())
            }
            Write-Output ($body -join "`n")
        }
    }
}

foreach ($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    Assert-Parses (Get-Content $file.FullName -Raw) $file.Name
}
$inlineCount = 0
foreach ($mode in $script:Modes.Keys) {
    $hcl = Get-Content (Join-Path $script:RepositoryRoot "examples\$mode\main.tf") -Raw
    if ($hcl -notmatch 'required_version = ">= 1\.17\.0"') {
        throw 'Preserve the documented core-version constraint; prerelease constraints are invalid.'
    }
    $github = $mode.StartsWith('gh-')
    $path = if ($github) { ".github\workflows\$mode.yml" } else { ".ado\$mode.yml" }
    $yaml = ConvertTo-Lf (Get-Content (Join-Path $script:RepositoryRoot $path) -Raw)
    foreach ($body in Get-InlineScripts $yaml) {
        Assert-Parses $body "$mode inline script"
        $inlineCount++
    }
    if ($github) {
        if ($yaml -notmatch '(?m)^on:\n  workflow_dispatch:' -or $yaml -match '(?m)^  (push|pull_request|schedule|workflow_run|workflow_call):') {
            throw "$mode must be manually dispatched only."
        }
        if ($yaml -notmatch 'id-token: write' -or $yaml -notmatch 'contents: read') { throw 'Missing minimum GitHub permissions.' }
        if ($yaml -match 'ARM_BACKEND_OIDC_REQUEST_(URL|TOKEN)') {
            throw 'Both GitHub modes must use native job broker fallback without explicit copies.'
        }
    } else {
        if ($yaml -notmatch '(?m)^trigger: none\npr: none$') { throw 'ADO trigger and PR trigger must be disabled.' }
        if ([regex]::Matches($yaml, 'task: AzureCLI@2').Count -ne 2 -or
            [regex]::Matches($yaml, 'SYSTEM_ACCESSTOKEN: \$\(System.AccessToken\)').Count -ne 2) {
            throw 'ADO init and plan must remain separate authenticated tasks.'
        }
        if ($yaml -notmatch 'azureSubscription: sc-tf36922-state' -or $yaml -notmatch 'azureSubscription: sc-tf36922-provider') {
            throw 'Unexpected service connection names.'
        }
    }
    foreach ($command in 'init', 'plan') {
        if ([regex]::Matches($yaml, "(?m)^\s*terraform $command ").Count -ne 1) { throw "Expected one $command in $mode." }
    }
    if ($yaml -match '(?m)^\s*terraform (apply|import|destroy)\b' -or $yaml -match 'setup-terraform|TerraformInstaller@') {
        throw 'A fixture must not apply/import/destroy or install a released Terraform binary.'
    }
    if ($yaml -notmatch 'windows-2022' -or $yaml -notmatch '1\.26\.4' -or $yaml -notmatch $script:CoreCommit) {
        throw 'Hosted Windows, Go or source pin drift.'
    }
    if ($yaml -notmatch 'finally \{' -or $yaml -notmatch 'Remove-Run.ps1' -or $yaml -notmatch 'Test-Plan.ps1') {
        throw 'Missing in-memory assertion or cleanup.'
    }
}

$baseExpected = @{
    AZAPI_CLIENT_ID = '11111111-1111-1111-1111-111111111111'
    AZAPI_OBJECT_ID = '77777777-7777-7777-7777-777777777777'
    AZAPI_TENANT_ID = '22222222-2222-2222-2222-222222222222'
    AZAPI_SUBSCRIPTION_ID = '33333333-3333-3333-3333-333333333333'
    STATE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
    STATE_TENANT_ID = '88888888-8888-8888-8888-888888888888'
    STATE_SUBSCRIPTION_ID = '99999999-9999-9999-9999-999999999999'
}
$testCases = foreach ($topology in 'same-tenant', 'cross-tenant') {
    foreach ($mode in $script:Modes.Keys) {
        $expected = $baseExpected.Clone()
        $expected.TOPOLOGY = $topology
        if ($topology -eq 'same-tenant') {
            $expected.STATE_TENANT_ID = $expected.AZAPI_TENANT_ID
            $expected.STATE_SUBSCRIPTION_ID = $expected.AZAPI_SUBSCRIPTION_ID
        }
        @{ Mode = $mode; Expected = $expected }
    }
}

function Get-InvalidExpectedValue([System.Collections.IDictionary] $Expected, [string] $Field) {
    if ($Field -eq 'OBJECT_ID') { return '' }
    if ($Field -ne 'CLIENT_ID' -and $Expected.TOPOLOGY -eq 'same-tenant') { return $Expected.STATE_CLIENT_ID }
    return $Expected["STATE_$Field"]
}

$passed = 0
foreach ($case in $testCases) {
    $mode = $case.Mode
    $expected = $case.Expected
    $identity = @{
        address = 'data.azapi_client_config.current'
        mode = 'data'
        type = 'azapi_client_config'
        provider_name = 'registry.terraform.io/azure/azapi'
        values = @{
            object_id = $expected.AZAPI_OBJECT_ID
            tenant_id = $expected.AZAPI_TENANT_ID
            subscription_id = $expected.AZAPI_SUBSCRIPTION_ID
        }
    }
    $resource = @{
        address = 'azapi_resource.example'
        mode = 'managed'
        type = 'azapi_resource'
        provider_name = 'registry.terraform.io/azure/azapi'
        values = @{
            type = 'Microsoft.Resources/resourceGroups@2024-03-01'
            name = "rg-tf36922-e8195f-$mode"
            location = 'westeurope'
            parent_id = "/subscriptions/$($expected.AZAPI_SUBSCRIPTION_ID)"
        }
    }
    # Actual Terraform show JSON: resolved AzAPI data is retained only in prior_state.
    $fixture = @{
        planned_values = @{ root_module = @{ resources = @($resource) } }
        prior_state = @{ values = @{ root_module = @{ resources = @($identity) } } }
        resource_changes = @(@{
            address = 'azapi_resource.example'
            mode = 'managed'
            type = 'azapi_resource'
            provider_name = 'registry.terraform.io/azure/azapi'
            change = @{ actions = @('create'); before = $null; after = $resource['values'] }
        })
        errored = $false
        applyable = $true
    }
    foreach ($shape in 'prior', 'planned', 'change', 'all') {
        $good = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        if ($shape -in 'planned', 'all') { $good.planned_values.root_module.resources += $identity }
        if ($shape -in 'change', 'all') {
            $good.resource_changes += @{
                address = $identity.address; mode = 'data'; type = $identity.type; provider_name = $identity.provider_name
                change = @{ actions = @('no-op'); before = $identity['values']; after = $identity['values'] }
            }
        }
        if ($shape -in 'planned', 'change') { $good.Remove('prior_state') }
        # Exercise the OrderedHashtable returned by Test-Plan.ps1, not just native hashtables.
        $good = $good | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $evidence = Assert-PlanData $good $expected $mode
        if ($evidence.result -ne 'passed' -or $evidence.applied -ne $false -or $evidence.Contains('planned_values') -or
            $evidence.topology -ne $expected.TOPOLOGY -or
            $evidence.provider.objectId -ne $expected.AZAPI_OBJECT_ID -or
            $evidence.provider.clientIdSource -ne 'expected-client-to-object-id-mapping') {
            throw 'Evidence must be a sanitized allow-list with observed object ID and explicit client-ID provenance.'
        }
        $passed++
    }
    foreach ($mutation in 'client', 'object', 'tenant', 'subscription', 'group', 'type', 'parent', 'location',
        'delete', 'replace', 'missing-data', 'extra-module', 'prior-module', 'duplicate-data', 'extra-data',
        'extra-managed', 'prior-managed', 'missing-object', 'wrong-provider', 'wrong-data-mode', 'wrong-data-type',
        'conflicting-data', 'deferred-data', 'unknown-data', 'change-group', 'change-type', 'change-parent',
        'change-location', 'change-provider', 'change-before', 'errored', 'not-applyable') {
        $bad = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $badIdentity = $bad.prior_state['values'].root_module.resources[0]
        $badResource = $bad.planned_values.root_module.resources[0]
        switch ($mutation) {
            'client' { $badIdentity['values'].client_id = $expected.STATE_CLIENT_ID }
            'object' { $badIdentity['values'].object_id = $expected.STATE_CLIENT_ID }
            'tenant' { $badIdentity['values'].tenant_id = $expected.STATE_CLIENT_ID }
            'subscription' { $badIdentity['values'].subscription_id = $expected.STATE_CLIENT_ID }
            'group' { $badResource['values'].name = 'wrong-group' }
            'type' { $badResource['values'].type = 'Microsoft.Storage/storageAccounts@2023-05-01' }
            'parent' { $badResource['values'].parent_id = "/subscriptions/$($expected.STATE_CLIENT_ID)" }
            'location' { $badResource['values'].location = 'eastus' }
            'delete' { $bad.resource_changes[0].change.actions = @('delete') }
            'replace' { $bad.resource_changes[0].change.actions = @('delete', 'create') }
            'missing-data' { $bad.Remove('prior_state') }
            'extra-module' { $bad.planned_values.root_module.child_modules = @(@{ address = 'module.unexpected' }) }
            'prior-module' { $bad.prior_state['values'].root_module.child_modules = @(@{ address = 'module.unexpected' }) }
            'duplicate-data' { $bad.prior_state['values'].root_module.resources += $badIdentity }
            'extra-data' { $badIdentity.address = 'data.azapi_client_config.unexpected' }
            'extra-managed' { $bad.planned_values.root_module.resources += $badResource }
            'prior-managed' { $bad.prior_state['values'].root_module.resources += $badResource }
            'missing-object' { $badIdentity['values'].Remove('object_id') }
            'wrong-provider' { $badIdentity.provider_name = 'registry.terraform.io/example/azapi' }
            'wrong-data-mode' { $badIdentity.mode = 'managed' }
            'wrong-data-type' { $badIdentity.type = 'azapi_resource' }
            'conflicting-data' {
                $bad.planned_values.root_module.resources += ($identity | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable)
                $bad.planned_values.root_module.resources[1]['values'].object_id = $expected.STATE_CLIENT_ID
            }
            { $_ -in 'deferred-data', 'unknown-data' } {
                $bad.resource_changes += @{
                    address = $identity.address; mode = 'data'; type = $identity.type; provider_name = $identity.provider_name
                    change = @{
                        actions = @($(if ($mutation -eq 'deferred-data') { 'read' } else { 'no-op' }))
                        before = $identity['values']; after = $identity['values']
                        after_unknown = @{ object_id = ($mutation -eq 'unknown-data') }
                    }
                }
            }
            'change-group' { $bad.resource_changes[0].change.after.name = 'wrong-group' }
            'change-type' { $bad.resource_changes[0].change.after.type = 'Microsoft.Storage/storageAccounts@2023-05-01' }
            'change-parent' { $bad.resource_changes[0].change.after.parent_id = "/subscriptions/$($expected.STATE_CLIENT_ID)" }
            'change-location' { $bad.resource_changes[0].change.after.location = 'eastus' }
            'change-provider' { $bad.resource_changes[0].provider_name = 'registry.terraform.io/example/azapi' }
            'change-before' { $bad.resource_changes[0].change.before = $resource['values'] }
            'errored' { $bad.errored = $true }
            'not-applyable' { $bad.applyable = $false }
        }
        $rejected = $false
        try { $null = Assert-PlanData $bad $expected $mode } catch { $rejected = $true }
        if (-not $rejected) { throw "$mode accepted invalid plan case: $mutation" }
        $passed++
    }
    foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID', 'OBJECT_ID') {
        $badExpected = $expected.Clone()
        $badExpected["AZAPI_$field"] = Get-InvalidExpectedValue $expected $field
        $failure = $null
        try { $null = Assert-PlanData $fixture $badExpected $mode } catch { $failure = $_.Exception.Message }
        if ($failure -notmatch $field) { throw "$mode accepted invalid expected $field for $($expected.TOPOLOGY)." }
        $passed++
    }
    foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
        if ($field -ne 'CLIENT_ID' -and $expected.TOPOLOGY -eq 'same-tenant') { continue }
        $badExpected = $expected.Clone()
        $badExpected["AZAPI_$field"] = "{$($expected["STATE_$field"])}"
        $failure = $null
        try { $null = Assert-PlanData $fixture $badExpected $mode } catch { $failure = $_.Exception.Message }
        if ($failure -notmatch "$field must be distinct") {
            throw "$mode accepted equivalent GUIDs with different formatting for $field."
        }
        $passed++
    }
    if ($expected.TOPOLOGY -eq 'same-tenant') {
        $equivalentExpected = $expected.Clone()
        foreach ($field in 'TENANT_ID', 'SUBSCRIPTION_ID') {
            $equivalentExpected["STATE_$field"] = "{$($expected["AZAPI_$field"])}"
        }
        $null = Assert-PlanData $fixture $equivalentExpected $mode
        $passed++
    }
    foreach ($invalidTopology in '', 'unknown', $(if ($expected.TOPOLOGY -eq 'same-tenant') { 'cross-tenant' } else { 'same-tenant' })) {
        $badExpected = $expected.Clone()
        $badExpected.TOPOLOGY = $invalidTopology
        $rejected = $false
        try { $null = Assert-PlanData $fixture $badExpected $mode } catch { $rejected = $true }
        if (-not $rejected) { throw "$mode accepted missing/incorrect topology." }
        $passed++
    }
    $savedObjectId = [Environment]::GetEnvironmentVariable('HARNESS_EXPECTED_AZAPI_OBJECT_ID')
    try {
        $environmentExpected = $expected.Clone()
        $environmentExpected.Remove('AZAPI_OBJECT_ID')
        $env:HARNESS_EXPECTED_AZAPI_OBJECT_ID = $expected.AZAPI_OBJECT_ID
        $null = Assert-PlanData $fixture $environmentExpected $mode
        $passed++
        $env:HARNESS_EXPECTED_AZAPI_OBJECT_ID = $null
        $rejected = $false
        try { $null = Assert-PlanData $fixture $environmentExpected $mode } catch { $rejected = $true }
        if (-not $rejected) { throw "$mode accepted missing expected object-ID metadata." }
        $passed++
    } finally {
        [Environment]::SetEnvironmentVariable('HARNESS_EXPECTED_AZAPI_OBJECT_ID', $savedObjectId)
    }
}
$authNames = @(
    'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'ARM_USE_OIDC', 'ARM_USE_AZUREAD',
    'ARM_BACKEND_CLIENT_ID', 'ARM_BACKEND_TENANT_ID', 'ARM_BACKEND_SUBSCRIPTION_ID',
    'ARM_BACKEND_USE_OIDC', 'ARM_BACKEND_USE_AZUREAD', 'ARM_BACKEND_ENVIRONMENT_VARIABLE_STRICT_MODE',
    'ARM_BACKEND_OIDC_REQUEST_URL', 'ARM_BACKEND_OIDC_REQUEST_TOKEN',
    'ARM_BACKEND_OIDC_AZURE_SERVICE_CONNECTION_ID', 'ARM_OIDC_AZURE_SERVICE_CONNECTION_ID',
    'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN',
    'AZURESUBSCRIPTION_SERVICE_CONNECTION_ID', 'SYSTEM_OIDCREQUESTURI', 'SYSTEM_ACCESSTOKEN'
) + @($expected.Keys | ForEach-Object { "HARNESS_EXPECTED_$_" })
$saved = @{}
foreach ($name in $authNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$initializeNames = @($expected.Keys) + @(
    'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_ENV', 'BUILD_BUILDID', 'SYSTEM_JOBATTEMPT',
    'STATE_STORAGE_ACCOUNT_NAME', 'STATE_CONTAINER_NAME', 'STATE_KEY'
)
foreach ($name in $initializeNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$authPassed = 0
$initializePassed = 0
$initializeDirectory = Join-Path $script:RepositoryRoot ".runs\fixture-init-$PID"
if (Test-Path $initializeDirectory) { throw 'Initializer test directory already exists.' }
$null = New-Item -ItemType Directory $initializeDirectory
try {
    foreach ($case in $testCases) {
        $mode = $case.Mode
        $expected = $case.Expected
        $initializeOptions = if ($expected.TOPOLOGY -eq 'cross-tenant') { @{ Topology = 'cross-tenant' } } else { @{} }
        foreach ($entry in $expected.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
        $env:GITHUB_RUN_ID = $env:BUILD_BUILDID = "$PID"
        $env:GITHUB_RUN_ATTEMPT = $env:SYSTEM_JOBATTEMPT = '987654321'
        $env:GITHUB_ENV = Join-Path $initializeDirectory "$($expected.TOPOLOGY)-$mode.env"
        $env:STATE_STORAGE_ACCOUNT_NAME = 'syntheticstorage'
        $env:STATE_CONTAINER_NAME = 'syntheticcontainer'
        $env:STATE_KEY = 'synthetic-key'
        $runDirectory = Join-Path $script:RepositoryRoot ".runs\$mode-$PID-987654321"
        if (Test-Path $runDirectory) { throw 'Initializer test run directory already exists.' }
        try {
            foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID', 'OBJECT_ID') {
                $value = Get-InvalidExpectedValue $expected $field
                [Environment]::SetEnvironmentVariable("AZAPI_$field", $value)
                $failure = $null
                try { & "$PSScriptRoot\Initialize-Run.ps1" -Mode $mode @initializeOptions 6>$null } catch { $failure = $_.Exception.Message }
                if (-not $failure -or $failure -notmatch $field -or (Test-Path $runDirectory)) {
                    throw "$mode initializer did not reject invalid $field before creating a run."
                }
                [Environment]::SetEnvironmentVariable("AZAPI_$field", $expected["AZAPI_$field"])
                $initializePassed++
            }
            foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
                if ($field -ne 'CLIENT_ID' -and $expected.TOPOLOGY -eq 'same-tenant') { continue }
                [Environment]::SetEnvironmentVariable("AZAPI_$field", "{$($expected["STATE_$field"])}")
                $failure = $null
                try { & "$PSScriptRoot\Initialize-Run.ps1" -Mode $mode @initializeOptions 6>$null } catch { $failure = $_.Exception.Message }
                if ($failure -notmatch "$field must be distinct" -or (Test-Path $runDirectory)) {
                    throw "$mode initializer accepted equivalent GUIDs with different formatting for $field."
                }
                [Environment]::SetEnvironmentVariable("AZAPI_$field", $expected["AZAPI_$field"])
                $initializePassed++
            }
            $output = (& "$PSScriptRoot\Initialize-Run.ps1" -Mode $mode @initializeOptions 6>&1) -join "`n"
            if ($mode.StartsWith('gh-')) { $output = Get-Content $env:GITHUB_ENV -Raw }
            if ($output -notmatch "HARNESS_EXPECTED_AZAPI_OBJECT_ID[=\]]$($expected.AZAPI_OBJECT_ID)" -or
                $output -notmatch "HARNESS_EXPECTED_TOPOLOGY[=\]]$($expected.TOPOLOGY)" -or
                -not (Test-Path (Join-Path $runDirectory 'main.tf'))) {
                throw "$mode initializer did not preserve the expected client/object mapping."
            }
            $initializePassed++
        } finally {
            if (Test-Path $runDirectory) { Remove-Item -LiteralPath $runDirectory -Recurse -Force }
        }
    }
    foreach ($case in $testCases) {
        $mode = $case.Mode
        $expected = $case.Expected
        foreach ($phase in 'Init', 'Plan') {
            foreach ($name in $authNames) { [Environment]::SetEnvironmentVariable($name, $null) }
            foreach ($entry in $expected.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable("HARNESS_EXPECTED_$($entry.Key)", $entry.Value)
            }
            $github = $mode.StartsWith('gh-')
            $strict = $mode.EndsWith('-strict')
            if ($strict) {
                $env:ARM_BACKEND_ENVIRONMENT_VARIABLE_STRICT_MODE = 'true'
                $env:ARM_BACKEND_USE_OIDC = 'true'
                $env:ARM_BACKEND_USE_AZUREAD = 'true'
                $env:ARM_BACKEND_SUBSCRIPTION_ID = $expected.STATE_SUBSCRIPTION_ID
            } else {
                $env:ARM_USE_AZUREAD = 'true'
            }
            if (-not $strict -or $github -or $phase -eq 'Plan') { $env:ARM_USE_OIDC = 'true' }
            $prefix = if (-not $github -and -not $strict -and $phase -eq 'Init') { 'ARM_' } else { 'ARM_BACKEND_' }
            [Environment]::SetEnvironmentVariable("${prefix}CLIENT_ID", $expected.STATE_CLIENT_ID)
            [Environment]::SetEnvironmentVariable("${prefix}TENANT_ID", $expected.STATE_TENANT_ID)
            if ($github -or $phase -eq 'Plan') {
                foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
                    [Environment]::SetEnvironmentVariable("ARM_$field", $expected["AZAPI_$field"])
                }
            }
            if ($github) {
                $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://example.invalid/github-broker'
                $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'synthetic-test-value'
            } else {
                $env:SYSTEM_OIDCREQUESTURI = 'https://example.invalid/ado-broker'
                $env:SYSTEM_ACCESSTOKEN = 'synthetic-test-value'
                $stateConnection = '55555555-5555-5555-5555-555555555555'
                $providerConnection = '66666666-6666-6666-6666-666666666666'
                [Environment]::SetEnvironmentVariable("${prefix}OIDC_AZURE_SERVICE_CONNECTION_ID", $stateConnection)
                if ($phase -eq 'Init') {
                    $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID = $stateConnection
                } else {
                    $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID = $providerConnection
                    $env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID = $providerConnection
                }
            }
            & "$PSScriptRoot\Assert-Run.ps1" -Mode $mode -Phase $phase 6>$null
            $authPassed++
            if ($github) {
                $env:ARM_BACKEND_OIDC_REQUEST_URL = $env:ACTIONS_ID_TOKEN_REQUEST_URL
                $rejected = $false
                try { & "$PSScriptRoot\Assert-Run.ps1" -Mode $mode -Phase $phase 6>$null } catch { $rejected = $true }
                if (-not $rejected) { throw "$mode $phase accepted a backend broker override." }
                $env:ARM_BACKEND_OIDC_REQUEST_URL = $null
                $authPassed++
            }
            [Environment]::SetEnvironmentVariable("${prefix}CLIENT_ID", $expected.AZAPI_CLIENT_ID)
            $rejected = $false
            try { & "$PSScriptRoot\Assert-Run.ps1" -Mode $mode -Phase $phase 6>$null } catch { $rejected = $true }
            if (-not $rejected) { throw "$mode $phase did not reject an incorrect backend identity." }
            $authPassed++
        }
    }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $initializeDirectory -Recurse -Force
}
& "$PSScriptRoot\Test-BuildTerraform.ps1"
Write-Host "PASS: source extraction, $inlineCount inline PowerShell blocks, all scripts, $passed plan cases, $initializePassed initializer cases and $authPassed runtime auth cases. No Azure/CI operations performed."
