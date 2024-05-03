PROVISIONED_FLAG_FILE=".provisioned"
FIRST_RUN_FLAG_FILE=".first_run"

function firstRun() {
  # Check if the flag file exists; if it does not, start first run
  if [ ! -f "$FIRST_RUN_FLAG_FILE" ]; then
    vagrant box update
    vagrant plugin install vagrant-scp
    echo "Starting first run, provisioning with: vagrant -up"
    echo "Please note: This operation will take at least 10 minutes..."
    vagrant up

    touch $FIRST_RUN_FLAG_FILE || true
    touch $PROVISIONED_FLAG_FILE || true
  fi
}

function provisionVms() {
  # First run & box update
  firstRun
  
  # Check if the flag file exists; if it does not, start provisioning
  if [ ! -f "$PROVISIONED_FLAG_FILE" ]; then
    echo "Starting vagrant VMs. Validators: $NUM_VALIDATORS"

    # Loop through the VM names and run vagrant up in the background
    vms=()
    pids=()
    for i in $(seq 1 $NUM_VALIDATORS); do
      vms+=("provider-chain-validator$i")
      vms+=("consumer-chain-validator$i")
    done
    for vm in "${vms[@]}"; do
      echo "Starting provisioning for $vm"
      vagrant up $vm --provision
      pids+=($!)
    done

    # Wait for all background tasks to complete
    for pid in "${pids[@]}"; do
      wait $pid
    done

    touch $PROVISIONED_FLAG_FILE || true
  fi

  echo "All VMs have been provisioned."
}