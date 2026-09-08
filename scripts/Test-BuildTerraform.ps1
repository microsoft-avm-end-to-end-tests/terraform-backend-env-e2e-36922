[CmdletBinding()]
param([string] $MetadataPath)

. "$PSScriptRoot\Harness.Common.ps1"
$buildScript = Get-Content "$PSScriptRoot\Build-Terraform.ps1" -Raw
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($buildScript, [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw 'Build-Terraform.ps1 does not parse.' }
foreach ($name in 'Invoke-CheckedNative', 'Assert-CleanSource', 'Assert-BuildMetadata') {
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $false))
    if ($definitions.Count -ne 1) { throw "Expected one build helper: $name" }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

$metadata = "terraform.exe: go1.26.4`n`tbuild`tvcs=git`n`tbuild`tvcs.revision=$script:CoreCommit`n`tbuild`tvcs.modified=false`n"
Assert-BuildMetadata $metadata $script:CoreCommit
Assert-BuildMetadata ($metadata.Replace("`n", "`r`n")) $script:CoreCommit
$cases = @(
    $metadata.Replace('vcs.modified=false', 'vcs.modified=true')
    $metadata.Replace($script:CoreCommit, ('0' * 40))
    $metadata.Replace("`tbuild`tvcs.modified=false`n", '')
    $metadata.Replace("`tbuild`tvcs.revision=", "`tmod`tvcs.revision=")
    ($metadata + "`tbuild`tvcs.modified=false`n")
    $metadata.Replace("`tbuild`tvcs=git`n", '')
)
foreach ($bad in $cases) {
    $rejected = $false
    try { Assert-BuildMetadata $bad $script:CoreCommit } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid binary metadata was accepted.' }
}

$pwsh = (Get-Command pwsh -CommandType Application).Source
$PSNativeCommandUseErrorActionPreference = $false
$result = Invoke-CheckedNative $pwsh @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output native-ok; exit 0')
Assert-Equal $result 'native-ok' 'native output'
$rejected = $false
try {
    Invoke-CheckedNative $pwsh @('-NoProfile', '-NonInteractive', '-Command', 'exit 37')
} catch {
    $rejected = $_.Exception.Message -match 'failed with exit code 37'
}
if (-not $rejected) { throw 'Native command failure was ignored with automatic native errors disabled.' }

function git {
    $global:LASTEXITCODE = 0
    if ($script:FakeGitStatus) { $script:FakeGitStatus }
}
$script:FakeGitStatus = $null
Assert-CleanSource 'synthetic-source' 'after checkout' 6>$null
$script:FakeGitStatus = ' D internal/stacks/stackruntime/testdata/missing-long-path-fixture.tfcomponent.hcl'
$rejected = $false
try { Assert-CleanSource 'synthetic-source' 'after checkout' 6>$null } catch {
    $rejected = $_.Exception.Message -match 'dirty after checkout'
}
if (-not $rejected) { throw 'Incomplete checkout was not rejected before compilation.' }

$longPaths = $buildScript.IndexOf("'config', '--local', 'core.longpaths', 'true'")
$checkout = $buildScript.IndexOf("'checkout', '--quiet', '--detach'")
$cleanBeforeBuild = $buildScript.IndexOf("Assert-CleanSource `$source 'after checkout'")
$compile = $buildScript.IndexOf("'build', '-trimpath', '-buildvcs=true'")
$cleanAfterBuild = $buildScript.IndexOf("Assert-CleanSource `$source 'after build'")
if ($longPaths -lt 0 -or $checkout -le $longPaths -or $cleanBeforeBuild -le $checkout -or
    $compile -le $cleanBeforeBuild -or $cleanAfterBuild -le $compile) {
    throw 'Long-path checkout and pre/post-build clean-tree gates are out of order.'
}
if ($MetadataPath) {
    Assert-BuildMetadata (Get-Content -LiteralPath $MetadataPath -Raw) $script:CoreCommit
}
Write-Host 'PASS: eight metadata cases, checked native exit codes, incomplete-checkout rejection, and long-path/build gate ordering.'
