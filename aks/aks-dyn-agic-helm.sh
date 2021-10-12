#!/bin/bash

#
# AKS cluster with dynamic IP
#
location=westeurope
name=aksappgw
virtualNetworkName=akscluster-vnet
virtualNetworkPrefix=10.178.0.0/16
nodeSubnetName=akscluster-node-subnet
nodeSubnetPrefix=10.178.0.0/24
podSubnetName=akscluster-pod-subnet
podSubnetPrefix=10.178.1.0/24
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location

#
# AKS cluster with Azure CNI v2
# Creates VNet, node subnet, pod subnet, Managed Identity and cluster with three nodes
#
az network vnet create -g $name -n $virtualNetworkName --address-prefixes $virtualNetworkPrefix
az network vnet subnet create -g $name --vnet-name $virtualNetworkName --name $nodeSubnetName --address-prefixes $nodeSubnetPrefix
az network vnet subnet create -g $name --vnet-name $virtualNetworkName --name $podSubnetName --address-prefixes $podSubnetPrefix
nodeSubnetId=$(az network vnet subnet list --vnet-name $virtualNetworkName --resource-group $name --query "[?name=='$nodeSubnetName'].id" -o tsv)
podSubnetId=$(az network vnet subnet list --vnet-name $virtualNetworkName --resource-group $name --query "[?name=='$podSubnetName'].id" -o tsv)

az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $nodeSubnetId \
    --pod-subnet-id $podSubnetId \
    --docker-bridge-address 172.17.0.1/16 \
    --dns-service-ip 10.240.0.10 \
    --service-cidr 10.240.0.0/24 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-count 3



az aks get-credentials -n $name -g $name --overwrite-existing

#
# Add nodepool on different subnet
#
nodepoolSubnetName=akscluster-pod-subnet-2
nodepoolSubnetPrefix=10.215.5.0/24

az network vnet subnet create -g $name --vnet-name $virtualNetworkName --name $nodepoolSubnetName --address-prefixes $nodepoolSubnetPrefix

nodepoolSubnetId=$(az network vnet subnet list --vnet-name $virtualNetworkName --resource-group $name --query "[?name=='$nodepoolSubnetName'].id" -o tsv)

az aks nodepool add \
    --resource-group $name \
    --cluster-name $name \
    --name np01 \
    --node-count 3 \
    --pod-subnet-id $nodepoolSubnetId

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