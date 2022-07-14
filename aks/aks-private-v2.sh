#!/bin/bash

#
# AKS cluster with API server VNet integration
#
# During preview, this is only available in eastus2, northcentralus, westcentralus and westus2
#
location=eastus2
#
# Choose random name for resources
#
name=aks-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
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
apiSubnetPrefix=10.${networkNumber}.0.0/24
nodeSubnetPrefix=10.${networkNumber}.1.0/24
bastionSubnetPrefix=10.${networkNumber}.2.0/24
#
# Get current latest (preview) version of Kubernetes
#
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null
#
# Create resource group
#
az group create -n $name -l $location
#
# Create Log Analytics workspace
#
az monitor log-analytics workspace create -g $name -n ${name}-logs
workspaceId=$(az monitor log-analytics workspace list --query "[?name=='${name}-logs'].id" -o tsv)
#
# Creates Network and subnets for cluster and Application Gateway
#
az network vnet create -g $name -n ${name}-network --address-prefixes $virtualNetworkPrefix
az network vnet subnet create -g $name --vnet-name ${name}-network --name ${name}-api-subnet --address-prefixes $apiSubnetPrefix
az network vnet subnet create -g $name --vnet-name ${name}-network --name ${name}-node-subnet --address-prefixes $nodeSubnetPrefix
az network vnet subnet create -g $name --vnet-name ${name}-network --name "AzureBastionSubnet" --address-prefixes $bastionSubnetPrefix

apiSubnetId=$(az network vnet subnet list --vnet-name ${name}-network --resource-group $name --query "[?name=='${name}-api-subnet'].id" -o tsv)
nodeSubnetId=$(az network vnet subnet list --vnet-name ${name}-network --resource-group $name --query "[?name=='${name}-node-subnet'].id" -o tsv)

#
# Create managed identity for control plane
#
az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)
identityClientId=$(az identity show --name $name -g $name --query clientId -o tsv)


#
# Assign roles to the identity for subnet injection
#
# Assign Network Contributor to the API server subnet
az role assignment create --scope $apiSubnetId \
    --role "Network Contributor" \
    --assignee $identityClientId

# Assign Network Contributor to the cluster subnet
az role assignment create --scope $nodeSubnetId \
    --role "Network Contributor" \
    --assignee $identityClientId
#
# Create AKS cluster
#
az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $nodeSubnetId \
    --apiserver-subnet-id $apiSubnetId \
    --enable-private-cluster \
    --enable-apiserver-vnet-integration \
    --dns-service-ip 10.240.0.10 \
    --service-cidr 10.240.0.0/24 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3 \
    --attach-acr pcreuwcore \
    --enable-addons monitoring \
    --workspace-resource-id $workspaceId

az aks get-credentials -n $name -g $name --overwrite-existing

az network public-ip create --name $name \
    --resource-group $name \
    --sku Standard

az network bastion create --name $name \
    --resource-group $name \
    --location $location \
    --public-ip-address $name \
    --vnet-name ${name}-network \

#
# Add nodepool with two taints
#
# az aks nodepool add \
#    --resource-group $name \
#    --cluster-name $name \
#    --name np01 \
#    --node-count 3 \
#    --node-taints samplekey1=samplevalue1:NoSchedule,samplekey2=samplevalue2:NoSchedule

#
# Add nodepool with modified max pods value
#
#az aks nodepool add \
#  --resource-group $name \
#  --cluster-name $name \
#  --name np01 \
#  --node-count 3 \
#  --max-pods 20
#
# Delete cluster
#
# az group delete -n $name -y
