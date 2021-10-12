#!/bin/bash

#
# AKS cluster with Flux v2 support
#
location=westeurope
name=aks-flux
virtualNetworkPrefix=10.25.0.0/16
subnetPrefix=10.25.0.0/24
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location

#
# AKS cluster with Azure CNI
# Creates VNet, Managed Identity and cluster with three nodes
#
az network vnet create -n  ${name}-vnet -g $name --address-prefixes $virtualNetworkPrefix -l $location --subnet-name  ${name}-subnet  --subnet-prefixes $subnetPrefix
vnetId=$(az network vnet subnet list --vnet-name ${name}-vnet --resource-group $name --query "[?name=='${name}-subnet'].id" -o tsv)

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
# Setup Flux v2 preview features
#
az feature register --namespace Microsoft.ContainerService --name AKS-ExtensionManager
az feature register --namespace Microsoft.KubernetesConfiguration --name fluxConfigurations
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration

az extension add --source ./k8s_configuration-1.1.0b1-py3-none-any.whl --yes
az extension add --source ./k8s_extension_private-0.7.1b1-py3-none-any.whl --yes

az k8s-configuration flux create \
    -g $name -c $name -t managedClusters \
    -n gitops-demo --namespace gitops-demo --scope cluster \
    -u https://github.com/Azure/arc-k8s-demo --branch main --kustomization name=kustomization1 prune=true


#
# Delete cluster
#
az group delete -n $name -y