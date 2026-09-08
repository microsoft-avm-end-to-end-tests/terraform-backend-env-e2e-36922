targetScope = 'subscription'

param location string = 'westeurope'
param githubSubjectPrefix string = 'repo:microsoft-avm-end-to-end-tests@177230035/terraform-backend-env-e2e-36922@1361231930'

var tags = {
  purpose: 'terraform-backend-env-e2e-cross-tenant'
  sourceCommit: '0c5e9bef8b6d76866b0f0ddedab5b72af51bcc27'
}
var cases = ['gh-default', 'gh-strict', 'ado-default', 'ado-strict']

resource identityGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-tf36922-csutf-provider'
  location: location
  tags: tags
}

resource targetGroups 'Microsoft.Resources/resourceGroups@2025-04-01' = [for testCase in cases: {
  name: 'rg-tf36922-e8195f-${testCase}'
  location: location
  tags: tags
}]

module identity './provider-identity.bicep' = {
  name: 'tf36922-csutf-provider'
  scope: identityGroup
  params: {
    location: location
    githubSubjectPrefix: githubSubjectPrefix
    tags: tags
  }
}

module roles './provider-role.bicep' = [for (testCase, i) in cases: {
  name: 'tf36922-csutf-${testCase}'
  scope: targetGroups[i]
  params: {
    principalId: identity.outputs.principalId
  }
}]

output clientId string = identity.outputs.clientId
output principalId string = identity.outputs.principalId
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
