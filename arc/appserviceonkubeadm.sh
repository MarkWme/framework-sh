#!/bin/bash

#
# Deploy a Kubernetes cluster to Azure using kubeadm
# Manage cluster with Azure Arc and add App Services
#
# Not working yet!
# App Service on K8s needs some storage. To set that up requires the CSI drivers. And I think they
# depend on the cloud provider. And that needs a bit of detailed reading to get it working :-)
#
# Set environment variables
#
location=westeurope
#
# Choose random name for resources
#
name=kube-$(cat /dev/urandom | tr -dc '[:lower:]' | fold -w ${1:-5} | head -n 1)
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
subnetPrefix=10.${networkNumber}.0.0/24

az group create -n $name -l $location -o table

az network vnet create \
    --resource-group $name \
    --name ${name}-vnet \
    --address-prefix $virtualNetworkPrefix \
    --subnet-name ${name}-subnet \
    --subnet-prefix $subnetPrefix \
    -o table

az network nsg create \
    --resource-group $name \
    --name ${name}-subnet-nsg \
    -o table

az network nsg rule create \
    --resource-group $name \
    --nsg-name ${name}-subnet-nsg \
    --name ${name}-ssh \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 22 \
    --access allow \
    -o table

az network nsg rule create \
    --resource-group $name \
    --nsg-name ${name}-subnet-nsg \
    --name ${name}-web \
    --protocol tcp \
    --priority 1001 \
    --destination-port-range 6443 \
    --access allow \
    -o table

az network vnet subnet update \
    -g $name \
    -n ${name}-subnet \
    --vnet-name ${name}-vnet \
    --network-security-group ${name}-subnet-nsg \
    -o table

for hostname in ${name}-control-1 ${name}-control-2 ${name}-worker-1 ${name}-worker-2
do
    az vm create -n $hostname -g $name \
    --image UbuntuLTS \
    --vnet-name ${name}-vnet \
    --subnet ${name}-subnet \
    --admin-username guvnor \
    --ssh-key-value @~/.ssh/id_rsa.pub \
    --size Standard_D2ds_v4 \
    --nsg ${name}-subnet-nsg \
    --public-ip-sku Standard \
    -o table
done
#
# Set up a load balancer
#
az network public-ip create \
    --resource-group $name \
    --name ${name}-control-ip \
    --sku Standard \
    --dns-name ${name} \
    -o table

 az network lb create \
    --resource-group $name \
    --name ${name}-lb \
    --sku Standard \
    --public-ip-address ${name}-control-ip \
    --frontend-ip-name ${name}-control-ip \
    --backend-pool-name ${name}-control-nodes \
    -o table     

az network lb probe create \
    --resource-group $name \
    --lb-name ${name}-lb \
    --name ${name}-control-web \
    --protocol tcp \
    --port 6443 \
    -o table

az network lb rule create \
    --resource-group $name \
    --lb-name ${name}-lb \
    --name ${name}-control-rule \
    --protocol tcp \
    --frontend-port 6443 \
    --backend-port 6443 \
    --frontend-ip-name ${name}-control-ip \
    --backend-pool-name ${name}-control-nodes \
    --probe-name ${name}-control-web \
    --disable-outbound-snat true \
    --idle-timeout 15 \
    --enable-tcp-reset true \
    -o table

az network nic ip-config address-pool add \
    --address-pool ${name}-control-nodes \
    --ip-config-name ipconfig${name}-control-1 \
    --nic-name ${name}-control-1VMNic \
    --resource-group $name \
    --lb-name ${name}-lb \
    -o table

az network nic ip-config address-pool add \
    --address-pool ${name}-control-nodes \
    --ip-config-name ipconfig${name}-control-2 \
    --nic-name ${name}-control-2VMNic \
    --resource-group $name \
    --lb-name ${name}-lb \
    -o table

control1ip=$(az vm list-ip-addresses -g $name -n ${name}-control-1 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
control2ip=$(az vm list-ip-addresses -g $name -n ${name}-control-2 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
worker1ip=$(az vm list-ip-addresses -g $name -n ${name}-worker-1 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
worker2ip=$(az vm list-ip-addresses -g $name -n ${name}-worker-2 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)

#
# Temporary
#
control1ip=$(az vm list-ip-addresses -g kube-htqif -n kube-htqif-control-1 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
control2ip=$(az vm list-ip-addresses -g kube-htqif -n kube-htqif-control-2 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
worker1ip=$(az vm list-ip-addresses -g kube-htqif -n kube-htqif-worker-1 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)
worker2ip=$(az vm list-ip-addresses -g kube-htqif -n kube-htqif-worker-2 --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)

#
# Configure first control plane node
#
ssh guvnor@$control1ip

sudo apt update
sudo apt -y install curl apt-transport-https;

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt -y install vim git curl wget kubelet kubeadm kubectl containerd;

sudo apt-mark hold kubelet kubeadm kubectl

kubectl version --client && kubeadm version

#
# Configure networking on nodes
#

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots.
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

sudo systemctl restart containerd

# Let iptables see bridged traffic
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system

# Setup kubeadm
# Replace name of cluster / location if needed
sudo kubeadm init --control-plane-endpoint "kube-vujgs.westeurope.cloudapp.azure.com:6443" --upload-certs

#
# Setup kubeconfig
#
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Add a CNI
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

# Check for node readiness
kubectl get nodes

#
# When you've run through this once, the first control plane node setup is complete.
# To setup the second node, run all the above again up to the kubeadm commands. Then run the kubeadmin join command that was output as a result of running kubeadm on the first node
#
# For the worker nodes, the same again, but make sure to use the second of the two kubeadm commands that are output
#
# You can optionally copy the kubeconfig to your local machine
#
# scp guvnor@$control1ip:/home/guvnor/.kube/config ~/.kube/config
#
# Note this will overwrite existing kubeconfig files. If you want to copy this config elsewhere, use export KUBECONFIG=path-to-kubeconfig
#

#
# Set up app service components
#

az extension add --upgrade --yes --name connectedk8s
az extension add --upgrade --yes --name k8s-extension
az extension add --upgrade --yes --name customlocation

az extension remove --name appservice-kube
az extension add --upgrade --yes --name appservice-kube
#
# Above command current deploys v0.1.2, below v0.2.2?
#
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"


#
# Create resource group for Azure Arc resources
#

az group create -n ${name}-arc -l $location -o table

#
# Onboard the cluster to Arc
# kube config needs to be set up and pointing to the cluster to be onboarded before running this.
#
az connectedk8s connect --name $name --resource-group ${name}-arc


#
# Check cluster status
#
az connectedk8s list --resource-group ${name}-arc --output table

#
# Check deployments and pods
#
kubectl get deployments,pods -n azure-arc

#
# Create Log Analytics workspace
#
workspaceName=${name}-workspace
az monitor log-analytics workspace create \
    --resource-group ${name}-arc \
    --workspace-name $workspaceName

#
# Get Log Analytics Workspace details
#
logAnalyticsWorkspaceId=$(az monitor log-analytics workspace show \
    --resource-group ${name}-arc \
    --workspace-name $workspaceName \
    --query customerId \
    --output tsv)
logAnalyticsWorkspaceIdEnc=$(printf %s $logAnalyticsWorkspaceId | base64)
logAnalyticsKey=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group ${name}-arc \
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

extensionName="appservice-ext"
namespace="appservice-ns"
kubeEnvironmentName=${name}-appservice

#
# Install the app service extension
#
az k8s-extension create \
    --resource-group ${name}-arc \
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
