#!/bin/bash

#
# ARO Cluster with custom service principal, resource group and Azure Container Registry
#
# Get the pull secret from https://cloud.redhat.com/openshift/install/azure/aro-provisioned
#
# Set environment variables
#
location=westeurope
name=aro-$(cat /dev/urandom | base64 | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)

number=0
number=$(az network vnet list --query "[].addressSpace.addressPrefixes" -o tsv | cut -d . -f 2 | sort | tail -n 1)
networkNumber=$(expr $number + 1)
#
# Set network and subnet prefixes
#
virtualNetworkPrefix=10.${networkNumber}.0.0/16
masterSubnetPrefix=10.${networkNumber}.0.0/23
workerSubnetPrefix=10.${networkNumber}.2.0/23

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
  --pull-secret @/Users/mark/Downloads/pull-secret.txt

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
# Create ACR instance
#
acrName=$(echo $name | sed 's/-//')
az acr create \
    --name $acrName \
    --resource-group $name \
    --sku standard \
    --admin-enabled true

#
# Get ACR credentials
#
acrUsername=$(az acr credential show -n $acrName | jq -r ".username")
acrPassword=$(az acr credential show -n $acrName | jq -r ".passwords[0].value")

#
# Create Kubernetes secret
# Secret will be created in the current Project (Namespace)
# and therefore only works with pods running in that Project
#
oc create secret docker-registry \
    --docker-server=${acrName}.azurecr.io \
    --docker-username=$acrUsername \
    --docker-password=$acrPassword \
    --docker-email=unused \
    acr-secret

#
# Enable monitoring with Azure Arc for Kubernetes
#
# Onboard cluster to Azure Arc
#
oc adm policy add-scc-to-user privileged system:serviceaccount:azure-arc:azure-arc-kube-aad-proxy-sa
az connectedk8s connect --name $name --resource-group $name
# Create Log Analytics workspace
#
az monitor log-analytics workspace create -g $name -n ${name}-logs
workspaceId=$(az monitor log-analytics workspace list --query "[?name=='${name}-logs'].id" -o tsv)

az k8s-extension create --name azuremonitor-containers \
  --cluster-name $name \
  --resource-group $name \
  --cluster-type connectedClusters \
  --extension-type Microsoft.AzureMonitor.Containers \
  --configuration-settings logAnalyticsWorkspaceResourceID=$workspaceId

#
# Delete the cluster
#
az aro delete --resource-group $name --name $name
az group delete --name $name -y
az ad sp delete --id $clientId
