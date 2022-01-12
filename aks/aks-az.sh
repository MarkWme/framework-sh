#!/bin/bash

#
# AKS cluster with Availability Zones
#
location=westeurope
#
# Choose random name for resources
#
name=aks-$(cat /dev/urandom | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
#
# Calculate next available network address space
#
number=0
number=$(az network vnet list --query "[].addressSpace.addressPrefixes" -o tsv | cut -d . -f 2 | sort | tail -n 1)
networkNumber=$(expr $number + 1)
virtualNetworkPrefix=10.${networkNumber}.0.0/16
aksSubnetPrefix=10.${networkNumber}.0.0/24

version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

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
az network vnet subnet create -g $name --vnet-name ${name}-network --name ${name}-aks-subnet --address-prefixes $aksSubnetPrefix -o table

aksSubnetId=$(az network vnet subnet list --vnet-name ${name}-network --resource-group $name --query "[?name=='${name}-aks-subnet'].id" -o tsv)
#
# Create managed identity for control plane
#
az identity create -n $name -g $name -o table
identityId=$(az identity show --name $name -g $name --query id -o tsv)

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $aksSubnetId \
    --service-cidr 10.240.0.0/24 \
    --dns-service-ip 10.240.0.10 \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3 \
    --zone 1 2 3 \
    --tags "features=az"

az aks get-credentials -n $name -g $name --overwrite-existing

#
# View nodes with details of AZ each is deployed to
#
kubectl get nodes -o custom-columns=NAME:'{.metadata.name}',REGION:'{.metadata.labels.topology\.kubernetes\.io/region}',ZONE:'{metadata.labels.topology\.kubernetes\.io/zone}'

#
# Delete cluster
#
# az group delete -n $name -y