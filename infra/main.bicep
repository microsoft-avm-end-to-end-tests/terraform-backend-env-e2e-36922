targetScope = 'subscription'

param location string = 'westeurope'
param prefix string = 'tf36922-e8195f'
param storageAccountName string = 'sttf36922e8195f'
param githubRepository string = 'microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922'

var tags = {
  purpose: 'terraform-backend-env-e2e'
  sourceCommit: 'e8195f605d24299788cdf36738915d84563e4c58'
}
var cases = [
  'gh-default'
  'gh-strict'
  'ado-default'
  'ado-strict'
]

resource stateGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: 'rg-${prefix}-state'
  location: location
  tags: tags
}

resource targetGroups 'Microsoft.Resources/resourceGroups@2025-04-01' = [for testCase in cases: {
  name: 'rg-${prefix}-${testCase}'
  location: location
  tags: tags
}]

module state './state.bicep' = {
  name: '${prefix}-state'
  scope: stateGroup
  params: {
    location: location
    storageAccountName: storageAccountName
    githubRepository: githubRepository
    tags: tags
  }
}

module providerRoles './provider-role.bicep' = [for (testCase, i) in cases: {
  name: '${prefix}-${testCase}-role'
  scope: targetGroups[i]
  params: {
    principalId: state.outputs.providerPrincipalId
  }
}]

output stateClientId string = state.outputs.stateClientId
output providerClientId string = state.outputs.providerClientId
output statePrincipalId string = state.outputs.statePrincipalId
output providerPrincipalId string = state.outputs.providerPrincipalId
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
output storageAccount string = storageAccountName
output containerScope string = state.outputs.containerScope
