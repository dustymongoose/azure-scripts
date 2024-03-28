#!/bin/bash

# Define variables
disk_encryption_set_id="full id of disk encryption set"
key_vault_id="full id of key vault"
resource_group="name of resource group"
subscription_id="name of subscription"
vm_list_file="vm_names.txt"


# Function to check if VM is deallocated
is_vm_stopped() {
    local vm_name="$1"
    local status=$(az vm get-instance-view -n "$vm_name" -g "$resource_group" --subscription "$subscription_id" --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" -o tsv)
    [[ "$status" == "PowerState/deallocated" ]] || [[ "$status" == "PowerState/stopped" ]]
}

# Function to check encryption status for a disk
check_encryption_type() {
    local disk_name="$1"
    local encryption_type=$(az disk show --name "$disk_name" --resource-group "$resource_group" --query "encryption.type" -o tsv)
    echo "Encryption type for disk $disk_name: $encryption_type"
}

# Loop through each VM in parallel
while IFS= read -r vm_name; do
    (
        echo "Processing VM: $vm_name"
        
        # Power off the VM first
        echo "Stopping VM..."
        # az vm stop --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id"
        az vm deallocate --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id"
        echo "VM stopped successfully."

        echo "Checking if VM is stopped..."
        retries=0
        while ! is_vm_stopped "$vm_name"; do
            echo "VM is still running. Waiting..."
            sleep 10
            ((retries++))
            if [[ $retries -eq 5 ]]; then
                echo "Failed to stop VM after $retries attempts. Exiting."
                exit 1
            fi
        done
        echo "VM has been stopped."

        # Get OS disk ID
        disk_names=$(az disk list -g $resource_group --query "[?contains(managedBy, '$vm_name')].name" -o tsv)

        # Enable double encryption for disks
        echo "Enabling double encryption for disks..."
        for disk_name in $disk_names; do
            az disk update --name $disk_name --resource-group $resource_group  \
            --encryption-type EncryptionAtRestWithPlatformAndCustomerKeys --disk-encryption-set $disk_encryption_set_id \
            --subscription $subscription_id
            echo "Double encryption enabled for disk: $disk_name."

            # Check encryption type for the disk
            check_encryption_type "$disk_name"
        done

        # Start the VM

        echo "Starting VM..."
        az vm start --name "$vm_name" --resource-group "$resource_group" --subscription "$subscription_id"
        echo "VM started successfully."
    ) &
done < "$vm_list_file"

wait
