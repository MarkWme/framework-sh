#!/bin/bash

#
# Deploy Azure App Service on Kubernetes to an AKS cluster
#

#
# Install / upgrade Azure CLI extensions
#
az extension add --upgrade --yes --name connectedk8s
az extension add --upgrade --yes --name k8s-extension
az extension add --upgrade --yes --name customlocation

#
# Register providers
#
az provider register --namespace Microsoft.ExtendedLocation --wait
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait

#
# Update appservice extension
#
az extension remove --name appservice-kube
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"

location=westeurope
name=aksappservice
extensionName=appservice-ext
namespace=appservice-ns
kubeEnvironmentName=azappsrvk8s

az group create -g $name -l $location
az aks create --resource-group $name --name $name
infra_rg=$(az aks show --resource-group $name --name $name --output tsv --query nodeResourceGroup)
az network public-ip create --resource-group $infra_rg --name MyPublicIP --sku STANDARD
staticIp=$(az network public-ip show --resource-group $infra_rg --name MyPublicIP --output tsv --query ipAddress)

az aks get-credentials --resource-group $name --name $name --admin

#
# Connect the cluster
#
az connectedk8s connect --name $name --resource-group $name

#
# Delete the customer connection
#
# az connectedk8s delete --name $NAME --resource-group $NAME


#
# Check cluster status
#
az connectedk8s list --resource-group $name --output table

#
# Check deployments and pods
#
kubectl get deployments,pods -n azure-arc

#
# Create Log Analytics workspace
#
workspaceName="$name-workspace"
az monitor log-analytics workspace create \
    --resource-group $name \
    --workspace-name $workspaceName

#
# Get Log Analytics Workspace details
#
logAnalyticsWorkspaceId=$(az monitor log-analytics workspace show \
    --resource-group $name \
    --workspace-name $workspaceName \
    --query customerId \
    --output tsv)
logAnalyticsWorkspaceIdEnc=$(printf %s $logAnalyticsWorkspaceId | base64)
logAnalyticsKey=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group $name \
    --workspace-name $workspaceName \
    --query primarySharedKey \
    --output tsv)
logAnalyticsKeyEncWithSpace=$(printf %s $logAnalyticsKey | base64)
logAnalyticsKeyEnc=$(echo -n "${logAnalyticsKeyEncWithSpace//[[:space:]]/}")

#
# Install the app service extension
#
az k8s-extension create \
    --resource-group $name \
    --name $extensionName \
    --cluster-type connectedClusters \
    --cluster-name $name \
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
    --cluster-name $name \
    --resource-group $name \
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
connectedClusterId=$(az connectedk8s show --resource-group $name --name $name --query id --output tsv)

az customlocation create \
    --resource-group $name \
    --name $customLocationName \
    --host-resource-id $connectedClusterId \
    --namespace $namespace \
    --cluster-extension-ids $extensionId

#
# Check the customLocation has been created
#
az customlocation show \
    --resource-group $name \
    --name $customLocationName

#
# Save the customLocation ID
#
customLocationId=$(az customlocation show \
    --resource-group $name \
    --name $customLocationName \
    --query id \
    --output tsv)

#
# Ugh, bug in latest Azure CLI will cause kube create phase to fail
# So, downgrade the CLI!
#
sudo apt install -y --allow-downgrades azure-cli=2.25.0-1~focal

#
# Create the AppService Kubernetes environment
#
az appservice kube create \
    --resource-group $name \
    --name $kubeEnvironmentName \
    --custom-location $customLocationId \
    --static-ip $staticIp