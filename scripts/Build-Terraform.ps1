[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('GitHub', 'AzurePipelines')][string] $CI)

. "$PSScriptRoot\Harness.Common.ps1"
$env:GOTOOLCHAIN = 'local'
$buildRoot = Join-Path $script:RepositoryRoot '.build'
$source = Join-Path $buildRoot 'terraform-source'
$bin = Join-Path $buildRoot 'bin'
$env:GOCACHE = Join-Path $buildRoot 'go\build'
$env:GOMODCACHE = Join-Path $buildRoot 'go\modules'
foreach ($directory in $bin, $env:GOCACHE, $env:GOMODCACHE) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
Assert-Equal (& go env GOVERSION) "go$script:GoVersion" 'installed Go version'

if (-not (Test-Path "$source\.git")) {
    & git init --quiet $source
    & git -C $source remote add origin $script:CoreRepository
}
Assert-Equal (& git -C $source remote get-url origin) $script:CoreRepository 'Terraform source remote'
if (& git -C $source status --porcelain) { throw 'Refusing a dirty Terraform source checkout.' }
& git -C $source fetch --quiet --depth=1 origin $script:CoreCommit
& git -C $source checkout --quiet --detach $script:CoreCommit
Assert-Equal (& git -C $source rev-parse HEAD) $script:CoreCommit 'Terraform source commit'
Assert-Equal ((Get-Content "$source\.go-version" -Raw).Trim()) $script:GoVersion '.go-version'
$goMod = Get-Content "$source\go.mod" -Raw
if ($goMod -notmatch "(?m)^go $([regex]::Escape($script:GoVersion))\s*$") {
    throw 'go.mod does not require the pinned Go version.'
}

$binary = Join-Path $bin 'terraform.exe'
Write-Host "Building $script:CoreRepository @ $script:CoreCommit with Go $script:GoVersion"
Push-Location $source
try {
    & go build -trimpath -buildvcs=true -o $binary .
} finally {
    Pop-Location
}
$metadata = (& go version -m $binary) -join "`n"
if ($metadata -notmatch "vcs.revision=$script:CoreCommit" -or $metadata -notmatch 'vcs.modified=false') {
    throw 'Built binary does not attest to the exact clean source revision.'
}
$version = (& $binary version -json | ConvertFrom-Json).terraform_version
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
