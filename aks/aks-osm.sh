#!/bin/bash

#
# Deploy AKS with OSM (Open Service Mesh) enabled
# Includes demos found at https://docs.microsoft.com/en-us/azure/aks/servicemesh-osm-about
#

#
# OSM Client Binary Setup
#
# Specify the OSM version that will be leveraged throughout these instructions
OSM_VERSION=v0.8.4

curl -sL "https://github.com/openservicemesh/osm/releases/download/$OSM_VERSION/osm-$OSM_VERSION-linux-amd64.tar.gz" | tar -vxzf -
sudo mv ./linux-amd64/osm /usr/local/bin/osm
sudo chmod +x /usr/local/bin/osm
#
# Run osm client to check it's working
#
osm version

#
# Environment variables for AKS cluster
#
version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null
location=westeurope
name=aksosm
virtualNetworkPrefix=10.201.0.0/16
subnetPrefix=10.201.0.0/24
#
# Create resource group
#
az group create -n $name -l $location

#
# Create virtual network and subnet
#
az network vnet create -n aks-vnet -g $name --address-prefixes $virtualNetworkPrefix -l westeurope --subnet-name aks-subnet --subnet-prefixes $subnetPrefix
vnetId=$(az network vnet subnet list --vnet-name aks-vnet --resource-group akscluster --query "[0].id" -o tsv)
#
# Create managed identity
#
az identity create -n $name -g $name
identityId=$(az identity show --name $name -g $name --query id -o tsv)
#
# Create AKS cluster with Azure CNI
#
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
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 30 \
    --enable-managed-identity \
    --assign-identity $identityId \
    -a open-service-mesh \
    --node-count 3

#
# Get cluster credentials
#
az aks get-credentials -n $name -g $name --overwrite-existing

#
# Check add-on is enabled
#
az aks list -g $name -o json | jq -r '.[].addonProfiles.openServiceMesh.enabled'

#
# Check status of osm-controller component
#
kubectl get deployments -n kube-system --selector app=osm-controller
kubectl get pods -n kube-system --selector app=osm-controller
kubectl get services -n kube-system --selector app=osm-controller

#
# View current OSM configuration
#
kubectl get configmap -n kube-system osm-config -o json | jq '.data'

#
# Create namespaces for the application
#
for i in bookstore bookbuyer bookthief bookwarehouse; do kubectl create ns $i; done

#
# Onboard the namespaces to OSM
#
osm namespace add bookstore bookbuyer bookthief bookwarehouse

#
# Deploy sample application
#
kubectl apply -f https://raw.githubusercontent.com/openservicemesh/osm/release-v0.8/docs/example/manifests/apps/bookbuyer.yaml
kubectl apply -f https://raw.githubusercontent.com/openservicemesh/osm/release-v0.8/docs/example/manifests/apps/bookthief.yaml
kubectl apply -f https://raw.githubusercontent.com/openservicemesh/osm/release-v0.8/docs/example/manifests/apps/bookstore.yaml
kubectl apply -f https://raw.githubusercontent.com/openservicemesh/osm/release-v0.8/docs/example/manifests/apps/bookwarehouse.yaml

#
# Check bookbuyer pod is deployed
#
kubectl get pod -n bookbuyer

#
# Port forward the bookbuyer pod
# After this step goto http://localhost:8080 to confirm operation
#
kubectl port-forward $(kubectl get pods -n bookbuyer -o json | jq -j ".items[].metadata.name") -n bookbuyer 8080:14001

#
# Port forward the bookthief pod
# After this step goto http://localhost:8080 to confirm operation
#
kubectl port-forward $(kubectl get pods -n bookthief -o json | jq -j ".items[].metadata.name") -n bookthief 8080:14001

#
# Turn off permissive mode
# After running this, the apps should no longer work - the count of books will stop incrementing
#
kubectl patch ConfigMap -n kube-system osm-config --type merge --patch '{"data":{"permissive_traffic_policy_mode":"false"}}'

#
# Set SMI traffic access policy to allow bookbuyer to communicate with bookstore and bookstore to communicate with bookwarehouse
# After running this, the bookbuyer app should be working, but not the bookthief app
#
kubectl apply -f - <<EOF
---
apiVersion: access.smi-spec.io/v1alpha3
kind: TrafficTarget
metadata:
  name: bookbuyer-access-bookstore
  namespace: bookstore
spec:
  destination:
    kind: ServiceAccount
    name: bookstore
    namespace: bookstore
  rules:
  - kind: HTTPRouteGroup
    name: bookstore-service-routes
    matches:
    - buy-a-book
    - books-bought
  sources:
  - kind: ServiceAccount
    name: bookbuyer
    namespace: bookbuyer
---
apiVersion: specs.smi-spec.io/v1alpha4
kind: HTTPRouteGroup
metadata:
  name: bookstore-service-routes
  namespace: bookstore
spec:
  matches:
  - name: books-bought
    pathRegex: /books-bought
    methods:
    - GET
    headers:
    - "user-agent": ".*-http-client/*.*"
    - "client-app": "bookbuyer"
  - name: buy-a-book
    pathRegex: ".*a-book.*new"
    methods:
    - GET
  - name: update-books-bought
    pathRegex: /update-books-bought
    methods:
    - POST
---
kind: TrafficTarget
apiVersion: access.smi-spec.io/v1alpha3
metadata:
  name: bookstore-access-bookwarehouse
  namespace: bookwarehouse
spec:
  destination:
    kind: ServiceAccount
    name: bookwarehouse
    namespace: bookwarehouse
  rules:
  - kind: HTTPRouteGroup
    name: bookwarehouse-service-routes
    matches:
    - restock-books
  sources:
  - kind: ServiceAccount
    name: bookstore
    namespace: bookstore
  - kind: ServiceAccount
    name: bookstore-v2
    namespace: bookstore
---
apiVersion: specs.smi-spec.io/v1alpha4
kind: HTTPRouteGroup
metadata:
  name: bookwarehouse-service-routes
  namespace: bookwarehouse
spec:
  matches:
    - name: restock-books
      methods:
      - POST
      headers:
      - host: bookwarehouse.bookwarehouse
EOF

#
# Apply a V2 of bookstore and allow traffic
#
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Service
metadata:
  name: bookstore-v2
  namespace: bookstore
  labels:
    app: bookstore-v2
spec:
  ports:
  - port: 14001
    name: bookstore-port
  selector:
    app: bookstore-v2
---
# Deploy bookstore-v2 Service Account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bookstore-v2
  namespace: bookstore
---
# Deploy bookstore-v2 Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bookstore-v2
  namespace: bookstore
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bookstore-v2
  template:
    metadata:
      labels:
        app: bookstore-v2
    spec:
      serviceAccountName: bookstore-v2
      containers:
        - name: bookstore
          image: openservicemesh/bookstore:v0.8.0
          imagePullPolicy: Always
          ports:
            - containerPort: 14001
              name: web
          command: ["/bookstore"]
          args: ["--path", "./", "--port", "14001"]
          env:
            - name: BOOKWAREHOUSE_NAMESPACE
              value: bookwarehouse
            - name: IDENTITY
              value: bookstore-v2
---
kind: TrafficTarget
apiVersion: access.smi-spec.io/v1alpha3
metadata:
  name: bookbuyer-access-bookstore-v2
  namespace: bookstore
spec:
  destination:
    kind: ServiceAccount
    name: bookstore-v2
    namespace: bookstore
  rules:
  - kind: HTTPRouteGroup
    name: bookstore-service-routes
    matches:
    - buy-a-book
    - books-bought
  sources:
  - kind: ServiceAccount
    name: bookbuyer
    namespace: bookbuyer
EOF

#
# Apply a traffic split policy to send 75% of traffic to the new service
# After running this, set up a port forward to bookbuyer and check that traffic splitting is happening via the UI
#
kubectl apply -f - <<EOF
apiVersion: split.smi-spec.io/v1alpha2
kind: TrafficSplit
metadata:
  name: bookstore-split
  namespace: bookstore
spec:
  service: bookstore.bookstore
  backends:
  - service: bookstore
    weight: 25
  - service: bookstore-v2
    weight: 75
EOF

#
# Add Ingress
#
# Create a service for bookbuyer
#
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: bookbuyer
  namespace: bookbuyer
  labels:
    app: bookbuyer
spec:
  ports:
  - port: 14001
    name: inbound-port
  selector:
    app: bookbuyer
EOF

#
# Create a namespace for your ingress resources
#
kubectl create namespace ingress-basic

# Add the ingress-nginx repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# Update the helm repo(s)
helm repo update

# Use Helm to deploy an NGINX ingress controller in the ingress-basic namespace
helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress-basic \
    --set controller.replicaCount=1 \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set controller.admissionWebhooks.patch.nodeSelector."beta\.kubernetes\.io/os"=linux

#
# Check for public IP address assignment to the ingress controller
#
kubectl --namespace ingress-basic get services -o wide -w nginx-ingress-ingress-nginx-controller

#
# Add ingress rules
#
kubectl apply -f - <<EOF
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: bookbuyer-ingress
  namespace: bookbuyer
  annotations:
    kubernetes.io/ingress.class: nginx

spec:

  rules:
    - host: bookbuyer.contoso.com
      http:
        paths:
        - path: /
          backend:
            serviceName: bookbuyer
            servicePort: 14001

  backend:
    serviceName: bookbuyer
    servicePort: 14001
EOF

#
# Clean up
#
az group delete -n $name -y
