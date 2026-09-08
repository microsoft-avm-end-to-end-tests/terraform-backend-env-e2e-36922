param location string
param storageAccountName string
param githubRepository string
param tags object

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = [for purpose in ['state', 'provider']: {
  name: 'id-tf36922-${purpose}'
  location: location
  tags: tags
}]

resource githubCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = [for (purpose, i) in ['state', 'provider']: {
  parent: identities[i]
  name: 'github-main'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepository}:ref:refs/heads/main'
    audiences: ['api://AzureADTokenExchange']
  }
}]

resource account 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'None'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: account
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: 'tfstate'
  properties: {
    publicAccess: 'None'
  }
}

resource stateRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, identities[0].id, 'Storage Blob Data Contributor')
  scope: container
  properties: {
    principalId: identities[0].properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

output stateClientId string = identities[0].properties.clientId
output providerClientId string = identities[1].properties.clientId
output statePrincipalId string = identities[0].properties.principalId
output providerPrincipalId string = identities[1].properties.principalId
output containerScope string = container.id
