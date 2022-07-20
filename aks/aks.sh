#!/bin/bash

#
# AKS cluster
#
location=westeurope
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
aksSubnetPrefix=10.${networkNumber}.0.0/24
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
az network vnet subnet create -g $name --vnet-name ${name}-network --name ${name}-aks-subnet --address-prefixes $aksSubnetPrefix

aksSubnetId=$(az network vnet subnet list --vnet-name ${name}-network --resource-group $name --query "[?name=='${name}-aks-subnet'].id" -o tsv)

#
# Create managed identity for control plane
#
az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)

#
# Create ACR instance
#
az acr create \
    --name $name \
    --resource-group $name \
    --sku standard
#
# Create AKS cluster
#
az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $aksSubnetId \
    --dns-service-ip 10.240.0.10 \
    --service-cidr 10.240.0.0/24 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3 \
    --attach-acr pcreuwcore \
    --enable-addons monitoring \
    --workspace-resource-id $workspaceId

az aks get-credentials -n $name -g $name --overwrite-existing

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
