#!/bin/bash

#
# AKS cluster with Availability Zones
#

location=westeurope
name=aksaz
virtualNetworkPrefix=10.202.0.0/16
subnetPrefix=10.202.0.0/24
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
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --node-count 3 \
    --zone 1 2 3

#
# AKS cluster with Azure CNI
# Creates VNet, Managed Identity and cluster with three nodes
#
az network vnet create -n aks-vnet -g $name --address-prefixes $virtualNetworkPrefix -l westeurope --subnet-name aks-subnet --subnet-prefixes $subnetPrefix
vnetId=$(az network vnet subnet list --vnet-name aks-vnet --resource-group $name --query "[0].id" -o tsv)
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
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3 \
    --zone 1 2 3


az aks get-credentials -n $name -g $name --overwrite-existing

#
# Scale cluster up and down
#
az aks scale -n $name -g $name --node-count=7

#
# Add nodepool
#
 az aks nodepool add \
    --resource-group $name \
    --cluster-name $name \
    --name np01 \
    --node-count 3


#
# Add nodepool with two taints
#
 az aks nodepool add \
    --resource-group akscluster \
    --cluster-name akscluster \
    --name np01 \
    --node-count 1 \
    --node-taints samplekey1=samplevalue1:NoSchedule,samplekey2=samplevalue2:NoSchedule

#
# Delete cluster
#
az group delete -n $name -y