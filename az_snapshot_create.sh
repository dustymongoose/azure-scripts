#!/bin/bash

# Define Azure Subscription ID and Resource Group
azure_subscription=""
resource_group=""

text_file="vm_names.txt"

# Read VM names from text file into an array
vm_names=()
while IFS= read -r line; do
    vm_names+=("$line")
done < "$text_file"

# Date for snapshot naming
snapshot_date=$(date +%Y-%m-%d)

# Set the Azure Subscription context
az account set --subscription "$azure_subscription"

# Function to create snapshot for a given disk ID and VM name
create_snapshot() {
   local disk_id=$1
   local vm_name=$2
   local snapshot_name=$3

   echo "Creating snapshot for disk ID: $disk_id with name: $snapshot_name"
   # Create the snapshot within the specified resource group
   az snapshot create \
       --name "$snapshot_name" \
       --resource-group "$resource_group" \
       --source "$disk_id" \
       --tags "VMName=$vm_name" "Date=$snapshot_date" >/dev/null

   echo "Snapshot created: $snapshot_name"
}

# Loop through each VM
for vm_name in "${vm_names[@]}"; do
   echo "Processing VM: $vm_name within subscription $azure_subscription and resource group $resource_group"

   # Check if VM exists
   if ! az vm show --name "$vm_name" --resource-group "$resource_group" &>/dev/null; then
       echo "VM $vm_name does not exist in resource group $resource_group. Skipping."
       continue
   fi

   # Fetch the OS disk ID
   os_disk_id=$(az vm show --name "$vm_name" --resource-group "$resource_group" --query "storageProfile.osDisk.managedDisk.id" -o tsv)

   # Initialize disk_ids array with OS disk
   disk_ids=("$os_disk_id")

   # Fetch all data disks attached to VM and append to disk_ids array
   data_disk_ids=$(az vm show --name "$vm_name" --resource-group "$resource_group" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv)
   for id in $data_disk_ids; do
       disk_ids+=("$id")
   done

   # Loop through each disk
   for disk_id in "${disk_ids[@]}"; do
       disk_name=$(az disk show --id "$disk_id" --query "name" -o tsv)
       snapshot_name="${vm_name}-${disk_name}-${snapshot_date}"

       # Check if snapshot already exists
       if ! az snapshot list --resource-group "$resource_group" --query "[?name=='$snapshot_name']" | grep -q "$snapshot_name"; then
           create_snapshot "$disk_id" "$vm_name" "$snapshot_name"
       else
           echo "Snapshot with name $snapshot_name already exists. Skipping creation."
       fi
   done
done
