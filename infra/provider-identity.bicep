param location string
param githubSubjectPrefix string
param tags object

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-tf36922-csutf-provider'
  location: location
  tags: tags
}

resource githubCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: identity
  name: 'github-main'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: '${githubSubjectPrefix}:ref:refs/heads/main'
    audiences: ['api://AzureADTokenExchange']
  }
}

output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId
