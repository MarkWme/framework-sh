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
name=aro-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
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
read -p "Private API server? (y/N) " privateAPI
if [[ $privateAPI =~ ^[Yy]$ ]]
then
  apiServerVisibility=Private
else
  apiServerVisibility=Public
fi

read -p "Private Ingress? (y/N) " privateIngress
if [[ $privateIngress =~ ^[Yy]$ ]]
then
  ingressVisibility=Private
else
  ingressVisibility=Public
fi

echo "Resource name prefix: ${name}"
echo "Virtual Network: ${virtualNetworkPrefix}"
echo "Master Nodes Subnet: ${masterSubnetPrefix}"
echo "Worker Nodes Subnet: ${workerSubnetPrefix}"

if [[ $privateAPI =~ ^[Yy]$ ]]
then
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

echo "Client ID: ${clientId}"
echo "Client Secret: ${clientSecret}"

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

if [[ $privateAPI =~ ^[Yy]$ ]]
then
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
  adminPassword=$(cat /dev/urandom | base64 | tr -dc '[:alnum:]!$%&()[]{}:;.' | fold -w ${1:-20} | head -n 1)

  az vm create --name jumpbox-ubuntu \
    --resource-group $name \
    --ssh-key-values ~/.ssh/id_rsa.pub \
    --admin-username $adminUserName \
    --image UbuntuLTS \
    --subnet ${name}-jumpbox-subnet \
    --public-ip-address jumpbox-ubuntu-ip \
    --public-ip-sku Standard \
    --vnet-name ${name}-vnet \
    -o table

  az vm create --name jumpbox-win \
    --resource-group $name \
    --admin-username $adminUserName \
    --admin-password "${adminPassword}" \
    --image MicrosoftWindowsDesktop:windows-11:win11-21h2-pro:22000.258.2110071642 \
    --size Standard_D4s_v4 \
    --subnet ${name}-jumpbox-subnet \
    --public-ip-address jumpbox-win-ip \
    --public-ip-sku Standard \
    --vnet-name ${name}-vnet \
    -o table

echo "Jumphost admin name: ${adminUserName}"
echo "Windows jumphost password: ${adminPassword}"

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
  --pull-secret @/Users/mark/Downloads/pull-secret.txt \
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
# wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
# wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-mac-arm64.tar.gz
# sudo tar -zxvf openshift-client-linux.tar.gz -C /usr/local/bin

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

