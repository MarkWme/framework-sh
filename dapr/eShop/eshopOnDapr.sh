#!/bin/bash

#
# Deploy eShop on Dapr to an AKS cluster
#
location=westeurope
name=aksdapreshop
virtualNetworkName=akscluster-vnet
virtualNetworkPrefix=10.150.0.0/16
subnetName=akscluster-subnet
subnetPrefix=10.150.0.0/24
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null

az group create -n $name -l $location

#
# AKS cluster with Azure CNI
# Creates VNet, Managed Identity and cluster with three nodes
#
az network vnet create -n $virtualNetworkName -g $name --address-prefixes $virtualNetworkPrefix -l $location --subnet-name $subnetName --subnet-prefixes $subnetPrefix
vnetId=$(az network vnet subnet list --vnet-name $virtualNetworkName --resource-group $name --query "[0].id" -o tsv)

az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin azure \
    --vnet-subnet-id $vnetId \
    --docker-bridge-address 172.17.0.1/16 \
    --dns-service-ip 10.240.0.10 \
    --service-cidr 10.240.0.0/24 \
    --enable-managed-identity \
    --assign-identity $identityId \
    --node-vm-size Standard_DS3_v2 \
    --node-count 3

az aks get-credentials -n $name -g $name --overwrite-existing

az aks update -n $name -g $name --attach-acr pcreuwcore

dapr init -k

gh repo clone https://github.com/dotnet-architecture/eShopOnDapr.git ~/repos/eShopOnDapr


sh -c 'cd ~/repos/eShopOnDapr/deploy/k8s && exec ./start-all.sh'

#
# Build container images
#
docker build -f src/Services/Basket/Basket.API/Dockerfile -t pcreuwcore.azurecr.io/eshopdapr/basket.api:latest .

docker build -f src/Services/Catalog/Catalog.API/Dockerfile -t pcreuwcore.azurecr.io/eshopdapr/catalog.api:latest .

docker build -f src/Services/Ordering/Ordering.API/Dockerfile -t pcreuwcore.azurecr.io/eshopdapr/ordering.api:latest .

docker build -f src/Services/Payment/Payment.API/Dockerfile -t pcreuwcore.azurecr.io/eshopdapr/payment.api:latest .

docker build -f src/ApiGateways/Aggregators/Web.Shopping.HttpAggregator/Dockerfile -t pcreuwcore.azurecr.io/eshopdapr/webshoppingagg:latest .
#
# Apply the following role binding to allow the default
# service account to access the redis secret
# https://github.com/dapr/quickstarts/issues/365
#
kubectl apply -f - <<EOF
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: admin
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: default
  namespace: eshop
EOF

#
# Add nodepool with two taints
#
 az aks nodepool add \
    --resource-group $name \
    --cluster-name $name \
    --name np01 \
    --node-count 3 \
    --node-taints samplekey1=samplevalue1:NoSchedule,samplekey2=samplevalue2:NoSchedule

#
# Add nodepool with modified max pods value
#
az aks nodepool add \
  --resource-group $name \
  --cluster-name $name \
  --name np01 \
  --node-count 3 \
  --max-pods 20
#
# Delete cluster
#
az group delete -n $name -y