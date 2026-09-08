[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pipelineScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra\New-TestPipeline.ps1'

function Assert-PipelineTest([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "Pipeline configuration assertion failed: $Label" }
}

function Invoke-PipelineConfigurationCase([hashtable] $PipelineParameters, [string] $Fault) {
    $pcCross = $PipelineParameters.Topology -eq 'cross-tenant'
    $pcConfigure = [bool] $PipelineParameters.ConfigureExisting
    $pcName = if ($pcCross) { "tf36922-ado-cross-$($PipelineParameters.Mode)" } else { "tf36922-ado-$($PipelineParameters.Mode)" }
    $pcOrganization = 'https://dev.azure.com/microsoft-avm-end-to-end-tests'
    $pcProject = 'terraform-backend-env-e2e-36922'
    $pcBase = "$pcOrganization/$pcProject"
    $pcDefinitionUri = "$pcBase/_apis/build/definitions/987654?api-version=7.1"
    $pcQueueUri = "$pcBase/_apis/distributedtask/queues/3121?api-version=7.1"
    $pcSummary = @{ id = 987654; name = $pcName; url = $pcDefinitionUri }
    $pcState = @{
        Calls = [Collections.Generic.List[string]]::new()
        Writes = [Collections.Generic.List[object]]::new()
        Permissions = [Collections.Generic.List[object]]::new()
        Definition = [pscustomobject]@{
            id = $pcSummary.id
            name = $pcName
            url = $pcDefinitionUri
            repository = @{ id = 'df3508b4-890d-40b0-890b-8a39b0660f64' }
            process = @{ yamlFilename = $PipelineParameters.YamlPath }
            queue = @{ id = 99; name = 'Old queue'; pool = @{ id = 1; isHosted = $false } }
            queueStatus = if ($pcConfigure) { 'disabled' } else { 'enabled' }
            variables = @{
                AZAPI_CLIENT_ID = @{ value = 'stale-provider' }
                AZAPI_TENANT_ID = @{ value = 'stale-tenant' }
                CSUTF_AZAPI_OBJECT_ID = @{ value = 'stale-object' }
                STATE_KEY = @{ value = 'stale-state' }
                UNRELATED = @{ value = 'stale-variable' }
            }
        }
        Queue = @{ id = 3121; name = 'Azure Pipelines'; pool = @{ id = 9; isHosted = $true } }
    }
    switch ($Fault) {
        'repository' { $pcState.Definition.repository.id = '00000000-0000-0000-0000-000000000001' }
        'yaml' { $pcState.Definition.process.yamlFilename = '.ado/other.yml' }
        'pool' { $pcState.Queue.pool.id = 10 }
        'self-hosted' { $pcState.Queue.pool.isHosted = $false }
        'queue-name' { $pcState.Queue.name = 'Other queue' }
    }

    # These mocks and their mutable state live only in this invocation's scope.
    # Unknown commands/URLs fail closed; neither mock delegates to a real command.
    function az {
        $pcArguments = @($args)
        $pcCommand = ($pcArguments | Select-Object -First 2) -join ' '
        switch ($pcCommand) {
            'pipelines list' {
                $pcState.Calls.Add('list')
                $pcExpected = @('pipelines', 'list', '--organization', $pcOrganization, '--project', $pcProject, '--name', $pcName, '-o', 'json')
                Assert-PipelineTest (($pcArguments -join '|') -ceq ($pcExpected -join '|')) 'scoped pipeline lookup'
                $pcCount = if ($pcConfigure) { 1 } else { 0 }
                if ($Fault -eq 'exists') { $pcCount = 1 }
                if ($Fault -eq 'missing-definition') { $pcCount = 0 }
                if ($Fault -eq 'multiple-definitions') { $pcCount = 2 }
                ConvertTo-Json -InputObject @(
                    for ($pcIndex = 0; $pcIndex -lt $pcCount; $pcIndex++) { $pcSummary }
                ) -Compress
            }
            'pipelines create' {
                $pcState.Calls.Add('create')
                $pcExpected = @(
                    'pipelines', 'create', '--name', $pcName, '--repository', $pcProject,
                    '--repository-type', 'tfsgit', '--branch', 'main', '--yaml-path', $PipelineParameters.YamlPath,
                    '--skip-first-run', '--organization', $pcOrganization, '--project', $pcProject, '-o', 'json'
                )
                Assert-PipelineTest (($pcArguments -join '|') -ceq ($pcExpected -join '|')) 'isolated creation with no first run'
                $pcSummary | ConvertTo-Json -Compress
            }
            'account get-access-token' {
                $pcState.Calls.Add('token')
                $pcExpected = @(
                    'account', 'get-access-token', '--subscription', '121e2ce8-c399-4fea-958a-09d15ed949c4',
                    '--resource', '499b84ac-1321-427f-aa17-267ca6975798', '--query', 'accessToken', '-o', 'tsv'
                )
                Assert-PipelineTest (($pcArguments -join '|') -ceq ($pcExpected -join '|')) 'subscription-scoped ADO token'
                'offline-fixture-token'
            }
            default { throw 'Unexpected az command in offline test.' }
        }
    }

    function Invoke-RestMethod {
        [CmdletBinding()]
        param([string] $Method = 'Get', [hashtable] $Headers, [string] $Uri, [string] $ContentType, [string] $Body)

        Assert-PipelineTest ($Headers.Authorization -ceq 'Bearer offline-fixture-token') 'REST authentication'
        if ($Method -eq 'Get' -and $Uri -eq $pcDefinitionUri) {
            $pcState.Calls.Add('get-definition')
            $pcState.Definition | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        } elseif ($Method -eq 'Get' -and $Uri -eq $pcQueueUri) {
            $pcState.Calls.Add('get-queue')
            $pcState.Queue | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        } elseif ($Method -eq 'Put' -and $Uri -eq $pcDefinitionUri) {
            $pcState.Calls.Add('put')
            Assert-PipelineTest ($ContentType -eq 'application/json') 'definition content type'
            $pcState.Writes.Add(($Body | ConvertFrom-Json -AsHashtable))
            $pcState.Definition = $Body | ConvertFrom-Json
            $pcState.Definition | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        } elseif ($Method -eq 'Patch' -and $Uri.StartsWith("$pcBase/_apis/pipelines/pipelinepermissions/endpoint/")) {
            $pcState.Calls.Add('patch')
            Assert-PipelineTest ($ContentType -eq 'application/json') 'permission content type'
            $pcState.Permissions.Add(@{ Uri = $Uri; Body = $Body | ConvertFrom-Json -AsHashtable })
            if (($Fault -eq 'state-authorization' -and $pcState.Permissions.Count -eq 1) -or
                ($Fault -eq 'provider-authorization' -and $pcState.Permissions.Count -eq 2)) {
                throw 'Synthetic authorization failure.'
            }
            [pscustomobject]@{}
        } else {
            throw 'Unexpected REST request in offline test.'
        }
    }

    $pcFailure = $null
    $pcOutput = @()
    try { $pcOutput = @(& $pipelineScript @PipelineParameters *>&1) } catch { $pcFailure = $_.Exception.Message }
    # Never echo captured output or headers, even when an assertion fails.
    Assert-PipelineTest (($pcOutput -join "`n") -notmatch 'offline-fixture-token') 'no token output'
    [pscustomobject]@{
        Calls = $pcState.Calls
        Writes = $pcState.Writes
        Permissions = $pcState.Permissions
        Output = $pcOutput
        Failure = $pcFailure
    }
}

$stateValues = @{
    STATE_CLIENT_ID = '4387b74e-0954-4630-a230-4c3a766c2b34'
    STATE_TENANT_ID = '13b2a159-de04-4835-a3ad-fd814c6adb4f'
    STATE_SUBSCRIPTION_ID = '121e2ce8-c399-4fea-958a-09d15ed949c4'
    STATE_STORAGE_ACCOUNT_NAME = 'sttf36922e8195f'
    STATE_CONTAINER_NAME = 'tfstate'
    STATE_KEY = 'tf36922'
}
$stateConnection = 'a772cbab-ead7-4c84-93bf-24a22ec6ab3c'
$sameConnection = 'bbfc21fb-7bc1-47b2-9578-89a4445edb31'
$crossConnection = '33333333-3333-4333-8333-333333333333'
$passed = 0
foreach ($topology in 'same-tenant', 'cross-tenant') {
    $cross = $topology -eq 'cross-tenant'
    foreach ($mode in 'default', 'strict') {
        foreach ($configure in $false, $true) {
            $parameters = @{
                Mode = $mode
                Topology = $topology
                YamlPath = if ($cross) { ".ado/ado-cross-$mode.yml" } else { ".ado/ado-$mode.yml" }
                ConfigureExisting = $configure
            }
            if ($cross) {
                $parameters.CsutfClientId = '11111111-1111-4111-8111-111111111111'
                $parameters.CsutfObjectId = '22222222-2222-4222-8222-222222222222'
                $parameters.CsutfConnectionId = $crossConnection
            }
            $label = "$topology/$mode/configure=$configure"
            $result = Invoke-PipelineConfigurationCase $parameters
            Assert-PipelineTest (-not $result.Failure) "$label succeeds"
            $expectedCalls = if ($configure) {
                'list,token,get-definition,get-queue,put,patch,patch,get-definition,put'
            } else {
                'list,create,token,get-definition,get-queue,put,patch,patch'
            }
            Assert-PipelineTest (($result.Calls -join ',') -ceq $expectedCalls) "$label operation ordering"
            $expectedValues = $stateValues.Clone()
            if ($cross) {
                $expectedValues.CSUTF_AZAPI_CLIENT_ID = $parameters.CsutfClientId
                $expectedValues.CSUTF_AZAPI_OBJECT_ID = $parameters.CsutfObjectId
                $expectedValues.CSUTF_AZAPI_TENANT_ID = 'dac8feee-8768-4fbd-9cf9-9d96d4718018'
                $expectedValues.CSUTF_AZAPI_SUBSCRIPTION_ID = '66bd4c09-0b95-49f7-9db1-a8f69c54e827'
            } else {
                $expectedValues.AZAPI_CLIENT_ID = 'b1c4b1f6-46bc-43ff-8109-55f4d2b6cc33'
                $expectedValues.AZAPI_OBJECT_ID = '4018377b-0c35-4934-8498-23d83f0fa11a'
                $expectedValues.AZAPI_TENANT_ID = $stateValues.STATE_TENANT_ID
                $expectedValues.AZAPI_SUBSCRIPTION_ID = $stateValues.STATE_SUBSCRIPTION_ID
            }
            foreach ($write in $result.Writes) {
                Assert-PipelineTest ($write.id -eq 987654) "$label definition ID"
                Assert-PipelineTest ($write.queue.id -eq 3121 -and $write.queue.pool.id -eq 9 -and
                    $write.queue.pool.isHosted -eq $true -and $write.queue.name -ceq 'Azure Pipelines') "$label hosted queue pinned"
                Assert-PipelineTest (($write.variables.Keys | Sort-Object) -join ',' -ceq
                    (($expectedValues.Keys | Sort-Object) -join ',')) "$label exact variable names; no overlapping globals"
                foreach ($key in $expectedValues.Keys) {
                    $entry = $write.variables[$key]
                    Assert-PipelineTest ($entry.value -ceq $expectedValues[$key] -and
                        $entry.isSecret -eq $false -and $entry.allowOverride -eq $false) "$label $key value and flags"
                }
            }
            if ($configure) {
                Assert-PipelineTest ($result.Writes[0].queueStatus -eq 'disabled' -and
                    $result.Writes[1].queueStatus -eq 'enabled') "$label only enables after authorization"
            }
            $providerConnection = if ($cross) { $crossConnection } else { $sameConnection }
            $endpointIds = @($stateConnection, $providerConnection)
            for ($i = 0; $i -lt $endpointIds.Count; $i++) {
                $permission = $result.Permissions[$i]
                $expectedUri = "https://dev.azure.com/microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922/_apis/pipelines/pipelinepermissions/endpoint/$($endpointIds[$i])?api-version=7.1-preview.1"
                Assert-PipelineTest ($permission.Uri -ceq $expectedUri) "$label selected endpoint only"
                Assert-PipelineTest (($permission.Body.Keys -join ',') -eq 'pipelines' -and
                    $permission.Body.pipelines.Count -eq 1 -and $permission.Body.pipelines[0].id -eq 987654 -and
                    $permission.Body.pipelines[0].authorized -eq $true) "$label authorizes only this pipeline"
            }
            $summary = ($result.Output -join "`n") | ConvertFrom-Json
            $expectedName = if ($cross) { "tf36922-ado-cross-$mode" } else { "tf36922-ado-$mode" }
            Assert-PipelineTest ($summary.id -eq 987654 -and $summary.name -ceq $expectedName) "$label output summary"
            $passed++

            if ($mode -ne 'default') { continue }
            foreach ($fault in 'repository', 'yaml', 'pool', 'self-hosted', 'queue-name') {
                $result = Invoke-PipelineConfigurationCase $parameters $fault
                $expectedFailure = if ($fault -in 'repository', 'yaml') { 'repository or YAML' } else { 'hosted pool' }
                Assert-PipelineTest ($result.Failure -match $expectedFailure) "$label rejects $fault"
                $readCalls = if ($configure) { 'list,token,get-definition' } else { 'list,create,token,get-definition' }
                if ($fault -notin 'repository', 'yaml') { $readCalls += ',get-queue' }
                Assert-PipelineTest (($result.Calls -join ',') -ceq $readCalls -and $result.Writes.Count -eq 0 -and
                    $result.Permissions.Count -eq 0) "$label $fault fails before PUT/PATCH"
                $passed++
            }
            if ($cross) {
                foreach ($key in 'CsutfClientId', 'CsutfObjectId', 'CsutfConnectionId') {
                    $missing = $parameters.Clone()
                    $missing.Remove($key)
                    $result = Invoke-PipelineConfigurationCase $missing
                    Assert-PipelineTest ($result.Failure -match 'require the newly provisioned CSUTF' -and
                        $result.Calls.Count -eq 0) "$label missing $key fails before az"
                    $passed++
                }
                if ($configure) {
                    foreach ($fault in 'state-authorization', 'provider-authorization') {
                        $result = Invoke-PipelineConfigurationCase $parameters $fault
                        $expectedCalls = 'list,token,get-definition,get-queue,put,patch'
                        if ($fault -eq 'provider-authorization') { $expectedCalls += ',patch' }
                        Assert-PipelineTest ($result.Failure -eq 'Synthetic authorization failure.' -and
                            ($result.Calls -join ',') -ceq $expectedCalls -and $result.Writes.Count -eq 1 -and
                            $result.Writes[0].queueStatus -eq 'disabled') "$label $fault must not enable"
                        $passed++
                    }
                }
            } else {
                $faults = if ($configure) { @('missing-definition', 'multiple-definitions') } else { @('exists') }
                foreach ($fault in $faults) {
                    $result = Invoke-PipelineConfigurationCase $parameters $fault
                    $expectedFailure = if ($configure) { 'Expected exactly one prepared pipeline' } else { 'already exists' }
                    Assert-PipelineTest ($result.Failure -match $expectedFailure -and
                        ($result.Calls -join ',') -ceq 'list') "$label rejects $fault before token/create/REST"
                    $passed++
                }
            }
        }
    }
}
Write-Host "PASS: $passed offline pipeline configuration cases (scoped az/REST mocks; no Azure/CI operations)."
