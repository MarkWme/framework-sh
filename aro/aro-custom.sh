#!/bin/bash

#
# ARO Cluster with custom service principal and resource group
#
# Get the pull secret from https://cloud.redhat.com/openshift/install/azure/aro-provisioned
#
# Set environment variables
#
location=westeurope
name=arocluster
virtualNetworkPrefix=10.150.0.0/22
masterSubnetPrefix=10.150.0.0/23
workerSubnetPrefix=10.150.2.0/23

#
# Create resource group
#
az group create \
  --name $name \
  --location $location

#
# Create service principal
#
clientSecret=$(az ad sp create-for-rbac --name ${name}-spn --skip-assignment --query password --output tsv)
clientId=$(az ad sp list --display-name ${name}-spn --query '[].appId' -o tsv)

#
# Create virtual network
#
az network vnet create \
   --resource-group $name \
   --name ${name}-vnet \
   --address-prefixes $virtualNetworkPrefix

#
# Subnet for master nodes
#
az network vnet subnet create \
  --resource-group $name \
  --vnet-name ${name}-vnet \
  --name master-subnet \
  --address-prefixes $masterSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Subnet for worker nodes
#
az network vnet subnet create \
  --resource-group $name \
  --vnet-name ${name}-vnet \
  --name worker-subnet \
  --address-prefixes $workerSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Disable subnet private endpoint policies on the master subnet
#
az network vnet subnet update \
  --name master-subnet \
  --resource-group $name \
  --vnet-name ${name}-vnet \
  --disable-private-link-service-network-policies true

#
# Create the cluster
#
az aro create \
  --resource-group $name \
  --cluster-resource-group ${name}-resources \
  --client-id $clientId \
  --client-secret $clientSecret \
  --name $name \
  --vnet ${name}-vnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --pull-secret @/mnt/c/Users/mtjw/Downloads/pull-secret.txt

#
# Get the cluster credentials
#
az aro list-credentials \
  --name $name \
  --resource-group $name

#
# Get the cluster admin URL
#
az aro show \
    --name $name \
    --resource-group $name \
    --query "consoleProfile.url" -o tsv

#
# Download OpenShift command line tool
#
cd ~
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
sudo tar -zxvf openshift-client-linux.tar.gz -C /usr/local/bin

#
# Login with oc
#
apiServer=$(az aro show -g $name -n $name --query apiserverProfile.url -o tsv)
userName=$(az aro list-credentials --name $name --resource-group $name | jq -r ".kubeadminUsername")
password=$(az aro list-credentials --name $name --resource-group $name | jq -r ".kubeadminPassword")
oc login $apiServer -u $userName -p $password

#
# Delete the cluster
#
az aro delete --resource-group $name --name $name
az group delete --name $name -y
az ad sp delete --id $clientId
