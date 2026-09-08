[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('gh-default', 'gh-strict', 'ado-default', 'ado-strict')][string] $Mode,
    [Parameter(Mandatory)][ValidateSet('Init', 'Plan')][string] $Phase
)

. "$PSScriptRoot\Harness.Common.ps1"
$expected = Get-ExpectedIdentities
if ($expected.STATE_CLIENT_ID -ieq $expected.AZAPI_CLIENT_ID) { throw 'Backend and provider identities must differ.' }
foreach ($name in 'TF_LOG', 'TF_LOG_PATH', 'TF_LOG_CORE', 'TF_LOG_PROVIDER', 'TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_show',
    'ARM_CLIENT_SECRET', 'ARM_BACKEND_CLIENT_SECRET', 'ARM_ACCESS_KEY', 'ARM_BACKEND_ACCESS_KEY',
    'ARM_SAS_TOKEN', 'ARM_BACKEND_SAS_TOKEN', 'ARM_OIDC_TOKEN', 'ARM_BACKEND_OIDC_TOKEN',
    'ARM_OIDC_TOKEN_FILE_PATH', 'ARM_BACKEND_OIDC_TOKEN_FILE_PATH') {
    if ([Environment]::GetEnvironmentVariable($name)) { throw "Unexpected credential, logging, or CLI override: $name" }
}
$strict = $Mode.EndsWith('-strict')
$github = $Mode.StartsWith('gh-')
if ($strict) {
    Assert-Equal $env:ARM_BACKEND_ENVIRONMENT_VARIABLE_STRICT_MODE 'true' 'backend strict mode'
    Assert-Equal $env:ARM_BACKEND_USE_OIDC 'true' 'backend OIDC'
    Assert-Equal $env:ARM_BACKEND_USE_AZUREAD 'true' 'backend Entra storage access'
    Assert-Equal $env:ARM_BACKEND_SUBSCRIPTION_ID $expected.STATE_SUBSCRIPTION_ID 'backend subscription'
} else {
    if ($env:ARM_BACKEND_ENVIRONMENT_VARIABLE_STRICT_MODE -and $env:ARM_BACKEND_ENVIRONMENT_VARIABLE_STRICT_MODE -ne 'false') {
        throw 'Non-strict fixture must use default fallback.'
    }
    foreach ($name in 'ARM_BACKEND_USE_OIDC', 'ARM_BACKEND_USE_AZUREAD', 'ARM_BACKEND_SUBSCRIPTION_ID',
        'ARM_BACKEND_OIDC_REQUEST_URL', 'ARM_BACKEND_OIDC_REQUEST_TOKEN') {
        if ([Environment]::GetEnvironmentVariable($name)) { throw "Unexpected backend override in non-strict mode: $name" }
    }
    Assert-Equal $env:ARM_USE_AZUREAD 'true' 'shared Entra storage access'
}
if (-not $strict -or $github -or $Phase -eq 'Plan') {
    Assert-Equal $env:ARM_USE_OIDC 'true' 'shared/provider OIDC'
}
$prefix = if (-not $github -and -not $strict -and $Phase -eq 'Init') { 'ARM_' } else { 'ARM_BACKEND_' }
Assert-Equal ([Environment]::GetEnvironmentVariable("${prefix}CLIENT_ID")) $expected.STATE_CLIENT_ID 'backend client'
Assert-Equal ([Environment]::GetEnvironmentVariable("${prefix}TENANT_ID")) $expected.STATE_TENANT_ID 'backend tenant'
if ($Phase -eq 'Plan' -or $github) {
    foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
        Assert-Equal ([Environment]::GetEnvironmentVariable("ARM_$field")) $expected["AZAPI_$field"] "provider $field"
    }
}
if ($github) {
    $null = Get-RequiredEnvironment 'ACTIONS_ID_TOKEN_REQUEST_URL'
    $null = Get-RequiredEnvironment 'ACTIONS_ID_TOKEN_REQUEST_TOKEN'
    if ($env:ARM_BACKEND_OIDC_REQUEST_URL -or $env:ARM_BACKEND_OIDC_REQUEST_TOKEN) {
        throw 'GitHub examples must exercise native job broker fallback without backend broker overrides.'
    }
} else {
    $null = Get-RequiredEnvironment 'SYSTEM_OIDCREQUESTURI'
    $null = Get-RequiredEnvironment 'SYSTEM_ACCESSTOKEN'
    $connection = Get-RequiredEnvironment "${prefix}OIDC_AZURE_SERVICE_CONNECTION_ID"
    Assert-Identifier $connection 'backend service connection'
    if ($Phase -eq 'Init') {
        Assert-Equal $connection $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID 'init state service connection'
    } else {
        Assert-Equal $env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID 'plan provider service connection'
        Assert-Identifier $env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID 'provider service connection'
        if ($connection -ieq $env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID) { throw 'The two service connections must differ.' }
    }
}
Write-Host "$Mode $Phase authentication invariants passed (no credentials emitted)."
