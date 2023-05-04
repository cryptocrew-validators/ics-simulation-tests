# Wait for spawn_time to be reached
function waitForSpawnTime() {
  PROP_SPAWN_TIME=$(cat prop.json | jq -r '.spawn_time')
  echo "Waiting for spawn time to be reached: $PROP_SPAWN_TIME"
  CURRENT_TIME=$(vagrant ssh provider-chain-validator1 -- "date -u '+%Y-%m-%dT%H:%M:%SZ'")
  CURRENT_TIME_SECONDS=$(date -d "$CURRENT_TIME" +%s)
  SPAWN_TIME_SECONDS=$(date -d "$PROP_SPAWN_TIME" +%s)
  REMAINING_SECONDS=$((SPAWN_TIME_SECONDS - CURRENT_TIME_SECONDS))
  echo "ETA: $REMAINING_SECONDS seconds..."
  
  while true; do
    CURRENT_TIME=$(vagrant ssh provider-chain-validator1 -- "date -u '+%Y-%m-%dT%H:%M:%SZ'")
    if [[ "$CURRENT_TIME" > "$PROP_SPAWN_TIME" ]]; then
      break
    fi
    sleep 5
  done
  
  echo "Spawn time reached!"
}

# Prepare consumer chain: copy private validator keys and finalizing genesis
function prepareConsumerChain() {
  echo "Preparing consumer chain..."

  # Check if we also need to include provider-chain-validat1 key, or if a KeyAssignment test has been run before (key has already been copied in this case)
  TMP_DIR_EXISTS=$(vagrant ssh provider-chain-validator1 -- "[ -d /home/vagrant/tmp ] && echo 'tmp directory exists' || echo 'tmp directory does not exist'")
  if [[ "$TMP_DIR_EXISTS" == *"does not exist"* ]]; then
  echo "Copying ORIGINAL private validator keys from provider-chain-validator1 to consumer-chain-validator1..."
    vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/priv_validator_key.json priv_validator_key1.json
    vagrant scp priv_validator_key1.json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json
  fi

  # Copy all other keys
  for i in $(seq 2 $NUM_VALIDATORS); do
    echo "Copying ORIGINAL private validator keys from provider-chain-validator${i} to consumer-chain-validator${i}..."
    vagrant scp provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json priv_validator_key${i}.json
    vagrant scp priv_validator_key${i}.json consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json
    rm "priv_validator_key${i}.json" 
  done
  
  # Query CCV consumer state on provider-chain-validator1
  echo "Querying CCV consumer state on provider-chain-validator1 and finalizing consumer-chain genesis.json..."
  CONSUMER_CCV_STATE=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "ccv.json"

  # Finalize consumer-chain genesis
  jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' raw_genesis.json ccv.json > final_genesis.json
  
  if [[ "$PROVIDER_VERSION" == *"v9.0"* ]]; then
  # # FIX: soft_opt_out_threshold gets lost / isn't returned by gaiad
    echo "Gaiad version <= v9.0.3: Appending `soft_opt_out_threshold` to final_genesis ccvconsumer.params."
    jq '.app_state.ccvconsumer.params |= . + {"soft_opt_out_threshold": "0.05"}' final_genesis.json > final_genesis_with_threshold.json
    mv final_genesis_with_threshold.json final_genesis.json
  fi

  # Distribute consumer-chain genesis
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp final_genesis.json consumer-chain-validator${i}:$CONSUMER_HOME/config/genesis.json
  done
}

# Start consumer-chain
function startConsumerChain() {
  echo ">> STARTING CONSUMER CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh consumer-chain-validator${i} -- "sudo $CONSUMER_APP --home $CONSUMER_HOME start --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 > /var/log/chain.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/chain.log"
  done
}

# Wait for consumer-chain
function waitForConsumerChain() {
  echo "Waiting for the consumer chain to launch..."
  CONSUMER_LATEST_HEIGHT=""
  while [[ ! $CONSUMER_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $CONSUMER_LATEST_HEIGHT -lt 2 ]]; do
    CONSUMER_LATEST_HEIGHT=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
  done
  echo ">> CONSUMER CHAIN successfully launched. Latest block height: $PROVIDER_LATEST_HEIGHT"
}