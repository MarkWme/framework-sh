#!/bin/bash

#
# Container Supply Chain 
#
# Choose random name for resources
#
# Pre-req's
#
# Fork these repos
# https://github.com/importing-public-content/base-image-node.git
# https://github.com/importing-public-content/import-baseimage-node.git
# https://github.com/importing-public-content/hello-world.git
#
# Create a GitHub PAT
# Create a Docker PAT

export LC_CTYPE=C
suffix=$(cat /dev/urandom | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)


RESOURCE_GROUP_LOCATION=westeurope

# Set the three registry names, must be globally unique:
REGISTRY_PUBLIC=publicregistry${suffix}
REGISTRY_BASE_ARTIFACTS=contosobaseartifacts${suffix}
REGISTRY=contoso${suffix}

# default resource groups
REGISTRY_PUBLIC_RG=${REGISTRY_PUBLIC}-rg
REGISTRY_BASE_ARTIFACTS_RG=${REGISTRY_BASE_ARTIFACTS}-rg
REGISTRY_RG=${REGISTRY}-rg

# fully qualified registry urls
REGISTRY_DOCKERHUB_URL=docker.io
REGISTRY_PUBLIC_URL=${REGISTRY_PUBLIC}.azurecr.io
REGISTRY_BASE_ARTIFACTS_URL=${REGISTRY_BASE_ARTIFACTS}.azurecr.io
REGISTRY_URL=${REGISTRY}.azurecr.io

# Azure key vault for storing secrets, name must be globally unique
AKV=acr-task-creds-${suffix}
AKV_RG=${AKV}-rg

# ACI for hosting the deployed application
ACI=hello-world-aci-${suffix}
ACI_RG=${ACI}-rg

GIT_BASE_IMAGE_NODE=https://github.com/markwme/base-image-node.git#main
GIT_NODE_IMPORT=https://github.com/markwme/import-baseimage-node.git#main
GIT_HELLO_WORLD=https://github.com/markwme/hello-world.git#main

#
# Get access tokens for GitHub and Docker
#
read -p "Enter GitHub PAT" GIT_TOKEN
read -p "Enter Docker ID" REGISTRY_DOCKERHUB_USER
read -p "Enter Docker PAT?" REGISTRY_DOCKERHUB_PASSWD

#
# Create three ACR instances
#
az group create --name $REGISTRY_PUBLIC_RG --location $RESOURCE_GROUP_LOCATION
az acr create --resource-group $REGISTRY_PUBLIC_RG --name $REGISTRY_PUBLIC --sku Premium

az group create --name $REGISTRY_BASE_ARTIFACTS_RG --location $RESOURCE_GROUP_LOCATION
az acr create --resource-group $REGISTRY_BASE_ARTIFACTS_RG --name $REGISTRY_BASE_ARTIFACTS --sku Premium

az group create --name $REGISTRY_RG --location $RESOURCE_GROUP_LOCATION
az acr create --resource-group $REGISTRY_RG --name $REGISTRY --sku Premium

#
# Create Key Vault instance to store access tokens
#
az group create --name $AKV_RG --location $RESOURCE_GROUP_LOCATION
az keyvault create --resource-group $AKV_RG --name $AKV

az keyvault secret set \
--vault-name $AKV \
--name registry-dockerhub-user \
--value $REGISTRY_DOCKERHUB_USER

az keyvault secret set \
--vault-name $AKV \
--name registry-dockerhub-password \
--value $REGISTRY_DOCKERHUB_PASSWD

az keyvault secret set --vault-name $AKV --name github-token --value $GIT_TOKEN

az keyvault secret show --vault-name $AKV --name github-token --query value -o tsv

#
# Create resource group for Azure Container Instance
#

az group create --name $ACI_RG --location $RESOURCE_GROUP_LOCATION

#
# Create the simulated Node.js public base image
#
# Done this way rather than using the real base image so that we can make changes to it
# and simulate what happens when a real base image is updated
#
# Setup the task
#
az acr task create \
  --name node-public \
  -r $REGISTRY_PUBLIC \
  -f acr-task.yaml \
  --context $GIT_BASE_IMAGE_NODE \
  --git-access-token $(az keyvault secret show \
                        --vault-name $AKV \
                        --name github-token \
                        --query value -o tsv) \
  --set REGISTRY_FROM_URL=${REGISTRY_DOCKERHUB_URL}/ \
  --assign-identity

#
# Add Docker hub credentials to the task
#
az acr task credential add \
  -n node-public \
  -r $REGISTRY_PUBLIC \
  --login-server $REGISTRY_DOCKERHUB_URL \
  -u https://${AKV}.vault.azure.net/secrets/registry-dockerhub-user \
  -p https://${AKV}.vault.azure.net/secrets/registry-dockerhub-password \
  --use-identity '[system]'

#
# Grant the task access to Key Vault
#
az keyvault set-policy \
  --name $AKV \
  --resource-group $AKV_RG \
  --object-id $(az acr task show \
                  --name node-public \
                  --registry $REGISTRY_PUBLIC \
                  --query identity.principalId --output tsv) \
  --secret-permissions get

#
# Run the task manually
#
az acr task run -r $REGISTRY_PUBLIC -n node-public

#
# Confirm the new image is available
#
az acr repository show-tags -n $REGISTRY_PUBLIC --repository node

#
# Create the hello-world image
#
# Builds an app container based on the node image created above
#
# Create a token to allow access to the simulated public repo
#
az keyvault secret set \
  --vault-name $AKV \
  --name "registry-${REGISTRY_PUBLIC}-user" \
  --value "registry-${REGISTRY_PUBLIC}-user"

az keyvault secret set \
  --vault-name $AKV \
  --name "registry-${REGISTRY_PUBLIC}-password" \
  --value $(az acr token create \
              --name "registry-${REGISTRY_PUBLIC}-user" \
              --registry $REGISTRY_PUBLIC \
              --scope-map _repositories_pull \
              -o tsv \
              --query 'credentials.passwords[0].value')
#
# Create token to allow ACI to have pull access to the private registry
#
az keyvault secret set \
  --vault-name $AKV \
  --name "registry-${REGISTRY}-user" \
  --value "registry-${REGISTRY}-user"

az keyvault secret set \
  --vault-name $AKV \
  --name "registry-${REGISTRY}-password" \
  --value $(az acr token create \
              --name "registry-${REGISTRY}-user" \
              --registry $REGISTRY \
              --repository hello-world content/read \
              -o tsv \
              --query 'credentials.passwords[0].value')
#
# Create task to build image
#
az acr task create \
  -n hello-world \
  -r $REGISTRY \
  -f acr-task.yaml \
  --context $GIT_HELLO_WORLD \
  --git-access-token $(az keyvault secret show \
                        --vault-name $AKV \
                        --name github-token \
                        --query value -o tsv) \
  --set REGISTRY_FROM_URL=${REGISTRY_PUBLIC_URL}/ \
  --set KEYVAULT=$AKV \
  --set ACI=$ACI \
  --set ACI_RG=$ACI_RG \
  --assign-identity

az acr task credential update \
  -n hello-world \
  -r $REGISTRY \
  --login-server $REGISTRY_PUBLIC_URL \
  -u https://acr-task-creds-geskk.vault.azure.net/secrets/registry-publicregistrygeskk-user \
  -p https://acr-task-creds-geskk.vault.azure.net/secrets/registry-publicregistrygeskk-password \
  --use-identity '[system]'

az keyvault set-policy \
  --name $AKV \
  --resource-group $AKV_RG \
  --object-id $(az acr task show \
                  --name hello-world \
                  --registry $REGISTRY \
                  --query identity.principalId --output tsv) \
  --secret-permissions get

az role assignment create \
  --assignee $(az acr task show \
  --name hello-world \
  --registry $REGISTRY \
  --query identity.principalId --output tsv) \
  --scope $(az group show -n $ACI_RG --query id -o tsv) \
  --role owner

az acr task run -r $REGISTRY -n hello-world

az container show \
  --resource-group $ACI_RG \
  --name ${ACI} \
  --query ipAddress.ip \
  --out tsv

  