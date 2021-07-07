#!/bin/bash

#
# Deploy Simple API application in an ACI container
#
#
# Set environment variables
#
LOCATION=westeurope
NAME=acisimpleapi
ACR_NAME=pcreuwcore

#
# Create resource group
#
az group create --name $NAME --location $LOCATION

#
# Get registry resource ID
#
ACR_REGISTRY_ID=$(az acr show --name $ACR_NAME --query id --output tsv)

#
# Create service principal for ACR access from ACI and store client ID and secret
#
SP_PASSWD=$(az ad sp create-for-rbac --name $NAME --scopes $ACR_REGISTRY_ID --role acrpull --query password --output tsv)
SP_APP_ID=$(az ad sp list --display-name $NAME --query '[].appId' -o tsv)

#
# Create container
#
az container create \
  --resource-group $NAME \
  --name $NAME \
  --image $ACR_NAME.azurecr.io/simpleapi:latest \
  --registry-login-server $ACR_NAME.azurecr.io \
  --registry-username $SP_APP_ID \
  --registry-password $SP_PASSWD \
  --dns-name-label $NAME \
  --cpu 2 \
  --memory 8 \
  --ports 3000

#
# Get container URL
#
ACI_URL=$(az container show -n $NAME -g $NAME --query ipAddress.fqdn -o tsv)

#
# Test container connection
#
curl $ACI_URL:3000/api/getVersion

#
# Clean up
#
az group delete --name $NAME -y
az ad sp delete --id $SP_APP_ID
