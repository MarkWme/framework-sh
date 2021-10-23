#!/bin/bash

#
# ARO Cluster
#
# Get the pull secret from https://cloud.redhat.com/openshift/install/azure/aro-provisioned
#
# Set environment variables
#
location=westeurope
#
# Choose random name for resources
#
name=aro-$(cat /dev/urandom | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
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
jumpboxSubnetPrefix=10.${networkNumber}.6.0/23
#
# Get cluster configuration details
#
read -p "Private cluster? (y/N) " privateCluster
if [[ $privateCluster =~ ^[Yy]$ ]]
then
  apiServerVisibility=Private
  ingressVisibility=Private
  name=${name}-priv
else
  apiServerVisibility=Public
  ingressVisibility=Public
  name=${name}-pub
fi
echo "Resource name prefix: ${name}"
echo "Virtual Network: ${virtualNetworkPrefix}"
echo "Master Nodes Subnet: ${masterSubnetPrefix}"
echo "Worker Nodes Subnet: ${workerSubnetPrefix}"
if [[ $privateCluster =~ ^[Yy]$ ]]
  echo "Jumpbox Subnet: ${jumpboxSubnetPrefix}"
fi
#
# Create resource group
#
az group create \
  --name $name \
  --location $location \
  -o table

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
   --address-prefixes $virtualNetworkPrefix \
   -o table

#
# Subnet for master nodes
#
az network vnet subnet create \
  --resource-group $name \
  --vnet-name ${name}-vnet \
  --name ${name}-master-subnet \
  --address-prefixes $masterSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry \
  -o table

#
# Disable subnet private endpoint policies on the master subnet
#
az network vnet subnet update \
  --name ${name}-master-subnet \
  --resource-group $name \
  --vnet-name ${name}-vnet \
  --disable-private-link-service-network-policies true \
  -o table

#
# Subnet for worker nodes
#
az network vnet subnet create \
  --resource-group $name \
  --vnet-name ${name}-vnet \
  --name ${name}-worker-subnet \
  --address-prefixes $workerSubnetPrefix \
  --service-endpoints Microsoft.ContainerRegistry \
  -o table

if [[ $privateCluster =~ ^[Yy]$ ]]
  #
  # Subnet for jumpbox
  #
  az network vnet subnet create \
    --resource-group $name \
    --vnet-name ${name}-vnet \
    --name ${name}-jumpbox-subnet \
    --address-prefixes $jumpboxSubnetPrefix \
    --service-endpoints Microsoft.ContainerRegistry \
    -o table

  #
  # Create a jumpbox VM
  #
  adminUserName=aroadmin

  az vm create --name ubuntu-jump \
    --resource-group $name \
    --ssh-key-values ~/.ssh/id_rsa.pub \
    --admin-username $adminUserName \
    --image UbuntuLTS \
    --subnet ${name}-jumpbox-subnet \
    --public-ip-address jumphost-ip \
    --public-ip-sku Standard \
    --vnet-name ${name}-vnet \
    -o table
  jumphostIp=$(az network public-ip show -g $name -n jumphost-ip | jq -r '.ipAddress')
fi



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
  --master-subnet ${name}-master-subnet \
  --worker-subnet ${name}-worker-subnet \
  --apiserver-visibility $apiServerVisibility \
  --ingress-visibility $ingressVisibility \
  --pull-secret @/mnt/c/Users/mtjw/Downloads/pull-secret.txt \
  -o table

#
# Get the cluster credentials
#
userName=$(az aro list-credentials --name $name --resource-group $name | jq -r ".kubeadminUsername")
password=$(az aro list-credentials --name $name --resource-group $name | jq -r ".kubeadminPassword")

#
# Get the cluster admin URL
#
clusterAdminUrl=$(az aro show --name $name --resource-group $name --query "consoleProfile.url" -o tsv)

echo "Cluster username: ${userName}"
echo "Cluster password: ${password}"
echo "Cluster admin URL: ${clusterAdminUrl}"

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
oc login $apiServer -u $userName -p $password

#
# Delete the cluster
#
read -p "Clean up deployment? (y/N or CTRL-C to stop) " cleanUp
if [[ $cleanUp =~ ^[Yy]$ ]]
then
  az aro delete --resource-group $name --name $name
  az group delete --name $name -y
  clientId=$(az ad sp list --display-name ${name}-spn --query '[].appId' -o tsv)
  az ad sp delete --id $clientId
fi

