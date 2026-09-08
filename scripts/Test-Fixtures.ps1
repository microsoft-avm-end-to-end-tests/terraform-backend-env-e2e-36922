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

$expected = @{
    AZAPI_CLIENT_ID = '11111111-1111-1111-1111-111111111111'
    AZAPI_TENANT_ID = '22222222-2222-2222-2222-222222222222'
    AZAPI_SUBSCRIPTION_ID = '33333333-3333-3333-3333-333333333333'
    STATE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
    STATE_TENANT_ID = '22222222-2222-2222-2222-222222222222'
    STATE_SUBSCRIPTION_ID = '33333333-3333-3333-3333-333333333333'
}
$passed = 0
foreach ($mode in $script:Modes.Keys) {
    $fixture = @{
        planned_values = @{
            root_module = @{
                resources = @(
                    @{
                        address = 'data.azapi_client_config.current'
                        mode = 'data'
                        type = 'azapi_client_config'
                        values = @{
                            client_id = $expected.AZAPI_CLIENT_ID
                            tenant_id = $expected.AZAPI_TENANT_ID
                            subscription_id = $expected.AZAPI_SUBSCRIPTION_ID
                        }
                    },
                    @{
                        address = 'azapi_resource.example'
                        mode = 'managed'
                        type = 'azapi_resource'
                        values = @{
                            type = 'Microsoft.Resources/resourceGroups@2024-03-01'
                            name = "rg-tf36922-e8195f-$mode"
                            location = 'westeurope'
                            parent_id = "/subscriptions/$($expected.AZAPI_SUBSCRIPTION_ID)"
                        }
                    }
                )
            }
        }
        resource_changes = @(@{
            address = 'azapi_resource.example'
            mode = 'managed'
            change = @{ actions = @('create') }
        })
    }
    $evidence = Assert-PlanData $fixture $expected $mode
    if ($evidence.result -ne 'passed' -or $evidence.applied -ne $false -or $evidence.Contains('planned_values')) {
        throw 'Evidence must be a sanitized allow-list, never a raw plan.'
    }
    $passed++
    foreach ($mutation in 'client', 'tenant', 'subscription', 'group', 'type', 'parent', 'delete', 'missing-data', 'extra-module') {
        $bad = $fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        switch ($mutation) {
            'client' { $bad.planned_values.root_module.resources[0].values.client_id = $expected.STATE_CLIENT_ID }
            'tenant' { $bad.planned_values.root_module.resources[0].values.tenant_id = $expected.STATE_CLIENT_ID }
            'subscription' { $bad.planned_values.root_module.resources[0].values.subscription_id = $expected.STATE_CLIENT_ID }
            'group' { $bad.planned_values.root_module.resources[1].values.name = 'wrong-group' }
            'type' { $bad.planned_values.root_module.resources[1].values.type = 'Microsoft.Storage/storageAccounts@2023-05-01' }
            'parent' { $bad.planned_values.root_module.resources[1].values.parent_id = "/subscriptions/$($expected.STATE_CLIENT_ID)" }
            'delete' { $bad.resource_changes[0].change.actions = @('delete') }
            'missing-data' { $bad.planned_values.root_module.resources = @($bad.planned_values.root_module.resources[1]) }
            'extra-module' { $bad.planned_values.root_module.child_modules = @(@{ address = 'module.unexpected' }) }
        }
        $rejected = $false
        try { $null = Assert-PlanData $bad $expected $mode } catch { $rejected = $true }
        if (-not $rejected) { throw "$mode accepted invalid plan case: $mutation" }
        $passed++
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
$authPassed = 0
try {
    foreach ($mode in $script:Modes.Keys) {
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
    foreach ($name in $authNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
& "$PSScriptRoot\Test-BuildTerraform.ps1"
Write-Host "PASS: source extraction, $inlineCount inline PowerShell blocks, all scripts, $passed plan cases and $authPassed runtime auth cases. No Azure/CI operations performed."
