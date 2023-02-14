#!/bin/bash

#
# ARO Secure Private Cluster
# Deploys ARO along with Azure Firewall and other security enhancements
# This script differs from the aro-secure.sh script as it creates the firewall and rules prior to the ARO deployment
#
# This script is an experiment to see if enabling firewall rules before cluster deployment works.
#
# Get the pull secret from https://cloud.redhat.com/openshift/install/azure/aro-provisioned
#
# Set environment variables
#
location=westeurope
#
# Choose random name for resources
#
name=aro-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
coreName=${name}-core
#
# Calculate next available network address space
#
number=0
number=$(az network vnet list --query "[].addressSpace.addressPrefixes" -o tsv | cut -d . -f 2 | sort | tail -n 1)
networkNumber=$(expr $number + 1)
#
# Set network and subnet prefixes
#
virtualNetworkPrefix=10.${networkNumber}.0.0/16
masterSubnetPrefix=10.${networkNumber}.0.0/23
workerSubnetPrefix=10.${networkNumber}.2.0/23
firewallSubnetPrefix=10.${networkNumber}.4.0/23
jumpboxSubnetPrefix=10.${networkNumber}.6.0/23
bastionSubnetPrefix=10.${networkNumber}.8.0/23

#
# Create resource groups
#
az group create \
  --name $name \
  --location $location

az group create \
  --name $coreName \
  --location $location

#
# Create virtual network
#
az network vnet create \
   --resource-group $coreName \
   --name ${name}-vnet \
   --address-prefixes $virtualNetworkPrefix

#
# Subnet for master nodes
#
az network vnet subnet create \
  --resource-group $coreName \
  --vnet-name ${name}-vnet \
  --name master-subnet \
  --address-prefixes $masterSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Subnet for worker nodes
#
az network vnet subnet create \
  --resource-group $coreName \
  --vnet-name ${name}-vnet \
  --name worker-subnet \
  --address-prefixes $workerSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Disable subnet private endpoint policies on the master subnet
#
az network vnet subnet update \
  --name master-subnet \
  --resource-group $coreName \
  --vnet-name ${name}-vnet \
  --disable-private-link-service-network-policies true

#
# Subnet for firewall
#
az network vnet subnet create \
  --resource-group $coreName \
  --vnet-name ${name}-vnet \
  --name AzureFirewallSubnet \
  --address-prefixes $firewallSubnetPrefix

#
# Subnet for Jump Box VM
#
az network vnet subnet create \
  --resource-group $coreName \
  --vnet-name ${name}-vnet \
  --name jumpbox-subnet \
  --address-prefixes $jumpboxSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

az network vnet subnet create \
  -g $coreName \
  --vnet-name ${name}-vnet \
  --name "AzureBastionSubnet" \
  --address-prefixes $bastionSubnetPrefix
#
# Create a jumpbox VM
#
VMUSERNAME=aroadmin

az vm create --name ubuntu-jump \
  --resource-group $coreName \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --admin-username $VMUSERNAME \
  --image UbuntuLTS \
  --subnet jumpbox-subnet \
  --public-ip-address jumphost-ip \
  --public-ip-sku Standard \
  --vnet-name ${name}-vnet

#
# Create an Azure Bastion
#
az network public-ip create --name ${name}-bastion-ip \
    --resource-group $coreName \
    --sku Standard

az network bastion create --name $name \
    --resource-group $coreName \
    --location $location \
    --public-ip-address ${name}-bastion-ip \
    --vnet-name ${name}-vnet \

#
# Create a public IP address for the firewall
#
az network public-ip create -g $coreName -n ${name}-firewall-ip --sku "Standard" --location $location

#
# Add / update the Azure Firewall extension for the az cli
#
az extension add --upgrade --yes -n azure-firewall

#
# Create Azure Firewall
#
az network firewall create -g $coreName -n $name -l $location
az network firewall ip-config create -g $coreName -f $name -n ${name}-fw-config --public-ip-address ${name}-firewall-ip --vnet-name ${name}-vnet

#
# Get Azure Firewall IP's
#
FWPUBLIC_IP=$(az network public-ip show -g $coreName -n ${name}-firewall-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $coreName -n ${name} --query "ipConfigurations[0].privateIpAddress" -o tsv)

#
# Create route table and routes
#
az network route-table create -g $coreName --name ${name}-udr

az network route-table route create -g $coreName --name ${name}-udr --route-table-name ${name}-udr --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP

#
# OpenShift application rules
#
az network firewall application-rule create -g $coreName -f $name \
  --collection-name 'ARO' \
  --action allow \
  --priority 100 \
  -n 'required' \
  --source-addresses '*' \
  --protocols 'http=80' 'https=443' \
  --target-fqdns 'registry.redhat.io' '*.quay.io' 'sso.redhat.com' 'mirror.openshift.com' 'api.openshift.com' 'quay.io' 'registry.access.redhat.com'

#
# Minimal egress rules, determined by experimentation!
#
az network firewall application-rule create -g $coreName -f $name \
  --collection-name 'ARO' \
  --action allow \
  --priority 100 \
  -n 'required' \
  --source-addresses '*' \
  --protocols 'http=80' 'https=443' \
  --target-fqdns 'api.openshift.com' 'quay.io' 'mirror.openshift.com'

#
# Rules to allow images from Docker hub
#
az network firewall application-rule create -g $name -f $name \
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
az network vnet subnet update -g $coreName --vnet-name ${name}-vnet --name master-subnet --route-table ${name}-udr
az network vnet subnet update -g $coreName --vnet-name ${name}-vnet --name worker-subnet --route-table ${name}-udr

virtualNetworkId=$(az network vnet show -g $coreName -n ${name}-vnet --query "id" -o tsv)
masterSubnetId=$(az network vnet subnet show -g $coreName --vnet-name ${name}-vnet --name master-subnet --query "id" -o tsv)
workerSubnetId=$(az network vnet subnet show -g $coreName --vnet-name ${name}-vnet --name worker-subnet --query "id" -o tsv)

#
# Create the cluster
#
az aro create \
  --resource-group $name \
  --name $name \
  --vnet $virtualNetworkId \
  --master-subnet $masterSubnetId \
  --worker-subnet $workerSubnetId \
  --apiserver-visibility Private \
  --ingress-visibility Private \
  --tags "apiServer=private" "ingress=private" "firewallEnabled=true" "outboundType=UserDefinedRouting" \
  --pull-secret @/Users/mark/Downloads/pull-secret.txt

#
# Get public IP address of jumphost
#
JUMPHOST_IP=$(az network public-ip show -g $coreName -n jumphost-ip | jq -r '.ipAddress')

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
NAME=arosecurefw
ARO_PASSWORD=$(az aro list-credentials -n $name -g $name -o json | jq -r '.kubeadminPassword')
ARO_USERNAME=$(az aro list-credentials -n $name -g $name -o json | jq -r '.kubeadminUsername')
ARO_URL=$(az aro show -n $name -g $name -o json | jq -r '.apiserverProfile.url')

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
CONSOLE_URL=$(az aro show -n $name -g $name --query "consoleProfile.url" -o tsv | sed -e 's/https\?:\/\///' | sed -e 's/\///')
sudo ssh -N -i /home/mark/.ssh/id_rsa -L 443:$CONSOLE_URL:443 aroadmin@$JUMPHOST_IP

#
# Breakdown of the above
#
# sudo - we need to map to port 443, so sudo is needed to map to a privileged port
# ssh - the ssh command
# -N - don't start an interactive session
# -i - path to the private key. As we're using sudo, we need to do this otherwise it will try to use root's private key
# /home/mark/.ssh/id_rsa - actual path of the private key
# 443 - the port we want to map to locally. Can't use something else, like 8443, because the OpenShift portal will redirect back to 443
# $CONSOLE_URL - should be the DNS name of the console with https:// and trailing slashes removed
# aroadmin@JUMPHOST_IP - username and IP address/name of remote host
