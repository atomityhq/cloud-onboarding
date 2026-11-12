targetScope = 'resourceGroup'

@description('The Object ID of Atomity\'s Service Principal.')
param atomityServicePrincipalObjectId string

@description('The target storage account name.')
param storageAccountName string

var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource storageRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: tenant()
  name: storageBlobDataReaderRoleId
}

resource storageBlobDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, atomityServicePrincipalObjectId, storageBlobDataReaderRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageRoleDefinition.id
    principalId: atomityServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    description: 'Atomity read-only access to billing export Parquet files in this storage account.'
  }
}

output roleAssignmentId string = storageBlobDataReaderAssignment.id