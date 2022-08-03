#!/bin/bash

#
# Deploy ACI into private network with custom DNS
#
# Set environment variables
#
location=westeurope
acrName=pcreuwcore
#
# Choose random name for resources
#
name=aci-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
#
# Calculate next available network address space
#
number=0
number=$(az network vnet list --query "[].addressSpace.addressPrefixes" -o tsv | cut -d . -f 2 | sort | tail -n 1)
if [[ -z $number ]]
then
    number=0
fi
networkNumber=$(expr $number + 1)
virtualNetworkPrefix=10.${networkNumber}.0.0/16
aciSubnetPrefix=10.${networkNumber}.0.0/24
#
# Create resource group
#
az group create -n $name -l $location
#
# Creates Network and subnets for cluster and Application Gateway
#
az network vnet create -g $name -n ${name}-network --address-prefixes $virtualNetworkPrefix
az network vnet subnet create -g $name --vnet-name ${name}-network --name ${name}-aci-subnet --address-prefixes $aciSubnetPrefix

aciSubnetId=$(az network vnet subnet list --vnet-name ${name}-network --resource-group $name --query "[?name=='${name}-aci-subnet'].id" -o tsv)

#
# Get registry resource ID
#
ACR_REGISTRY_ID=$(az acr show --name $acrName --query id --output tsv)

#
# Create service principal for ACR access from ACI and store client ID and secret
#
SP_PASSWD=$(az ad sp create-for-rbac --name $name-spn --scopes $ACR_REGISTRY_ID --role acrpull --query password --output tsv)
SP_APP_ID=$(az ad sp list --display-name $name-spn --query '[].appId' -o tsv)

#
# Create container
#
# You might need to wait 30 seconds or so for the above SP permission to propagate before creating the ACI
#
az container create \
  --resource-group $name \
  --name $name \
  --image $acrName.azurecr.io/simpleapi:latest \
  --registry-login-server $acrName.azurecr.io \
  --registry-username $SP_APP_ID \
  --registry-password $SP_PASSWD \
  --subnet $aciSubnetId \
  --cpu 2 \
  --memory 8 \ß
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
az container delete -n $NAME -g $NAME -y
az group delete --name $NAME -y
az ad sp delete --id $SP_APP_ID
