function provisionVms() {
  PROVISIONED_FLAG_FILE=".provisioned"
  vagrant box update

  # Check if the flag file exists; if it does not, start provisioning
  if [ ! -f "$PROVISIONED_FLAG_FILE" ]; then
    echo "Starting vagrant VMs. Validators: $CHAIN_NUM_VALIDATORS"
    vagrant plugin install vagrant-scp

    # Loop through the VM names and run vagrant up in the background
    vms=()
    pids=()
    for i in $(seq 1 $CHAIN_NUM_VALIDATORS); do
      vms+=("provider-chain-validator$i")
      vms+=("consumer-chain-validator$i")
    done
    for vm in "${vms[@]}"; do
      echo "Starting provisioning for $vm"
      vagrant up $vm --provision --no-parallel &
      pids+=($!)
    done

    # Wait for all background tasks to complete
    for pid in "${pids[@]}"; do
      wait $pid
    done

    touch "$PROVISIONED_FLAG_FILE"
  fi

  echo "All VMs have been provisioned."
}