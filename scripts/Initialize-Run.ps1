[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('gh-default', 'gh-strict', 'ado-default', 'ado-strict')][string] $Mode)

. "$PSScriptRoot\Harness.Common.ps1"
$github = $Mode.StartsWith('gh-')
$run = Get-RequiredEnvironment $(if ($github) { 'GITHUB_RUN_ID' } else { 'BUILD_BUILDID' })
$attempt = Get-RequiredEnvironment $(if ($github) { 'GITHUB_RUN_ATTEMPT' } else { 'SYSTEM_JOBATTEMPT' })
if ($run -notmatch '^\d+$' -or $attempt -notmatch '^\d+$') { throw 'Invalid CI run/attempt identifiers.' }
$variables = [ordered]@{}
foreach ($role in 'AZAPI', 'STATE') {
    foreach ($field in 'CLIENT_ID', 'TENANT_ID', 'SUBSCRIPTION_ID') {
        $name = "${role}_${field}"
        $value = Get-RequiredEnvironment $name
        Assert-Identifier $value $name
        $variables["HARNESS_EXPECTED_$name"] = $value
    }
}
if ($variables.HARNESS_EXPECTED_STATE_CLIENT_ID -ieq $variables.HARNESS_EXPECTED_AZAPI_CLIENT_ID) {
    throw 'Backend and provider client IDs must be distinct.'
}
foreach ($name in 'STATE_STORAGE_ACCOUNT_NAME', 'STATE_CONTAINER_NAME', 'STATE_KEY') {
    $null = Get-RequiredEnvironment $name
}
$key = Get-RequiredEnvironment 'STATE_KEY'
if ($key -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._/-]*$') { throw 'STATE_KEY must be a safe, non-secret blob name/prefix.' }
$id = "$Mode-$run-$attempt"
$directory = Join-Path $script:RepositoryRoot ".runs\$id"
if (Test-Path $directory) { throw 'This run/attempt working directory already exists.' }
[IO.Directory]::CreateDirectory($directory) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $script:RepositoryRoot 'evidence')) | Out-Null
Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot "examples\$Mode\main.tf") -Destination $directory
$variables.HARNESS_WORK_DIR = $directory
$variables.HARNESS_SCRIPT_DIR = $PSScriptRoot
$variables.HARNESS_RUN_NAME = $id
$variables.STATE_KEY = "$key.$Mode.$run.$attempt.tfstate"
foreach ($entry in $variables.GetEnumerator()) {
    if ($github) {
        Add-Content -LiteralPath (Get-RequiredEnvironment 'GITHUB_ENV') -Value "$($entry.Key)=$($entry.Value)"
    } else {
        $escaped = $entry.Value.Replace('%', '%AZP25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host "##vso[task.setvariable variable=$($entry.Key)]$escaped"
    }
}
Write-Host "Prepared $id; separate backend/provider identities; init and plan only."
