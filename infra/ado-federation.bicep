param stateIssuer string
param stateSubject string
param providerIssuer string
param providerSubject string

resource stateIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: 'id-tf36922-state'
}

resource providerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: 'id-tf36922-provider'
}

resource stateCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: stateIdentity
  name: 'ado-service-connection'
  properties: {
    issuer: stateIssuer
    subject: stateSubject
    audiences: ['api://AzureADTokenExchange']
  }
}

resource providerCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: providerIdentity
  name: 'ado-service-connection'
  properties: {
    issuer: providerIssuer
    subject: providerSubject
    audiences: ['api://AzureADTokenExchange']
  }
}
