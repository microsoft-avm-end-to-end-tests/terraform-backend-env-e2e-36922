[CmdletBinding()]
param(
    [string] $DocsPath,
    [switch] $Check
)

. "$PSScriptRoot\Harness.Common.ps1"

function Replace-Once([string] $Text, [string] $Old, [string] $New) {
    if ([regex]::Matches($Text, [regex]::Escape($Old)).Count -ne 1) {
        throw "Expected exactly one adaptation target: $Old"
    }
    return $Text.Replace($Old, $New)
}

function Get-AuthSignature([string] $Text) {
    return (($Text -split "`n" | Where-Object {
        $_ -match '^\s*(ARM_[A-Z_]+:|SYSTEM_ACCESSTOKEN:|\$env:ARM_[A-Z_]+\s*=|\$(clientId|tenantId|connectionId|subscriptionId)\s*=|Write-Host "##vso\[task.setvariable variable=STATE_)'
    } | ForEach-Object { $_.Trim() }) -join "`n")
}

$files = [ordered]@{}
$sourceRoot = Join-Path $script:RepositoryRoot 'examples\source'
if ($DocsPath) {
    $DocsPath = (Resolve-Path -LiteralPath $DocsPath).Path
    $docsRoot = (& git -C (Split-Path $DocsPath -Parent) rev-parse --show-toplevel).Replace('/', '\')
    Assert-Equal ([IO.Path]::GetFullPath($DocsPath)) ([IO.Path]::GetFullPath((Join-Path $docsRoot $script:DocsRelativePath.Replace('/', '\')))) 'authorized documentation path'
    Assert-Equal (& git -C $docsRoot rev-parse HEAD) $script:DocsCommit 'documentation checkout revision'
    $text = ConvertTo-Lf (Get-Content -LiteralPath $DocsPath -Raw)
    $committed = ((& git -C $docsRoot show "${script:DocsCommit}:$script:DocsRelativePath") -join "`n") + "`n"
    if ($text -cne $committed) { throw 'Documentation content differs from the pinned commit.' }
    $manifest = [ordered]@{
        docsRepository = 'https://github.com/hashicorp/web-unified-docs'
        docsPullRequest = 'https://github.com/hashicorp/web-unified-docs/pull/3332'
        docsCommit = $script:DocsCommit
        docsPath = $script:DocsRelativePath
        docsBlob = (& git -C $docsRoot rev-parse "${script:DocsCommit}:$script:DocsRelativePath")
        docsSha256Lf = Get-TextHash $text
        coreRepository = $script:CoreRepository
        coreCommit = $script:CoreCommit
        corePullRequest = 'https://github.com/hashicorp/terraform/pull/36922'
        goVersion = $script:GoVersion
        snippets = @()
    }
    foreach ($mode in $script:Modes.Keys) {
        $heading = $script:Modes[$mode]
        $sections = [regex]::Matches($text, "(?ms)^#### $([regex]::Escape($heading))`n(?<body>.*?)(?=^#{1,4} |\z)")
        if ($sections.Count -ne 1) { throw "Missing or ambiguous heading: $heading" }
        $entry = [ordered]@{ mode = $mode; heading = $heading }
        foreach ($language in 'hcl', 'yaml') {
            $fences = [regex]::Matches($sections[0].Groups['body'].Value, '(?ms)^```' + $language + '\n(?<code>.*?)^```\s*$')
            if ($fences.Count -ne 1) { throw "Expected one $language fence under $heading" }
            $code = $fences[0].Groups['code'].Value
            $leaf = if ($language -eq 'hcl') { 'main.tf' } else { 'pipeline.yml' }
            $files["examples\source\$mode\$leaf"] = $code
            $entry["${language}Sha256"] = Get-TextHash $code
        }
        $manifest.snippets += $entry
    }
    $files['examples\source\provenance.json'] = ($manifest | ConvertTo-Json -Depth 8) + "`n"
} else {
    $manifest = Get-Content "$sourceRoot\provenance.json" -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal $manifest.docsCommit $script:DocsCommit 'recorded documentation revision'
    Assert-Equal $manifest.coreCommit $script:CoreCommit 'recorded core revision'
    Assert-Equal $manifest.goVersion $script:GoVersion 'recorded Go version'
    if ($manifest.snippets.Count -ne 4) { throw 'Expected exactly four provenance entries.' }
    foreach ($mode in $script:Modes.Keys) {
        $entries = @($manifest.snippets | Where-Object { $_.mode -eq $mode })
        if ($entries.Count -ne 1) { throw "Missing source provenance for $mode" }
        $entry = $entries[0]
        Assert-Equal $entry.heading $script:Modes[$mode] 'source heading'
        foreach ($language in 'hcl', 'yaml') {
            $leaf = if ($language -eq 'hcl') { 'main.tf' } else { 'pipeline.yml' }
            $code = ConvertTo-Lf (Get-Content "$sourceRoot\$mode\$leaf" -Raw)
            Assert-Equal (Get-TextHash $code) $entry["${language}Sha256"] "$mode $language source hash"
            $files["examples\source\$mode\$leaf"] = $code
        }
    }
}

$githubBuild = ConvertTo-Lf @'
      - name: Validate fixtures and prepare isolated run
        shell: pwsh
        run: |
          .\scripts\Test-Fixtures.ps1
          .\scripts\Initialize-Run.ps1 -Mode __MODE__
        env:
          AZAPI_CLIENT_ID: ${{ vars.AZAPI_CLIENT_ID }}
          AZAPI_TENANT_ID: ${{ vars.AZAPI_TENANT_ID }}
          AZAPI_SUBSCRIPTION_ID: ${{ vars.AZAPI_SUBSCRIPTION_ID }}
          STATE_CLIENT_ID: ${{ vars.STATE_CLIENT_ID }}
          STATE_TENANT_ID: ${{ vars.STATE_TENANT_ID }}
          STATE_SUBSCRIPTION_ID: ${{ vars.STATE_SUBSCRIPTION_ID }}

      - uses: actions/setup-go@v6
        with:
          go-version: '1.26.4'
          cache: false

      - uses: actions/cache@v4
        with:
          path: .build\go
          key: go-${{ runner.os }}-1.26.4-__CORE_COMMIT__

      - name: Build pinned Terraform source (never a release binary)
        shell: pwsh
        run: .\scripts\Build-Terraform.ps1 -CI GitHub
'@
$githubEnd = ConvertTo-Lf @'

      - name: Remove local plan and state even after failure
        if: always()
        shell: pwsh
        run: .\scripts\Remove-Run.ps1

      - name: Publish sanitized evidence only
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: evidence-__MODE__-${{ github.run_id }}-${{ github.run_attempt }}
          path: evidence\*.json
          if-no-files-found: ignore
          retention-days: 7
'@
$adoBuild = ConvertTo-Lf @'
  - pwsh: |
      .\scripts\Test-Fixtures.ps1
      .\scripts\Initialize-Run.ps1 -Mode __MODE__
    displayName: Validate fixtures and prepare isolated run
    env:
      AZAPI_CLIENT_ID: $(AZAPI_CLIENT_ID)
      AZAPI_TENANT_ID: $(AZAPI_TENANT_ID)
      AZAPI_SUBSCRIPTION_ID: $(AZAPI_SUBSCRIPTION_ID)
      STATE_CLIENT_ID: $(STATE_CLIENT_ID)
      STATE_TENANT_ID: $(STATE_TENANT_ID)
      STATE_SUBSCRIPTION_ID: $(STATE_SUBSCRIPTION_ID)
      STATE_STORAGE_ACCOUNT_NAME: $(STATE_STORAGE_ACCOUNT_NAME)
      STATE_CONTAINER_NAME: $(STATE_CONTAINER_NAME)
      STATE_KEY: $(STATE_KEY)

  - task: GoTool@0
    displayName: Install pinned Go toolchain
    inputs:
      version: '1.26.4'

  - task: Cache@2
    displayName: Cache Go modules and compilation only
    inputs:
      key: '"go" | "$(Agent.OS)" | "1.26.4" | "__CORE_COMMIT__"'
      path: '$(Build.SourcesDirectory)\.build\go'

  - pwsh: .\scripts\Build-Terraform.ps1 -CI AzurePipelines
    displayName: Build pinned Terraform source (never a release binary)
'@
$adoEnd = ConvertTo-Lf @'

  - pwsh: .\scripts\Remove-Run.ps1
    displayName: Remove local plan and state even after failure
    condition: always()

  - task: PublishPipelineArtifact@1
    displayName: Publish sanitized evidence only
    condition: and(always(), ne(variables['HARNESS_RUN_NAME'], ''))
    inputs:
      targetPath: '$(Build.SourcesDirectory)\evidence'
      artifact: evidence-__MODE__-$(Build.BuildId)-$(System.JobAttempt)
'@

foreach ($mode in $script:Modes.Keys) {
    $hcl = $files["examples\source\$mode\main.tf"]
    $hcl = Replace-Once $hcl 'name      = "example-resources"' "name      = `"rg-tf36922-e8195f-$mode`""
    $files["examples\$mode\main.tf"] = $hcl

    $original = $files["examples\source\$mode\pipeline.yml"]
    $yaml = $original
    $github = $mode.StartsWith('gh-')
    if ($github) {
        $yaml = [regex]::Replace($yaml, '^name: .+', "name: Terraform backend $mode (pinned source)")
        $yaml = Replace-Once $yaml 'runs-on: ubuntu-latest' "runs-on: windows-2022`n    timeout-minutes: 90"
        $installer = ConvertTo-Lf @'
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ vars.TERRAFORM_VERSION }}
          terraform_wrapper: false
'@
        $yaml = Replace-Once $yaml $installer $githubBuild.Replace('__MODE__', $mode).Replace('__CORE_COMMIT__', $script:CoreCommit)
        $indent = '          '
        $yaml += $githubEnd.Replace('__MODE__', $mode) + "`n"
        $path = ".github\workflows\$mode.yml"
    } else {
        $yaml = Replace-Once $yaml 'trigger: none' "trigger: none`npr: none"
        $yaml = Replace-Once $yaml 'vmImage: ubuntu-latest' 'vmImage: windows-2022'
        $yaml = Replace-Once $yaml 'azureSubscription: $(STATE_SERVICE_CONNECTION)' 'azureSubscription: sc-tf36922-state'
        $yaml = Replace-Once $yaml 'azureSubscription: $(AZAPI_SERVICE_CONNECTION)' 'azureSubscription: sc-tf36922-provider'
        $installer = ConvertTo-Lf @'
  - task: TerraformInstaller@1
    displayName: "[Terraform] Install Terraform"
    inputs:
      terraformVersion: $(TERRAFORM_VERSION)
'@
        $yaml = Replace-Once $yaml $installer $adoBuild.Replace('__MODE__', $mode).Replace('__CORE_COMMIT__', $script:CoreCommit)
        $indent = '        '
        $yaml += $adoEnd.Replace('__MODE__', $mode) + "`n"
        $path = ".ado\$mode.yml"
    }
    $nativePreference = '$PSNativeCommandUseErrorActionPreference = $true'
    if ([regex]::Matches($yaml, [regex]::Escape($nativePreference)).Count -ne 2) {
        throw 'Expected separate init and plan script boundaries.'
    }
    $yaml = $yaml.Replace($nativePreference, "$nativePreference`n`n${indent}Set-Location `$env:HARNESS_WORK_DIR")
    $init = 'terraform init -input=false `'
    $guard = '& "$env:HARNESS_SCRIPT_DIR\Assert-Run.ps1" -Mode ' + $mode + ' -Phase Init'
    $yaml = Replace-Once $yaml $init "$guard`n`n$indent$init"
    $plan = 'terraform plan -input=false -out=tfplan'
    $checkedPlan = @(
        ('& "$env:HARNESS_SCRIPT_DIR\Assert-Run.ps1" -Mode ' + $mode + ' -Phase Plan')
        'try {'
        "  $plan"
        ('  & "$env:HARNESS_SCRIPT_DIR\Test-Plan.ps1" -Mode ' + $mode)
        '} finally {'
        '  & "$env:HARNESS_SCRIPT_DIR\Remove-Run.ps1"'
        '}'
    ) -join "`n$indent"
    $yaml = Replace-Once $yaml $plan $checkedPlan
    Assert-Equal (Get-AuthSignature $yaml) (Get-AuthSignature $original) "$mode exact source authentication sequence"
    $files[$path] = "# Generated by scripts\Export-Fixtures.ps1; authentication comes from pinned documentation.`n$yaml"
}

foreach ($entry in $files.GetEnumerator()) {
    $path = Join-Path $script:RepositoryRoot $entry.Key
    $expectedContent = ConvertTo-Lf $entry.Value
    if ($Check) {
        if (-not (Test-Path -LiteralPath $path) -or (ConvertTo-Lf (Get-Content -LiteralPath $path -Raw)) -cne $expectedContent) {
            throw "Generated fixture drift: $($entry.Key)"
        }
    } else {
        Write-Utf8 $path $expectedContent
    }
}
Write-Host "$(if ($Check) { 'Verified' } else { 'Exported' }) four HCL/YAML fixtures, source hashes and exact authentication sequences."
