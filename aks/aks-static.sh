#!/bin/bash

#
# Basic AKS cluster
#

version=$(az aks get-versions -l $location --query "orchestrators[-1].orchestratorVersion" -o tsv)  2>/dev/null
location=westeurope
name=akscluster

az group create -n $name -l $location

az aks create \
    --name $name \
    --resource-group $name \
    --kubernetes-version $version \
    --location $location \
    --network-plugin kubenet \
    --node-count 3

az aks get-credentials -n $name -g $name --overwrite-existing

#
# Add nodepool with two taints
#
 az aks nodepool add \
    --resource-group akscluster \
    --cluster-name akscluster \
    --name np01 \
    --node-count 1 \
    --node-taints samplekey1=samplevalue1:NoSchedule,samplekey2=samplevalue2:NoSchedule