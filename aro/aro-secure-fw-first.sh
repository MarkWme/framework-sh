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
LOCATION=westeurope
NAME=arosecurefw
virtualNetworkPrefix=10.153.0.0/21
masterSubnetPrefix=10.153.0.0/23
workerSubnetPrefix=10.153.2.0/23
firewallSubnetPrefix=10.153.4.0/23
jumpboxSubnetPrefix=10.153.6.0/23

#
# Create resource group
#
az group create \
  --name $NAME \
  --location $LOCATION

#
# Create virtual network
#
az network vnet create \
   --resource-group $NAME \
   --name ${NAME}-vnet \
   --address-prefixes $virtualNetworkPrefix

#
# Subnet for master nodes
#
az network vnet subnet create \
  --resource-group $NAME \
  --vnet-name ${NAME}-vnet \
  --name master-subnet \
  --address-prefixes $masterSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Subnet for worker nodes
#
az network vnet subnet create \
  --resource-group $NAME \
  --vnet-name ${NAME}-vnet \
  --name worker-subnet \
  --address-prefixes $workerSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Disable subnet private endpoint policies on the master subnet
#
az network vnet subnet update \
  --name master-subnet \
  --resource-group $NAME \
  --vnet-name ${NAME}-vnet \
  --disable-private-link-service-network-policies true

#
# Subnet for firewall
#
az network vnet subnet create \
  --resource-group $NAME \
  --vnet-name ${NAME}-vnet \
  --name AzureFirewallSubnet \
  --address-prefixes $firewallSubnetPrefix

#
# Subnet for Jump Box VM
#
az network vnet subnet create \
  --resource-group $NAME \
  --vnet-name ${NAME}-vnet \
  --name jumpbox-subnet \
  --address-prefixes $jumpboxSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry

#
# Create a jumpbox VM
#
VMUSERNAME=aroadmin

az vm create --name ubuntu-jump \
  --resource-group $NAME \
  --ssh-key-values ~/.ssh/id_rsa.pub \
  --admin-username $VMUSERNAME \
  --image UbuntuLTS \
  --subnet jumpbox-subnet \
  --public-ip-address jumphost-ip \
  --public-ip-sku Standard \
  --vnet-name ${NAME}-vnet

#
# Create a public IP address for the firewall
#
az network public-ip create -g $NAME -n ${NAME}-ip --sku "Standard" --location $LOCATION

#
# Add / update the Azure Firewall extension for the az cli
#
az extension add --upgrade --yes -n azure-firewall

#
# Create Azure Firewall
#
az network firewall create -g $NAME -n $NAME -l $LOCATION
az network firewall ip-config create -g $NAME -f $NAME -n ${NAME}-fw-config --public-ip-address ${NAME}-ip --vnet-name ${NAME}-vnet

#
# Get Azure Firewall IP's
#
FWPUBLIC_IP=$(az network public-ip show -g $NAME -n ${NAME}-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $NAME -n ${NAME} --query "ipConfigurations[0].privateIpAddress" -o tsv)

#
# Create route table and routes
#
az network route-table create -g $NAME --name ${NAME}-udr

az network route-table route create -g $NAME --name ${NAME}-udr --route-table-name ${NAME}-udr --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP

#
# OpenShift application rules
#
az network firewall application-rule create -g $NAME -f $NAME \
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
az network firewall application-rule create -g $NAME -f $NAME \
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
az network vnet subnet update -g $NAME --vnet-name ${NAME}-vnet --name master-subnet --route-table ${NAME}-udr
az network vnet subnet update -g $NAME --vnet-name ${NAME}-vnet --name worker-subnet --route-table ${NAME}-udr

#
# Create the cluster
#
az aro create \
  --resource-group $NAME \
  --name $NAME \
  --vnet ${NAME}-vnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --apiserver-visibility Private \
  --ingress-visibility Private \
  --pull-secret @/mnt/c/Users/mtjw/Downloads/pull-secret.txt

#
# Get public IP address of jumphost
#
JUMPHOST_IP=$(az network public-ip show -g $NAME -n jumphost-ip | jq -r '.ipAddress')

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
ARO_PASSWORD=$(az aro list-credentials -n $NAME -g $NAME -o json | jq -r '.kubeadminPassword')
ARO_USERNAME=$(az aro list-credentials -n $NAME -g $NAME -o json | jq -r '.kubeadminUsername')
ARO_URL=$(az aro show -n $NAME -g $NAME -o json | jq -r '.apiserverProfile.url')

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
CONSOLE_URL=$(az aro show -n $NAME -g $NAME --query "consoleProfile.url" -o tsv | sed -e 's/https\?:\/\///' | sed -e 's/\///')
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
