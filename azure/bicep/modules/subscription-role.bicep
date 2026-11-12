targetScope = 'subscription'

@description('The Object ID of Atomity\'s Service Principal.')
param atomityServicePrincipalObjectId string

// Reader built-in role GUID
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: tenant()
  name: readerRoleId
}

resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, atomityServicePrincipalObjectId, readerRoleId)
  properties: {
    roleDefinitionId: readerRoleDefinition.id
    principalId: atomityServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    description: 'Atomity read-only inventory and metrics access on this subscription.'
  }
}

output roleAssignmentId string = readerRoleAssignment.id