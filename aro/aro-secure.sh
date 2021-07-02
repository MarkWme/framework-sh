#!/bin/bash

#
# ARO Secure Private Cluster
# Deploys ARO along with Azure Firewall and other security enhancements
#
# Get the pull secret from https://cloud.redhat.com/openshift/install/azure/aro-provisioned
#
# Set environment variables
#
LOCATION=westeurope
RESOURCEGROUP=arosecure
CLUSTER=arosecure
virtualNetworkPrefix=10.152.0.0/21
masterSubnetPrefix=10.152.0.0/23
workerSubnetPrefix=10.152.2.0/23
firewallSubnetPrefix=10.152.4.0/23
jumpboxSubnetPrefix=10.152.6.0/23

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
# Subnet for firewall
#
az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name AzureFirewallSubnet \
  --address-prefixes $firewallSubnetPrefix

#
# Subnet for Jump Box VM
#
az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name jumpbox-subnet \
  --address-prefixes $jumpboxSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Create a jumpbox VM
#
VMUSERNAME=aroadmin

az vm create --name ubuntu-jump \
  --resource-group $RESOURCEGROUP \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --admin-username $VMUSERNAME \
  --image UbuntuLTS \
  --subnet jumpbox-subnet \
  --public-ip-address jumphost-ip \
  --vnet-name aro-vnet

#
# Create the cluster
#
az aro create \
  --resource-group $RESOURCEGROUP \
  --name $CLUSTER \
  --vnet aro-vnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --apiserver-visibility Private \
  --ingress-visibility Private \
  --pull-secret @/mnt/c/Users/mtjw/Downloads/pull-secret.txt

#
# Create a public IP address for the firewall
#
az network public-ip create -g $RESOURCEGROUP -n fw-ip --sku "Standard" --location $LOCATION

#
# Add / update the Azure Firewall extension for the az cli
#
az extension add -n azure-firewall
az extension update -n azure-firewall

#
# You've only tested as far as this so far! :-)
#

#
# Create Azure Firewall
#
az network firewall create -g $RESOURCEGROUP -n arosecure -l $LOCATION
az network firewall ip-config create -g $RESOURCEGROUP -f arosecure -n fw-config --public-ip-address fw-ip --vnet-name aro-vnet

#
# Get Azure Firewall IP's
#
FWPUBLIC_IP=$(az network public-ip show -g $RESOURCEGROUP -n fw-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RESOURCEGROUP -n arosecure --query "ipConfigurations[0].privateIpAddress" -o tsv)

#
# Create route table and routes
#
az network route-table create -g $RESOURCEGROUP --name aro-udr

az network route-table route create -g $RESOURCEGROUP --name aro-udr --route-table-name aro-udr --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP

#
# OpenShift application rules
#
az network firewall application-rule create -g $RESOURCEGROUP -f arosecure \
  --collection-name 'ARO' \
  --action allow \
  --priority 100 \
  -n 'required' \
  --source-addresses '*' \
  --protocols 'http=80' 'https=443' \
  --target-fqdns 'registry.redhat.io' '*.quay.io' 'sso.redhat.com' 'management.azure.com' 'mirror.openshift.com' 'api.openshift.com' 'quay.io' '*.blob.core.windows.net' 'gcs.prod.monitoring.core.windows.net' 'registry.access.redhat.com' 'login.microsoftonline.com' '*.servicebus.windows.net' '*.table.core.windows.net' 'grafana.com'

#
# Rules to allow images from Docker hub
#
az network firewall application-rule create -g $RESOURCEGROUP -f arosecure \
  --collection-name 'Docker' \
  --action allow \
  --priority 200 \
  -n 'docker' \
  --source-addresses '*' \
  --protocols 'http=80' 'https=443' \
  --target-fqdns '*cloudflare.docker.com' '*registry-1.docker.io' 'apt.dockerproject.org' 'auth.docker.io'

#
# Associate ARO subnets to firewall
#
az network vnet subnet update -g $RESOURCEGROUP --vnet-name aro-vnet --name master-subnet --route-table aro-udr
az network vnet subnet update -g $RESOURCEGROUP --vnet-name aro-vnet --name worker-subnet --route-table aro-udr

#
# Continue adding steps from here:
# https://docs.microsoft.com/en-us/azure/openshift/howto-restrict-egress#configure-the-jumpbox
#