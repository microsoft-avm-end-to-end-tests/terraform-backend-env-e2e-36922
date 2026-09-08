[CmdletBinding()]
param(
    [ValidateSet('Validate', 'WhatIf', 'Deploy')]
    [string] $Operation = 'Validate'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$subscription = '121e2ce8-c399-4fea-958a-09d15ed949c4'
$account = az account show --subscription $subscription -o json | ConvertFrom-Json
if ($account.tenantId -ne '13b2a159-de04-4835-a3ad-fd814c6adb4f') {
    throw 'Unexpected tenant; refusing deployment.'
}
$command = @{ Validate = 'validate'; WhatIf = 'what-if'; Deploy = 'create' }[$Operation]
az deployment sub $command --subscription $subscription --location westeurope `
    --name tf36922-e8195f-bootstrap --template-file "$PSScriptRoot\main.bicep" `
    --only-show-errors -o json
