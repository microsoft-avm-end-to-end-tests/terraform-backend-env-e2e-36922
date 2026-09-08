[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('gh-default', 'gh-strict', 'ado-default', 'ado-strict')][string] $Mode)

. "$PSScriptRoot\Harness.Common.ps1"
$expected = Get-ExpectedIdentities
$raw = $null
$plan = $null
try {
    $raw = (& terraform show -json tfplan) -join "`n"
    $plan = $raw | ConvertFrom-Json -AsHashtable
    $evidence = Assert-PlanData $plan $expected $Mode
    $runName = Get-RequiredEnvironment 'HARNESS_RUN_NAME'
    if ($runName -notmatch "^$([regex]::Escape($Mode))-\d+-\d+$") { throw 'Invalid evidence name.' }
    $evidence.run = $runName
    $evidence.stateKey = Get-RequiredEnvironment 'STATE_KEY'
    $json = $evidence | ConvertTo-Json -Depth 8
    Write-Utf8 (Join-Path $script:RepositoryRoot "evidence\$runName.json") "$json`n"
    Write-Host $json
} finally {
    $raw = $null
    $plan = $null
}
