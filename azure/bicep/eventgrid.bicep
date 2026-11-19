targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param storageAccountName string

@minLength(3)
param containerName string

@minLength(1)
@description('Root directory without leading or trailing slashes.')
param rootFolderPath string = 'atomity-exports'

@minLength(3)
@maxLength(64)
param eventSubscriptionName string = 'atomity-cost-blob-created'

@description('HTTPS endpoint returned by Atomity binding registration.')
param webhookEndpoint string

@secure()
@minLength(43)
@maxLength(43)
param webhookSecret string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource subscription 'Microsoft.EventGrid/eventSubscriptions@2022-06-15' = {
  name: eventSubscriptionName
  scope: storage

  properties: {
    eventDeliverySchema: 'EventGridSchema'

    destination: {
      endpointType: 'WebHook'

      properties: {
        endpointUrl: webhookEndpoint

        deliveryAttributeMappings: [
          {
            name: 'X-Atomity-Webhook-Token'
            type: 'Static'

            properties: {
              value: webhookSecret
              isSecret: true
            }
          }
        ]
      }
    }

    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]

      subjectBeginsWith: '/blobServices/default/containers/${containerName}/blobs/${rootFolderPath}/'
      isSubjectCaseSensitive: true
    }

    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output eventSubscriptionId string = subscription.id