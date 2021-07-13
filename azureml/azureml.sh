#!/bin/bash

#
# AzureML on AKS
#
location=westeurope
name=azuremlaks
azureSubscriptionId=$(az account show -s "Microsoft Azure" | jq -r .id)

az group create -n $name -l $location

az extension add -n ml

az ml workspace create -w $name -g $name

