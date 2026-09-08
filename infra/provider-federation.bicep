param issuer string
param subject string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: 'id-tf36922-csutf-provider'
}

resource credential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: identity
  name: 'ado-service-connection'
  properties: {
    issuer: issuer
    subject: subject
    audiences: ['api://AzureADTokenExchange']
  }
}
