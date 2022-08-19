#!/bin/bash

#
# Private AKS cluster
#
location=westeurope
name=aks-prv-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)

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
jumpboxSubnetPrefix=10.${networkNumber}.100.0/24

version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location -o table

#
# AKS cluster with Azure CNI
# Creates VNet, Managed Identity and cluster with three nodes
#
az network vnet create -n ${name}-vnet -g $name --address-prefixes $virtualNetworkPrefix -o table
az network vnet subnet create -g $name --vnet-name ${name}-vnet --name ${name}-aks-subnet --address-prefixes $aksSubnetPrefix -o table
az network vnet subnet create -g $name --vnet-name ${name}-vnet --name ${name}-jumpbox-subnet --address-prefixes $jumpboxSubnetPrefix -o table

aksSubnetId=$(az network vnet subnet list --vnet-name ${name}-vnet --resource-group $name --query "[?name=='${name}-aks-subnet'].id" -o tsv)


az identity create -n $name -g $name -o table
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
  --subnet ${name}-jumpbox-subnet \
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
    --vnet-subnet-id $aksSubnetId \
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