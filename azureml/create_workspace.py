import os
import azureml.core
from azureml.core import Workspace

azureSubscriptionId = os.getenv("azureSubscriptionId")
name = os.getenv("name")
location = os.getenv("location")

ws = Workspace.create(name=name,
               subscription_id=azureSubscriptionId,
               resource_group=name,
               location=location
               )