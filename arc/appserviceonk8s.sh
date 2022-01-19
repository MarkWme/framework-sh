#!/bin/bash

#
# Not working fully
# 1. Deploying app service seems to fail because a storageClass named "default" does not exist. Tried creating one for azure-file, but didn't seem to fix it. Adding "default" then led to errors creating secrets. So, need to understand how to set up PV/PVC's in capz clusters.
# 2. Possible issues with IP address. Might need to create a separate one and use that for the "staticIP" value
#

#
# Deploy Azure App Service on Kubernetes to a
# "on-premises" cluster
#
export SP_NAME=clusterapi_capz_sp
export LOCATION=westeurope
export NAME=azappsrvk8s
extensionName="appservice-ext"
namespace="appservice-ns"
kubeEnvironmentName="azappsrvk8s"
#
# Get subscription ID and tenant ID
#
export AZURE_SUBSCRIPTION_ID=$(az account show -s "Microsoft Azure" | jq -r .id)
export AZURE_TENANT_ID=$(az account show -s "Microsoft Azure" | jq -r .tenantId)

#
# Create a service principal and store the client ID and client secret
#
export AZURE_CLIENT_SECRET=$(az ad sp create-for-rbac --name $SP_NAME --query password --output tsv)
export AZURE_CLIENT_ID=$(az ad sp list --display-name $SP_NAME --query '[].appId' -o tsv)

#
# Base64 encode the variables
#
export AZURE_SUBSCRIPTION_ID_B64="$(echo -n "$AZURE_SUBSCRIPTION_ID" | base64 | tr -d '\n')"
export AZURE_TENANT_ID_B64="$(echo -n "$AZURE_TENANT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_ID_B64="$(echo -n "$AZURE_CLIENT_ID" | base64 | tr -d '\n')"
export AZURE_CLIENT_SECRET_B64="$(echo -n "$AZURE_CLIENT_SECRET" | base64 | tr -d '\n')"

#
# Settings needed for AzureClusterIdentity used by the AzureCluster
#
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

#
# Use cluster API to create a vanilla K8s cluster in Azure
#
# Create cluster to run clusterapi services
#
kind create cluster --name kind-capz
#
# brew version of clusterctl doesn't seem to work properly,
# so don't install via brew until it's fixed!
#
#brew install clusterctl
#
# Install clusterctl
#
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.0.2/clusterctl-linux-amd64 -o clusterctl

chmod +x ./clusterctl
sudo mv ./clusterctl /usr/local/bin/clusterctl
clusterctl version

#
# Initialise the clusterapi management cluster
#
# Create a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
#
kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"

#
# Initialize the management cluster
#
clusterctl init --infrastructure azure

# Name of the Azure datacenter location. Change this value to your desired location.
export AZURE_LOCATION="westeurope"

# Select VM types.
export AZURE_CONTROL_PLANE_MACHINE_TYPE="Standard_D2s_v3"
export AZURE_NODE_MACHINE_TYPE="Standard_D2s_v3"

#
# Generate the cluster config YAML
# Make sure the kubernetes-version value is valid!
#
clusterctl generate cluster capi-quickstart \
  --kubernetes-version v1.23.0 \
  --control-plane-machine-count=3 \
  --worker-machine-count=3 \
  > ~/capi-quickstart.yaml

#
# Create the cluster
#
kubectl apply -f ~/capi-quickstart.yaml

#
# Commands to check the status of cluster creation
#
kubectl get cluster

clusterctl describe cluster capi-quickstart

kubectl get kubeadmcontrolplane

#
# Get kubeconfig
#
clusterctl get kubeconfig capi-quickstart > capi-quickstart.kubeconfig

#
# Deploy Calico with VXLAN
#
kubectl --kubeconfig=./capi-quickstart.kubeconfig \
  apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-api-provider-azure/master/templates/addons/calico.yaml

#
# Add Azure CLI extensions
#
az extension add --upgrade --yes --name connectedk8s
az extension add --upgrade --yes --name k8s-extension
az extension add --upgrade --yes --name customlocation
#
# Register providers
#
az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation
az provider register --namespace Microsoft.Web
az extension remove --name appservice-kube
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"
#
# Check provider registration status
#
az provider show -n Microsoft.Kubernetes -o table
az provider show -n Microsoft.KubernetesConfiguration -o table
az provider show -n Microsoft.ExtendedLocation -o table
az provider show -n Microsoft.Web -o table

#
# Create resource group
#
az group create --name $NAME --location $LOCATION --output table

#
# Connect the cluster
#
az connectedk8s connect --name $NAME --resource-group $NAME

#
# Delete the customer connection
#
# az connectedk8s delete --name $NAME --resource-group $NAME


#
# Check cluster status
#
az connectedk8s list --resource-group $NAME --output table

#
# Check deployments and pods
#
kubectl get deployments,pods -n azure-arc

#
# Create Log Analytics workspace
#
workspaceName="$NAME-workspace"
az monitor log-analytics workspace create \
    --resource-group $NAME \
    --workspace-name $workspaceName

#
# Get Log Analytics Workspace details
#
logAnalyticsWorkspaceId=$(az monitor log-analytics workspace show \
    --resource-group $NAME \
    --workspace-name $workspaceName \
    --query customerId \
    --output tsv)
logAnalyticsWorkspaceIdEnc=$(printf %s $logAnalyticsWorkspaceId | base64)
logAnalyticsKey=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group $NAME \
    --workspace-name $workspaceName \
    --query primarySharedKey \
    --output tsv)
logAnalyticsKeyEncWithSpace=$(printf %s $logAnalyticsKey | base64)
logAnalyticsKeyEnc=$(echo -n "${logAnalyticsKeyEncWithSpace//[[:space:]]/}")

#
# Get load balancer IP address of cluster
#
staticIp=$(az network public-ip show --resource-group capi-quickstart --name pip-capi-quickstart-apiserver --output tsv --query ipAddress)

#
# Possible issue with extension creation, this might be a fix.
# A storage class is created but not set as default. This sets the only storage class to default
#
#kubectl patch storageclass $(k get sc -o json | jq -j '.items[].metadata.name') -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

#
# Create a default storage class
#
kubectl apply -f - <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: default
provisioner: kubernetes.io/azure-file
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=0
  - gid=0
  - mfsymlinks
  - cache=strict
  - actimeo=30
parameters:
  skuName: Standard_LRS
EOF


#
# Install the app service extension
#
az k8s-extension create \
    --resource-group $NAME \
    --name $extensionName \
    --cluster-type connectedClusters \
    --cluster-name $NAME \
    --extension-type 'Microsoft.Web.Appservice' \
    --release-train stable \
    --auto-upgrade-minor-version true \
    --scope cluster \
    --release-namespace $namespace \
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" \
    --configuration-settings "appsNamespace=${namespace}" \
    --configuration-settings "clusterName=${kubeEnvironmentName}" \
    --configuration-settings "loadBalancerIp=${staticIp}" \
    --configuration-settings "keda.enabled=true" \
    --configuration-settings "buildService.storageClassName=default" \
    --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" \
    --configuration-settings "customConfigMap=${namespace}/kube-environment-config" \
    --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=capi-quickstart" \
    --configuration-settings "logProcessor.appLogs.destination=log-analytics" \
    --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=${logAnalyticsWorkspaceIdEnc}" \
    --configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=${logAnalyticsKeyEnc}"

#
# Save the ID of the extension
#
extensionId=$(az k8s-extension show \
    --cluster-type connectedClusters \
    --cluster-name $NAME \
    --resource-group $NAME \
    --name $extensionName \
    --query id \
    --output tsv)

#
# Use this command to force a wait until the extension deployment is complete
#
az resource wait --ids $extensionId --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

#
# Create a custom location
#
customLocationName="markw"
connectedClusterId=$(az connectedk8s show --resource-group $NAME --name $NAME --query id --output tsv)

az customlocation create \
    --resource-group $NAME \
    --name $customLocationName \
    --host-resource-id $connectedClusterId \
    --namespace $namespace \
    --cluster-extension-ids $extensionId

#
# To clean up the capi cluster ...
#
# kind get kubeconfig --name kind-capz > ~/kindkubeconfig
# KUBECONFIG=~/kindkubeconfig kubectl delete cluster capi-quickstart
