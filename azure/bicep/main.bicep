targetScope = 'managementGroup'

@description('Object ID of Atomity\'s Service Principal in your tenant (obtained after Step 1 admin consent).')
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

@description('How inventory and metrics access is scoped: management_group (recommended) or subscription.')
@allowed([
  'management_group'
  'subscription'
])
param scopeMode string = 'management_group'

@description('List of subscription IDs to grant Reader on when scopeMode is "subscription".')
param subscriptionIds array = []

@description('Deployment location metadata (used by ARM for deployment records).')
param location string = deployment().location

// Azure Built-in Role Definition IDs
var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// ---------------------------------------------------------------------------
// 1. Management Group Scope: Assign "Reader" to Atomity's Service Principal
// ---------------------------------------------------------------------------
resource readerRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: tenant()
  name: readerRoleDefinitionId
}

resource managementGroupReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (scopeMode == 'management_group') {
  name: guid(managementGroup().id, atomityServicePrincipalObjectId, readerRoleDefinitionId)
  properties: {
    roleDefinitionId: readerRoleDefinition.id
    principalId: atomityServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    description: 'Atomity read-only access for inventory, metrics, and recommendations across the management group.'
  }
}

// ---------------------------------------------------------------------------
// 2. Subscription Scope (Alternative): Assign "Reader" to specific subscriptions
// ---------------------------------------------------------------------------
module subscriptionReaderAssignments 'modules/subscription-role.bicep' = [for subId in subscriptionIds: if (scopeMode == 'subscription') {
  name: 'atomity-sub-reader-${subId}'
  scope: subscription(subId)
  params: {
    atomityServicePrincipalObjectId: atomityServicePrincipalObjectId
  }
}]

// ---------------------------------------------------------------------------
// 3. Storage Account Scope: Cross-scope module to assign "Storage Blob Data Reader"
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
output readerScope string = (scopeMode == 'management_group') ? managementGroup().id : 'Subscriptions'

@description('The storage account receiving the export.')
output storageAccount string = storageAccountName

@description('Confirmation of the storage account role assignment ID.')
output storageRoleAssignmentId string = storageAccountRoleAssignment.outputs.roleAssignmentId