#!/bin/bash

# Define variables for existing disk encryption set and Azure Key Vault
disk_encryption_set_id="existing_disk_encryption_set_id"
key_vault_id="existing_key_vault_id"

# Path to the text file containing VM names
vm_list_file="vm_names.txt"

# Function to check if VM is deallocated
is_vm_deallocated() {
    local vm_name="$1"
    local resource_group="$2"
    local status=$(az vm show -n "$vm_name" -g "$resource_group" --query "powerState" -o tsv)
    [[ "$status" == "VM deallocated" ]]
}

# Loop through each VM in parallel
while IFS= read -r vm_name; do
    (
        # Check if VM is deallocated
        while ! is_vm_deallocated "$vm_name" "$resource_group"; do
            sleep 10
        done

        # Power off the VM
        az vm deallocate --name "$vm_name" --resource-group "$resource_group"

        # Get OS disk ID
        os_disk_id=$(az vm show -n "$vm_name" -g "$resource_group" --query "storageProfile.osDisk.managedDisk.id" -o tsv)

        # Deallocate and detach OS disk
        az disk update --ids "$os_disk_id" --resource-group "$resource_group" --set osType=None
        az vm update --name "$vm_name" --resource-group "$resource_group" --set storageProfile.osDisk.managedDisk.id=""

        # Get data disk IDs
        data_disk_ids=$(az vm show -n "$vm_name" -g "$resource_group" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv)

        # Deallocate and detach data disks
        for disk_id in $data_disk_ids; do
            az disk update --ids "$disk_id" --resource-group "$resource_group" --set osType=None
            az vm disk detach --name "$vm_name" --resource-group "$resource_group" --disk "$disk_id"
        done

        # Enable double encryption for OS disk
        az disk encryption set --resource-group "$resource_group" --name "$os_disk_id" \
            --disk-encryption-set "$disk_encryption_set_id" --key-vault "$key_vault_id"

        # Enable double encryption for data disks
        for disk_id in $data_disk_ids; do
            az disk encryption set --resource-group "$resource_group" --name "$disk_id" \
                --disk-encryption-set "$disk_encryption_set_id" --key-vault "$key_vault_id"
        done

        # Reattach and start the VM
        az vm update --name "$vm_name" --resource-group "$resource_group" --set storageProfile.osDisk.managedDisk.id="$os_disk_id"
        for disk_id in $data_disk_ids; do
            az vm disk attach --vm-name "$vm_name" --resource-group "$resource_group" --disk "$disk_id"
        done
        az vm start --name "$vm_name" --resource-group "$resource_group"
    ) &
done < "$vm_list_file"

# Wait for all background processes to finish
wait