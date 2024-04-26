set -e

# Wait for spawn_time to be reached
function waitForSpawnTime() {
  PROP_SPAWN_TIME=$(cat prop.json | jq -r '.messages[0].content.spawn_time')
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
    vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/priv_validator_key.json files/generated/priv_validator_key1.json
    vagrant scp files/generated/priv_validator_key1.json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json
  fi

  # Copy all other keys
  for i in $(seq 2 $NUM_VALIDATORS); do
    echo "Copying ORIGINAL private validator keys from provider-chain-validator${i} to consumer-chain-validator${i}..."
    vagrant scp provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json files/generated/priv_validator_key${i}.json
    vagrant scp files/generated/priv_validator_key${i}.json consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json
  done
  
  # Query CCV consumer state on provider-chain-validator1
  echo "Querying CCV consumer state on provider-chain-validator1 and finalizing consumer-chain genesis.json..."
  CONSUMER_CCV_STATE=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "files/generated/ccv.json"

  # Finalize consumer-chain genesis
  # jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' raw_genesis.json ccv.json > final_genesis.json
  jq --slurpfile new_ccvconsumer <(cat files/generated/ccv.json) '.app_state.ccvconsumer.params as $params | .app_state.ccvconsumer = ($new_ccvconsumer[0] | .params = $params)' files/downloads/raw_genesis.json > files/generated/final_genesis.json
  
  # Distribute consumer-chain genesis
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp files/generated/final_genesis.json consumer-chain-validator${i}:$CONSUMER_HOME/config/genesis.json
  done
}

# Starting consumer chain
function startConsumerChain() {
  echo ">>> STARTING CONSUMER CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh consumer-chain-validator${i} -- "$CONSUMER_APP --home $CONSUMER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --api.enable true --grpc.enable true --grpc.address "0.0.0.0:9090" > /var/log/chain.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/chain.log"
  done
}

# Wait for consumer to finalize a block
function waitForConsumerChain() {
  echo "Waiting for Consumer Chain to finalize a block..."

  MAX_ITERATIONS=30
  ITERATION=0
  CONSUMER_LATEST_HEIGHT=""

  while [[ ! $CONSUMER_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $CONSUMER_LATEST_HEIGHT -lt 1 ]] && [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    CONSUMER_LATEST_HEIGHT=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
    ITERATION=$((ITERATION+1))
  done
  
  if [[ $ITERATION -eq $MAX_ITERATIONS ]]; then
    echo ">>> CONSUMER CHAIN launch failed. Max iterations reached."
    TEST_CONSUMER_LAUNCH="false"
  else
    echo ">>> CONSUMER CHAIN successfully launched. Latest block height: $CONSUMER_LATEST_HEIGHT"
    TEST_CONSUMER_LAUNCH="true"
  fi
}

function manipulateConsumerGenesis() {
  echo "Manipulating consumer raw_genesis file"

  if [ ! -f "files/user/genesis.json" ]; then
    # Download and manipulate consumer genesis file
    echo "Downloading consumer genesis file from $CONSUMER_GENESIS_SOURCE"
    wget -4 -q $CONSUMER_GENESIS_SOURCE -O files/downloads/raw_genesis.json
  else
    cp files/user/genesis.json files/downloads/raw_genesis.json
    echo "Using local genesis.json file"
  fi

  # Update supply to empty array to pass genesis supply check
  echo "Setting supply to []"
  jq '.app_state.bank.supply = []' files/downloads/raw_genesis.json | sponge files/downloads/raw_genesis.json

  # Update chain_id to consumer-chain
  echo "Setting chain_id: consumer-chain"
  jq --arg chainid "consumer-chain" '.chain_id = $chainid' files/downloads/raw_genesis.json | sponge files/downloads/raw_genesis.json
  
  # Update genesis_time to 1min in the past
  GENESIS_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))"')
  echo "Setting genesis time: $GENESIS_TIME" 
  jq --arg time "$GENESIS_TIME" '.genesis_time = $time' files/downloads/raw_genesis.json | sponge files/downloads/raw_genesis.json

  # Add relayer account and balances
  echo "Adding relayer account & balances"
  #vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP keys delete relayer --keyring-backend test -y || true"
  CONSUMER_RELAYER_ACCOUNT_ADDRESS=$(vagrant ssh consumer-chain-validator1 -- "echo "$RELAYER_MNEMONIC" | $CONSUMER_APP keys add relayer --recover --keyring-backend test --output json")
  
  cat > files/generated/relayer_account_consumer.json <<EOT
{
  "@type": "/cosmos.auth.v1beta1.BaseAccount",
  "address": "$(echo $CONSUMER_RELAYER_ACCOUNT_ADDRESS | jq -r '.address')",
  "pub_key": null,
  "account_number": "1",
  "sequence": "0"
}
EOT

  cat > files/generated/relayer_balance_consumer.json <<EOT
{
  "address": "$(echo $CONSUMER_RELAYER_ACCOUNT_ADDRESS | jq -r '.address')",
  "coins": [
    {
      "denom": "$CONSUMER_FEE_DENOM",
      "amount": "150000000"
    }
  ]
}
EOT



  cat files/generated/relayer_account_consumer.json
  cat files/generated/relayer_balance_consumer.json
  jq '.app_state.auth.accounts += [input]' files/downloads/raw_genesis.json files/generated/relayer_account_consumer.json > files/generated/raw_genesis_modified.json && mv files/generated/raw_genesis_modified.json files/downloads/raw_genesis.json
  jq '.app_state.bank.balances += [input]' files/downloads/raw_genesis.json files/generated/relayer_balance_consumer.json > files/generated/raw_genesis_modified.json && mv files/generated/raw_genesis_modified.json files/downloads/raw_genesis.json
  rm files/generated/relayer_account_consumer.json files/generated/relayer_balance_consumer.json
}