targetScope = 'managementGroup'

metadata description = 'Atomity read-only connection for Azure, at management group scope: Reader on the management group and Storage Blob Data Reader on the billing export storage account. It creates role assignments only. It does not create the Service Principal or the Cost Management export. To grant Reader on individual subscriptions instead, use subscription.bicep.'

@description('Object ID of Atomity\'s Service Principal in your tenant. Get it with: az ad sp show --id c4b84012-e86e-4ea0-9c42-5e015c1c30f4 --query id -o tsv')
@minLength(36)
@maxLength(36)
param atomityServicePrincipalObjectId string

@description('Subscription ID where your billing export storage account is located.')
@minLength(36)
@maxLength(36)
param storageAccountSubscriptionId string

@description('Resource group name where your billing export storage account is located.')
@minLength(1)
param storageAccountResourceGroupName string

@description('Name of the existing storage account designated to receive the FOCUS cost export.')
@minLength(3)
@maxLength(24)
param storageAccountName string

// Azure built-in role definition ID
var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// ---------------------------------------------------------------------------
// 1. Management group: assign "Reader" to Atomity's Service Principal
// ---------------------------------------------------------------------------
resource readerRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: tenant()
  name: readerRoleDefinitionId
}

resource managementGroupReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, atomityServicePrincipalObjectId, readerRoleDefinitionId)
  properties: {
    roleDefinitionId: readerRoleDefinition.id
    principalId: atomityServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    description: 'Atomity read-only access for inventory, metrics, and recommendations across the management group.'
  }
}

// ---------------------------------------------------------------------------
// 2. Storage account: cross-scope module that assigns "Storage Blob Data Reader"
// ---------------------------------------------------------------------------
module storageAccountRoleAssignment 'modules/storage-role.bicep' = {
  name: 'atomity-storage-role-deployment'
  scope: resourceGroup(storageAccountSubscriptionId, storageAccountResourceGroupName)
  params: {
    atomityServicePrincipalObjectId: atomityServicePrincipalObjectId
    storageAccountName: storageAccountName
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('The scope where the Reader role was assigned.')
output readerScope string = managementGroup().id

@description('The storage account receiving the export.')
output storageAccount string = storageAccountName

@description('Confirmation of the storage account role assignment ID.')
output storageRoleAssignmentId string = storageAccountRoleAssignment.outputs.roleAssignmentId
