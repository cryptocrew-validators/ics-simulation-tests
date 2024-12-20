set -e

# Wait for spawn_time to be reached
function waitForSpawnTime() {
  if $PERMISSIONLESS ; then
    PROP_SPAWN_TIME=$(cat files/generated/create_consumer.json | jq -r '.initialization_parameters.spawn_time')
  else
    PROP_SPAWN_TIME=$(cat files/generated/prop.json | jq -r '.messages[0].content.spawn_time')
  fi
  
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

function configPeersConsumer() {
  echo "Configuring Consumer chain peers"
  PERSISTENT_PEERS_CONSUMER=""
  for i in $(seq 1 $NUM_VALIDATORS); do
    NODE_ID_CONSUMER="$(vagrant ssh consumer-chain-validator${i} -- $CONSUMER_APP --home $CONSUMER_HOME tendermint show-node-id)@192.168.33.2${i}:26656"
    PERSISTENT_PEERS_CONSUMER="${PERSISTENT_PEERS_CONSUMER},${NODE_ID_CONSUMER}"
  done
  PERSISTENT_PEERS_CONSUMER="${PERSISTENT_PEERS_CONSUMER:1}"
  echo '[consumer-chain] persistent_peers = "'$PERSISTENT_PEERS_CONSUMER'"'

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sed -i \"s/^persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_CONSUMER\\\"/g\" $CONSUMER_HOME/config/config.toml'"
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sed -i \"s/^addr_book_strict = .*/addr_book_strict = false/g\" $CONSUMER_HOME/config/config.toml'" 
  done
}

# Prepare consumer chain: copy private validator keys and finalizing genesis
function prepareConsumerChain() {
  echo "Preparing consumer chain..."

  configPeersConsumer

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
  CONSUMER_CCV_STATE=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME query provider consumer-genesis 0 -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "files/generated/ccv.json"

  # import module state
  echo "Importing testnet module state"
  MODULE_DIR="files/user/module_state"
  TARGET_FILE="files/generated/raw_genesis_consumer.json"
  for module_file in $MODULE_DIR/*.json; do
    module_name=$(basename "$module_file" .json)
    module_state=$(cat "$module_file" | jq -r --arg MODULE "$module_name" '.[$MODULE]')
    jq --argjson state "$module_state" --arg MODULE "$module_name" '.app_state[$MODULE] = $state' "$TARGET_FILE" | sponge "$TARGET_FILE"
    echo "-> added: $module_name"
  done
  echo "All modules have been updated in $TARGET_FILE."

  # Finalize consumer-chain genesis
  echo "Merging CCV state into raw_genesis state, enabling ccvconsumer.params"
  # jq --slurpfile new_ccvconsumer <(cat files/generated/ccv.json) '.app_state.ccvconsumer.params as $params | .app_state.ccvconsumer = ($new_ccvconsumer[0] | .params = $params)' files/generated/raw_genesis_consumer.json > files/generated/genesis_consumer.json
  
  jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' files/generated/raw_genesis_consumer.json files/generated/ccv.json > files/generated/genesis_consumer.json
  jq '.app_state.ccvconsumer.params.enabled = true' files/generated/genesis_consumer.json | sponge files/generated/genesis_consumer.json
  jq --arg denom "$CONSUMER_FEE_DENOM" '.app_state.ccvconsumer.params.reward_denoms = [$denom]' files/generated/genesis_consumer.json | sponge files/generated/genesis_consumer.json

  # Distribute consumer-chain genesis
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp files/generated/genesis_consumer.json consumer-chain-validator${i}:$CONSUMER_HOME/config/genesis.json
  done
}

# Starting consumer chain
function startConsumerChain() {
  echo ">>> STARTING CONSUMER CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh consumer-chain-validator${i} -- "$CONSUMER_APP --home $CONSUMER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --api.enable true --grpc.enable true --grpc.address 0.0.0.0:9090 --minimum-gas-prices 0$CONSUMER_FEE_DENOM > /var/log/chain.log 2>&1 &"
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

function prepareConsumerRawGenesis() {
  echo "Preparing Consumer genesis"
  if [ ! -f "files/user/genesis.json" ]; then
    # Download and manipulate consumer genesis file
    if [ ! -z "$CONSUMER_GENESIS_SOURCE" ]; then
      echo "Downloading consumer genesis file from $CONSUMER_GENESIS_SOURCE"
      wget -4 -q $CONSUMER_GENESIS_SOURCE -O files/generated/raw_genesis_consumer.json
    else
      echo "No Consumer genesis state provided, using default (init) state from consumer-chain-validator1"
      vagrant scp consumer-chain-validator1:$CONSUMER_HOME/config/genesis.json files/generated/raw_genesis_consumer.json
    fi
  else
    echo "Using provided genesis.json file at files/user/genesis.json"
    cp files/user/genesis.json files/generated/raw_genesis_consumer.json
  fi
}

function manipulateConsumerGenesis() {
  prepareConsumerRawGenesis

  echo "Manipulating consumer raw_genesis file"
  # cat files/generated/raw_genesis_consumer.json

  # Update supply to empty array to pass genesis supply check
  echo "Setting supply to []"
  jq '.app_state.bank.supply = []' files/generated/raw_genesis_consumer.json | sponge files/generated/raw_genesis_consumer.json

  # Update chain_id to consumer-chain
  echo "Setting chain_id: consumer-chain"
  jq --arg chainid "consumer-chain-1" '.chain_id = $chainid' files/generated/raw_genesis_consumer.json | sponge files/generated/raw_genesis_consumer.json
  
  # Update genesis_time to 1min in the past
  GENESIS_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))"')
  echo "Setting genesis time: $GENESIS_TIME" 
  jq --arg time "$GENESIS_TIME" '.genesis_time = $time' files/generated/raw_genesis_consumer.json | sponge files/generated/raw_genesis_consumer.json

  # Add relayer account and balances
  echo "Adding relayer account & balances"
  vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP keys delete relayer --keyring-backend test -y > /dev/null || true"
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
  jq '.app_state.auth.accounts += [input]' files/generated/raw_genesis_consumer.json files/generated/relayer_account_consumer.json > files/generated/raw_genesis_modified.json && mv files/generated/raw_genesis_modified.json files/generated/raw_genesis_consumer.json
  jq '.app_state.bank.balances += [input]' files/generated/raw_genesis_consumer.json files/generated/relayer_balance_consumer.json > files/generated/raw_genesis_modified.json && mv files/generated/raw_genesis_modified.json files/generated/raw_genesis_consumer.json
  rm files/generated/relayer_account_consumer.json files/generated/relayer_balance_consumer.json
}