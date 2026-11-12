targetScope = 'subscription'

metadata description = 'Atomity read-only connection for Azure, per subscription: Reader on each listed subscription and Storage Blob Data Reader on the billing export storage account. It creates role assignments only. It does not create the Service Principal or the Cost Management export. It needs no management group rights. Deploy it with az deployment sub create, from any one of the subscriptions. To grant Reader on a whole management group instead, use main.bicep.'

@description('Object ID of Atomity\'s Service Principal in your tenant. Get it with: az ad sp show --id c4b84012-e86e-4ea0-9c42-5e015c1c30f4 --query id -o tsv')
@minLength(36)
@maxLength(36)
param atomityServicePrincipalObjectId string

@description('Subscription IDs to grant Reader on. The deployment can run from any one of them. Subscriptions you add later are not covered until you deploy again with them listed.')
@minLength(1)
param subscriptionIds array

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

// ---------------------------------------------------------------------------
// 1. Each listed subscription: assign "Reader" to Atomity's Service Principal.
//    union() drops duplicates, which would otherwise collide on the deployment name.
// ---------------------------------------------------------------------------
module subscriptionReaderAssignments 'modules/subscription-role.bicep' = [for subId in union(subscriptionIds, []): {
  name: 'atomity-sub-reader-${subId}'
  scope: subscription(subId)
  params: {
    atomityServicePrincipalObjectId: atomityServicePrincipalObjectId
  }
}]

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
@description('The subscriptions where the Reader role was assigned.')
output readerSubscriptions array = union(subscriptionIds, [])

@description('The storage account receiving the export.')
output storageAccount string = storageAccountName

@description('Confirmation of the storage account role assignment ID.')
output storageRoleAssignmentId string = storageAccountRoleAssignment.outputs.roleAssignmentId
