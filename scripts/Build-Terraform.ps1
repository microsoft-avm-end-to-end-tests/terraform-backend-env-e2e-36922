[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('GitHub', 'AzurePipelines')][string] $CI)

. "$PSScriptRoot\Harness.Common.ps1"

function Invoke-CheckedNative([string] $FilePath, [string[]] $ArgumentList) {
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE." }
}

function Assert-CleanSource([string] $Source, [string] $Stage) {
    $status = @(Invoke-CheckedNative git @('-C', $Source, 'status', '--porcelain=v1', '--untracked-files=all'))
    if ($status.Count) {
        Write-Host ($status -join "`n")
        throw "Terraform source is dirty $Stage; refusing to build or attest to an incomplete checkout."
    }
    Write-Host "Terraform source status $Stage`: clean."
}

function Assert-BuildMetadata([string] $Metadata, [string] $ExpectedCommit) {
    $revisions = [regex]::Matches($Metadata, '(?m)^\s*build\s+vcs\.revision=([0-9a-f]{40})\s*$')
    $modified = [regex]::Matches($Metadata, '(?m)^\s*build\s+vcs\.modified=(true|false)\s*$')
    $vcs = [regex]::Matches($Metadata, '(?m)^\s*build\s+vcs=git\s*$')
    if ($revisions.Count -ne 1 -or $revisions[0].Groups[1].Value -cne $ExpectedCommit -or
        $modified.Count -ne 1 -or $modified[0].Groups[1].Value -cne 'false' -or $vcs.Count -ne 1) {
        throw 'Built binary does not attest to the exact clean source revision.'
    }
}

$env:GOTOOLCHAIN = 'local'
$buildRoot = Join-Path $script:RepositoryRoot '.build'
$source = Join-Path $buildRoot 'terraform-source'
$bin = Join-Path $buildRoot 'bin'
$env:GOCACHE = Join-Path $buildRoot 'go\build'
$env:GOMODCACHE = Join-Path $buildRoot 'go\modules'
foreach ($directory in $bin, $env:GOCACHE, $env:GOMODCACHE) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
Assert-Equal (Invoke-CheckedNative go @('env', 'GOVERSION')) "go$script:GoVersion" 'installed Go version'

if (-not (Test-Path "$source\.git")) {
    Invoke-CheckedNative git @('init', '--quiet', $source)
    Invoke-CheckedNative git @('-C', $source, 'remote', 'add', 'origin', $script:CoreRepository)
}
Assert-Equal (Invoke-CheckedNative git @('-C', $source, 'remote', 'get-url', 'origin')) $script:CoreRepository 'Terraform source remote'
Assert-CleanSource $source 'before checkout'
# Terraform's tracked test fixtures exceed MAX_PATH under hosted Windows workspace roots.
Invoke-CheckedNative git @('-C', $source, 'config', '--local', 'core.longpaths', 'true')
Invoke-CheckedNative git @('-C', $source, 'fetch', '--quiet', '--depth=1', 'origin', $script:CoreCommit)
Invoke-CheckedNative git @('-C', $source, 'checkout', '--quiet', '--detach', $script:CoreCommit)
Assert-Equal (Invoke-CheckedNative git @('-C', $source, 'rev-parse', 'HEAD')) $script:CoreCommit 'Terraform source commit'
Assert-CleanSource $source 'after checkout'
Assert-Equal ((Get-Content "$source\.go-version" -Raw).Trim()) $script:GoVersion '.go-version'
$goMod = Get-Content "$source\go.mod" -Raw
if ($goMod -notmatch "(?m)^go $([regex]::Escape($script:GoVersion))\s*$") {
    throw 'go.mod does not require the pinned Go version.'
}

$binary = Join-Path $bin 'terraform.exe'
Write-Host "Building $script:CoreRepository @ $script:CoreCommit with Go $script:GoVersion"
Push-Location $source
try {
    Invoke-CheckedNative go @('build', '-trimpath', '-buildvcs=true', '-o', $binary, '.')
} finally {
    Pop-Location
}
$metadata = (Invoke-CheckedNative go @('version', '-m', $binary)) -join "`n"
foreach ($line in $metadata -split "`n") {
    if ($line -match '^\s*build\s+vcs(?:\.|=)') { Write-Host $line.Trim() }
}
Assert-CleanSource $source 'after build'
Assert-BuildMetadata $metadata $script:CoreCommit
$version = (Invoke-CheckedNative $binary @('version', '-json') | ConvertFrom-Json).terraform_version
if ($version -notmatch '^1\.17\.0-dev') { throw "Unexpected Terraform source version: $version" }
$evidence = [ordered]@{
    repository = $script:CoreRepository
    commit = $script:CoreCommit
    goVersion = $script:GoVersion
    terraformVersion = $version
    binarySha256 = (Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    buildCommand = 'go build -trimpath -buildvcs=true -o <binary> .'
}
$json = $evidence | ConvertTo-Json
Write-Utf8 (Join-Path $script:RepositoryRoot 'evidence\build.json') "$json`n"
Write-Host $json
if ($CI -eq 'GitHub') {
    Add-Content -LiteralPath (Get-RequiredEnvironment 'GITHUB_PATH') -Value $bin
} else {
    Write-Host "##vso[task.prependpath]$bin"
}
