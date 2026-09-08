param githubSubjectPrefix string

resource identities 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = [for purpose in ['state', 'provider']: {
  name: 'id-tf36922-${purpose}'
}]

resource credentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = [for (purpose, i) in ['state', 'provider']: {
  parent: identities[i]
  name: 'github-main'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: '${githubSubjectPrefix}:ref:refs/heads/main'
    audiences: ['api://AzureADTokenExchange']
  }
}]
