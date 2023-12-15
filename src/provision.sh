PROVISIONED_FLAG_FILE=".provisioned"
FIRST_RUN_FLAG_FILE=".first_run"

function validateMigrationStateExport() {
  if [[ "$CONSUMER_MIGRATION" == "true" ]] && [[ "$CONSUMER_GENESIS_SOURCE" == "migration_state_export.json" ]]; then
    echo "Validating consumer migration state export..."
    if ! jq . $CONSUMER_GENESIS_SOURCE > /dev/null 2>&1 ; then
      echo "Invalid JSON in file: $CONSUMER_GENESIS_SOURCE"
      return 1
    fi
  fi
  return 0
}

function firstRun() {
  # Check if the flag file exists; if it does not, start first run
  if [ ! -f "$FIRST_RUN_FLAG_FILE" ]; then
    vagrant box update
    vagrant plugin install vagrant-scp
    echo "Starting first run, provisioning with: vagrant -up"
    echo "Please note: This operation will take some time..."
    vagrant up

    touch $FIRST_RUN_FLAG_FILE || true
    touch $PROVISIONED_FLAG_FILE || true
  fi
}

function provisionVms() {
  # First run & box update
  firstRun
  # validateMigrationStateExport

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
      vagrant up $vm --provision --no-parallel &
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