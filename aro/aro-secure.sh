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
  --public-ip-sku Standard \
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
az extension add --upgrade --yes -n azure-firewall

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
# Get public IP address of jumphost
#
JUMPHOST_IP=$(az network public-ip show -g arosecure -n jumphost-ip | jq -r '.ipAddress')

#
# Jumphost configuration
# Update packages, install Azure CLI and jq
#
ssh aroadmin@$JUMPHOST_IP
sudo apt update && sudo apt upgrade -y
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo apt install jq -y
#
# Connect to ARO
#
az login
CLUSTER=arosecure
RESOURCEGROUP=arosecure
ARO_PASSWORD=$(az aro list-credentials -n $CLUSTER -g $RESOURCEGROUP -o json | jq -r '.kubeadminPassword')
ARO_USERNAME=$(az aro list-credentials -n $CLUSTER -g $RESOURCEGROUP -o json | jq -r '.kubeadminUsername')
ARO_URL=$(az aro show -n $CLUSTER -g $RESOURCEGROUP -o json | jq -r '.apiserverProfile.url')

#
# Install oc cli
#
cd ~
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
mkdir openshift
tar -zxvf openshift-client-linux.tar.gz -C openshift
echo 'export PATH=$PATH:~/openshift' >> ~/.bashrc && source ~/.bashrc

#
# Login with oc
#
oc login $ARO_URL -u $ARO_USERNAME -p $ARO_PASSWORD

#
# Test connectivity to the outside world
# The final command should be denied by the firewall
#
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: centos
spec:
  containers:
  - name: centos
    image: centos
    ports:
    - containerPort: 80
    command:
    - sleep
    - "3600"
EOF

oc exec -it centos -- /bin/bash

curl microsoft.com

#
# Access the web console
# 
# From your laptop, not the jumpbox!
#
# Although I couldn't get this to work. One problem was that running ssh with sudo
# seems to fail if the id_rsa.pub public key file exists in the .ssh folder. Fix was
# to simply move the file out of that folder. 
#
# After that though, attempting to establish a tunnel using either the below or sshuttle
# always resulted in the ssh connection being immediately dropped by the host after
# authentication. In the end, it was quicker to deploy a Windows VM and access the
# web console from there!
#
CONSOLE_URL=$(az aro show -n $CLUSTER -g $RESOURCEGROUP --query "consoleProfile.url" -o tsv)
sudo ssh -L 443:$CONSOLE_URL:443 aroadmin@$JUMPHOST_IP
#
# Note - CONSOLE_URL needs to have the "https" stripped!
#


#
# Example
# sudo ssh -i /Users/jimzim/.ssh/id_rsa -L 443:console-openshift-console.apps.d5xm5iut.eastus.aroapp.io:443 aroadmin@104.211.18.56
#

https://console-openshift-console.apps.fnew20kz.westeurope.aroapp.io/