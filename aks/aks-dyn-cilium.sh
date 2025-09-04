#!/bin/bash

#
# AKS cluster with Dynamic IP and Cilium
#
location=westeurope
#
# Choose random name for resources
#
name=aks-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
#
# Calculate next available network address space
#
number=$(az network vnet list --query "[].addressSpace.addressPrefixes" -o tsv | cut -d . -f 2 | sort | tail -n 1)
if [[ -z $number ]]
then
    number=0
fi
networkNumber=$(expr $number + 1)

virtualNetworkPrefix=10.${networkNumber}.0.0/16
aksNodeSubnetPrefix=10.${networkNumber}.0.0/24
aksPodSubnetPrefix=10.${networkNumber}.1.0/24

version=$(az aks get-versions -l $location | jq -r "(.values[].patchVersions) | keys | .[]" | sort | tail -n 1) 2>/dev/null

az group create -n $name -l $location

#
# Create Log Analytics workspace
#
az monitor log-analytics workspace create -g $name -n ${name}-logs
workspaceId=$(az monitor log-analytics workspace list --query "[?name=='${name}-logs'].id" -o tsv)

#
# Create managed identity for control plane
#
az identity create -n $name -g $name -o table
identityId=$(az identity show --name $name -g $name --query id -o tsv)

#
# AKS cluster with Azure CNI v2
# Creates VNet, node subnet, pod subnet, Managed Identity and cluster with three nodes
#
az network vnet create -g $name -n ${name}-vnet --address-prefixes $virtualNetworkPrefix
az network vnet subnet create -g $name --vnet-name ${name}-vnet --name ${name}-node-subnet --address-prefixes $aksNodeSubnetPrefix
az network vnet subnet create -g $name --vnet-name ${name}-vnet --name ${name}-pod-subnet --address-prefixes $aksPodSubnetPrefix
nodeSubnetId=$(az network vnet subnet list --vnet-name ${name}-vnet --resource-group $name --query "[?name=='${name}-node-subnet'].id" -o tsv)
podSubnetId=$(az network vnet subnet list --vnet-name ${name}-vnet --resource-group $name --query "[?name=='${name}-pod-subnet'].id" -o tsv)

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --network-dataplane cilium \
    --vnet-subnet-id $nodeSubnetId \
    --pod-subnet-id $podSubnetId \
    --dns-service-ip 10.240.0.10 \
    --service-cidr 10.240.0.0/24 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3


az aks get-credentials -n $name -g $name --overwrite-existing

#
# Delete cluster
#
# az group delete -n $name -y