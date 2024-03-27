#!/bin/bash

# Define variables
disk_encryption_set_id="existing_disk_encryption_set_id"
key_vault_id="existing_key_vault_id"
resource_group="your_resource_group_name"
subscription_id="your_subscription_id"
vm_list_file="vm_names.txt"

# Function to check if VM is deallocated
is_vm_deallocated() {
    local vm_name="$1"
    local status=$(az vm show -n "$vm_name" -g "$resource_group" --subscription "$subscription_id" --query "powerState" -o tsv)
    [[ "$status" == "VM deallocated" ]]
}

# Loop through each VM in parallel
while IFS= read -r vm_name; do
    (
        echo "Processing VM: $vm_name"
        echo "Checking if VM is deallocated..."
        local retries=0
        while ! is_vm_deallocated "$vm_name"; do
            echo "VM is still running. Waiting..."
            sleep 10
            ((retries++))
            if [[ $retries -eq 5 ]]; then
                echo "Failed to deallocate VM after $retries attempts. Exiting."
                exit 1
            fi
        done
        echo "VM has been deallocated."

        # Power off the VM
        echo "Deallocating VM..."
        az vm deallocate --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id"
        echo "VM deallocated successfully."

        # Get OS disk ID
        os_disk_id=$(az vm show -n "$vm_name" -g "$resource_group" --subscription "$subscription_id" --query "storageProfile.osDisk.managedDisk.id" -o tsv)

        # Deallocate and detach OS disk
        echo "Deallocating and detaching OS disk..."
        az disk update --ids "$os_disk_id" --resource-group "$resource_group" --subscription "$subscription_id" --set osType=None
        az vm update --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id" --set storageProfile.osDisk.managedDisk.id=""
        echo "OS disk deallocated and detached successfully."

        # Get data disk IDs
        data_disk_ids=$(az vm show -n "$vm_name" -g "$resource_group" --subscription "$subscription_id" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv)

        # Deallocate and detach data disks
        echo "Deallocating and detaching data disks..."
        for disk_id in $data_disk_ids; do
            az disk update --ids "$disk_id" --resource-group "$resource_group" --subscription "$subscription_id" --set osType=None
            az vm disk detach --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id" --disk "$disk_id"
        done
        echo "Data disks deallocated and detached successfully."

        # Enable double encryption for OS disk
        echo "Enabling double encryption for OS disk..."
        az disk encryption set --resource-group "$resource_group" --subscription "$subscription_id" --name "$os_disk_id" \
            --disk-encryption-set "$disk_encryption_set_id" --key-vault "$key_vault_id"
        echo "Double encryption enabled for OS disk."

        # Enable double encryption for data disks
        echo "Enabling double encryption for data disks..."
        for disk_id in $data_disk_ids; do
            az disk encryption set --resource-group "$resource_group" --subscription "$subscription_id" --name "$disk_id" \
                --disk-encryption-set "$disk_encryption_set_id" --key-vault "$key_vault_id"
        done
        echo "Double encryption enabled for data disks."

        # Reattach and start the VM
        echo "Reattaching OS disk..."
        az vm update --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id" --set storageProfile.osDisk.managedDisk.id="$os_disk_id"
        echo "OS disk reattached successfully."

        echo "Reattaching data disks..."
        for disk_id in $data_disk_ids; do
            az vm disk attach --vm-name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id" --disk "$disk_id"
        done
        echo "Data disks reattached successfully."

        echo "Starting VM..."
        az vm start --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id"
        echo "VM started successfully."
    ) &
done < "$vm_list_file"

wait