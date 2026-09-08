[CmdletBinding()]
param()

. "$PSScriptRoot\Harness.Common.ps1"
if ([string]::IsNullOrWhiteSpace($env:HARNESS_WORK_DIR)) { return }
$directory = [IO.Path]::GetFullPath($env:HARNESS_WORK_DIR)
$allowedParent = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '.runs'))
if ((Split-Path $directory -Parent) -ine $allowedParent -or
    (Split-Path $directory -Leaf) -notmatch '^(gh|ado)-(default|strict)-\d+-\d+$') {
    throw 'Refusing cleanup outside the exact harness run directory.'
}
Set-Location $script:RepositoryRoot
if (Test-Path -LiteralPath $directory) {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host 'Removed local plan, backend metadata, provider cache and working state; no remote state deletion.'
