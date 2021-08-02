#!/bin/bash

#
# ARO Cluster
#
# Get the pull secret from https://cloud.redhat.com/openshift/install/azure/aro-provisioned
#
# Set environment variables
#
LOCATION=westeurope
RESOURCEGROUP=arocluster
CLUSTER=arocluster
virtualNetworkPrefix=10.150.0.0/22
masterSubnetPrefix=10.150.0.0/23
workerSubnetPrefix=10.150.2.0/23

#
# Create resource group
#
az group create \
  --name $RESOURCEGROUP \
  --location $LOCATION

#
# Create virtual network
#
az network vnet create \
   --resource-group $RESOURCEGROUP \
   --name aro-vnet \
   --address-prefixes $virtualNetworkPrefix

#
# Subnet for master nodes
#
az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name master-subnet \
  --address-prefixes $masterSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Subnet for worker nodes
#
az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name worker-subnet \
  --address-prefixes $workerSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Disable subnet private endpoint policies on the master subnet
#
az network vnet subnet update \
  --name master-subnet \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --disable-private-link-service-network-policies true

#
# Create the cluster
#
az aro create \
  --resource-group $RESOURCEGROUP \
  --name $CLUSTER \
  --vnet aro-vnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --pull-secret @/mnt/c/Users/mtjw/Downloads/pull-secret.txt

#
# Get the cluster credentials
#
az aro list-credentials \
  --name $CLUSTER \
  --resource-group $RESOURCEGROUP

#
# Get the cluster admin URL
#
az aro show \
    --name $CLUSTER \
    --resource-group $RESOURCEGROUP \
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
apiServer=$(az aro show -g $RESOURCEGROUP -n $CLUSTER --query apiserverProfile.url -o tsv)
userName=$(az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP | jq -r ".kubeadminUsername")
password=$(az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP | jq -r ".kubeadminPassword")
oc login $apiServer -u $userName -p $password

#
# Delete the cluster
#
#az aro delete --resource-group $RESOURCEGROUP --name $CLUSTER

