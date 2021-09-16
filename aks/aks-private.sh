#!/bin/bash

#
# Private AKS cluster
#
location=westeurope
name=aksprivate
virtualNetworkPrefix=10.220.0.0/16
subnetPrefix=10.220.0.0/24
jumpboxSubnetPrefix=10.220.100.0/24
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location

#
# AKS cluster with Azure CNI
# Creates VNet, Managed Identity and cluster with three nodes
#
az network vnet create -n ${name}-vnet -g $name --address-prefixes $virtualNetworkPrefix -l $location --subnet-name nodepool-subnet --subnet-prefixes $subnetPrefix

az network vnet subnet create -g $name --vnet-name ${name}-vnet --name jumpbox-subnet --address-prefixes $jumpboxSubnetPrefix

vnetId=$(az network vnet subnet list --vnet-name ${name}-vnet --resource-group $name --query "[0].id" -o tsv)

az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)

#
# Create a jumpbox VM
#
VMUSERNAME=aksadmin

az vm create --name ubuntu-jump \
  --resource-group $name \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --admin-username $VMUSERNAME \
  --image UbuntuLTS \
  --subnet jumpbox-subnet \
  --public-ip-address jumphost-ip \
  --public-ip-sku Standard \
  --vnet-name ${name}-vnet


az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --enable-private-cluster \
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
# Delete cluster
#
az group delete -n $name -y