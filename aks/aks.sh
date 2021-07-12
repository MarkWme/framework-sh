#!/bin/bash

#
# Basic AKS cluster
#
location=westeurope
name=akscluster
virtualNetworkName=akscluster-vnet
virtualNetworkPrefix=10.201.0.0/16
subnetName=akscluster-subnet
subnetPrefix=10.201.0.0/24
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location

#
# AKS cluster with kubenet, three nodes
#
az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin kubenet \
    --node-count 3

#
# AKS cluster with Azure CNI
# Creates VNet, Managed Identity and cluster with three nodes
#
az network vnet create -n $virtualNetworkName -g $name --address-prefixes $virtualNetworkPrefix -l $location --subnet-name $subnetName --subnet-prefixes $subnetPrefix
vnetId=$(az network vnet subnet list --vnet-name $virtualNetworkName --resource-group $name --query "[0].id" -o tsv)

az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $vnetId \
    --docker-bridge-address 172.17.0.1/16 \
    --dns-service-ip 10.240.0.10 \
    --service-cidr 10.240.0.0/24 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3


az aks get-credentials -n $name -g $name --overwrite-existing

#
# Add nodepool with two taints
#
 az aks nodepool add \
    --resource-group $name \
    --cluster-name $name \
    --name np01 \
    --node-count 3 \
    --node-taints samplekey1=samplevalue1:NoSchedule,samplekey2=samplevalue2:NoSchedule

#
# Add nodepool with modified max pods value
#
az aks nodepool add \
  --resource-group $name \
  --cluster-name $name \
  --name np01 \
  --node-count 3 \
  --max-pods 20
#
# Delete cluster
#
az group delete -n $name -y