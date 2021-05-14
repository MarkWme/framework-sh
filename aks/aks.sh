#!/usr/bin/zsh

zparseopts -D -E -F - l:=location -location:=location v:=version -version:=version n:=name -name:=name

#
# Check if a name has been provided. If not, default to aks
#
if [ -z $name[1] ]; then
    name=aks
else
    name=${name[-1]}
fi

#
# Check if a location has been passed in. If not, default to West Europe.
#
if [ -z $location[1] ]; then
    location=westeurope
else
    location=${location[-1]}
fi

#
# Check if a version has been passed in. If not, default to the latest version of Kubernetes for the region
#
if [ -z $version[1] ]; then
    version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv) 2>/dev/null
else
    version=${version[-1]}
fi

echo Creating resources with the following values
echo --------------------------------------------
echo Name........: $name
echo Location....: $location
echo K8s Version.: $version
echo .
#
# Create resource group
#
echo Creating resource group
echo -----------------------

az group create --name $name --location $location

#
# Create cluster
#
echo Creating AKS cluster
echo --------------------

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin kubenet \
    --node-count 3
