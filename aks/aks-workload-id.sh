#!/bin/bash

#
# AKS cluster with Azure Workload Identity
#
location=westeurope
#
# Choose random name for resources
#
name=aks-$(cat /dev/urandom | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
#
# Calculate next available network address space
#
number=0
number=$(az network vnet list --query "[].addressSpace.addressPrefixes" -o tsv | cut -d . -f 2 | sort | tail -n 1)
networkNumber=$(expr $number + 1)
virtualNetworkPrefix=10.${networkNumber}.0.0/16
aksSubnetPrefix=10.${networkNumber}.0.0/24

version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location

#
# Create Log Analytics workspace
#
az monitor log-analytics workspace create -g $name -n ${name}-logs
workspaceId=$(az monitor log-analytics workspace list --query "[?name=='${name}-logs'].id" -o tsv)

#
# Creates Network and subnets for cluster and Application Gateway
#
az network vnet create -g $name -n ${name}-network --address-prefixes $virtualNetworkPrefix
az network vnet subnet create -g $name --vnet-name ${name}-network --name ${name}-aks-subnet --address-prefixes $aksSubnetPrefix -o table

aksSubnetId=$(az network vnet subnet list --vnet-name ${name}-network --resource-group $name --query "[?name=='${name}-aks-subnet'].id" -o tsv)
#
# Create managed identity for control plane
#
az identity create -n $name -g $name -o table
identityId=$(az identity show --name $name -g $name --query id -o tsv)

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $aksSubnetId \
    --service-cidr 10.240.0.0/24 \
    --dns-service-ip 10.240.0.10 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --enable-oidc-issuer \
    --node-count 3 \
    --enable-addons monitoring \
    --workspace-resource-id $workspaceId \
    --tags "features=workload-id"

az aks get-credentials -n $name -g $name --overwrite-existing

#
# Output the OIDC issuer URL
#
az aks show --resource-group $name --name $name --query "oidcIssuerProfile.issuerUrl" -otsv

export azureTenantId="$(az account show -s "Microsoft Azure" --query tenantId -o tsv)"

#
# Install mutating admission webhook
#
git clone https://github.com/Azure/azure-workload-identity ~/repos/azure-workload-identity
cd ~/repos/azure-workload-identity
helm install workload-identity-webhook charts/workload-identity-webhook \
   --namespace azure-workload-identity-system \
   --create-namespace \
   --set azureTenantID="${azureTenantId}"

#
# Demo
#
# environment variables for the Azure Key Vault resource
export keyVaultName=${name}-vault
export keyVaultSecretName="my-secret"

# environment variables for the AAD application
export applicationName=${name}-azwi-demo

# environment variables for the Kubernetes service account & federated identity credential
export serviceAccountNamespace="default"
export serviceAccountName="workload-identity-sa"
export serviceAccountIssuer=$(az aks show --resource-group "$name" --name "$name" --query "oidcIssuerProfile.issuerUrl" -otsv)

#
# Create an Azure Key Vault instance
#
az keyvault create --resource-group "$name" \
   --location "$location" \
   --name "$keyVaultName"

#
# Create a secret
#
az keyvault secret set --vault-name "$keyVaultName" \
   --name "$keyVaultSecretName" \
   --value "Hello\!"

#
# Create an Azure AD application
#
azwi serviceaccount create phase app --aad-application-name "$applicationName"

#
# Set the access policy so the AAD application can access key vault
#
export applicationClientId="$(az ad sp list --display-name "$applicationName" --query '[0].appId' -otsv)"
az keyvault set-policy --name "$keyVaultName" \
  --secret-permissions get \
  --spn "$applicationClientId"

#
# Create a Kubernetes service account
#
azwi serviceaccount create phase sa \
  --aad-application-name "$applicationName" \
  --service-account-namespace "$serviceAccountNamespace" \
  --service-account-name "$serviceAccountName"

#
# Establish federation between the AAD application and the service account
#
azwi serviceaccount create phase federated-identity \
  --aad-application-name "$applicationName" \
  --service-account-namespace "$serviceAccountNamespace" \
  --service-account-name "$serviceAccountName" \
  --service-account-issuer-url "$serviceAccountIssuer"

#
# Deploy the demo workload
#
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: quick-start
  namespace: $serviceAccountNamespace
spec:
  serviceAccountName: $serviceAccountName
  containers:
    - image: ghcr.io/azure/azure-workload-identity/msal-go:latest
      name: oidc
      env:
      - name: KEYVAULT_NAME
        value: $keyVaultName
      - name: SECRET_NAME
        value: $keyVaultSecretName
  nodeSelector:
    kubernetes.io/os: linux
EOF
#
# Confirm the app was able to get the secret
#
k logs quick-start                                                   
#
# Output will be similar to
# I0112 15:06:51.685795       1 main.go:30] "successfully got secret" secret="Hello!"
#

#
# Delete cluster
#
# az ad sp delete --id $applicationClientId
# az group delete -n $name -y