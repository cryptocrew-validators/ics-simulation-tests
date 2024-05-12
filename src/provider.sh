set -e

# Get peerlists for both provider and consumer chain, edit config
function configPeers() {
  PERSISTENT_PEERS_PROVIDER=""
  for i in $(seq 1 $NUM_VALIDATORS); do
    NODE_ID_PROVIDER="$(vagrant ssh provider-chain-validator${i} -- $PROVIDER_APP --home $PROVIDER_HOME tendermint show-node-id)@192.168.33.1${i}:26656"
    PERSISTENT_PEERS_PROVIDER="${PERSISTENT_PEERS_PROVIDER},${NODE_ID_PROVIDER}"
  done
  PERSISTENT_PEERS_PROVIDER="${PERSISTENT_PEERS_PROVIDER:1}"
  echo '[provider-chain] persistent_peers = "'$PERSISTENT_PEERS_PROVIDER'"'

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh provider-chain-validator${i} -- "bash -c 'sed -i \"s/^persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_PROVIDER\\\"/g\" $PROVIDER_HOME/config/config.toml'"
    vagrant ssh provider-chain-validator${i} -- "bash -c 'sed -i \"s/^addr_book_strict = .*/addr_book_strict = false/g\" $PROVIDER_HOME/config/config.toml'"
  done
}

# Start all virtual machines, collect gentxs & start provider chain
function startProviderChain() {
  sleep 1
  echo "Preparing provider-chain with $NUM_VALIDATORS validators."
  echo "Getting peerlists, editing configs..."
  configPeers
  
  # Copy gentxs to the first validator of provider chain, collect gentxs
  echo "Copying gentxs to provider-chain-validator1..."
  VAL_ACCOUNTS=()
  for i in $(seq 2 $NUM_VALIDATORS); do
    GENTX_FILENAME=$(vagrant ssh provider-chain-validator${i} -- "bash -c 'ls $PROVIDER_HOME/config/gentx/ | head -n 1'")
    vagrant scp provider-chain-validator${i}:$PROVIDER_HOME/config/gentx/$GENTX_FILENAME files/generated/gentx_provider${i}.json
    vagrant scp files/generated/gentx_provider${i}.json provider-chain-validator1:$PROVIDER_HOME/config/gentx/gentx${i}.json
    
    ACCOUNT=$(cat files/generated/gentx_provider${i}.json | jq -r '.body.messages[0].delegator_address')
    VAL_ACCOUNTS+=($ACCOUNT)
    echo "[provider-chain-validator${i}] ${VAL_ACCOUNTS[i-2]} (account: provider-chain-validator${i})"
  done

  # Check if genesis accounts have already been added, if not: collect gentxs
  GENESIS_JSON=$(vagrant ssh provider-chain-validator1 -- cat $PROVIDER_HOME/config/genesis.json)
  # if [[ ! "$GENESIS_JSON" == *"${VAL_ACCOUNTS[1]}"* ]] ; then
    echo "Adding genesis accounts..."

    # Add validator accounts & relayer account
    for i in $(seq 2 $NUM_VALIDATORS); do
      echo ${VAL_ACCOUNTS[i-2]}
      vagrant ssh provider-chain-validator1 -- $PROVIDER_APP --home $PROVIDER_HOME genesis add-genesis-account ${VAL_ACCOUNTS[i-2]} 1500000000000icsstake --keyring-backend test || true
    done
    vagrant ssh provider-chain-validator1 -- $PROVIDER_APP --home $PROVIDER_HOME genesis add-genesis-account cosmos1l7hrk5smvnatux7fsutvc0zldj3z8gawhd7ex7 1500000000000icsstake --keyring-backend test || true

    # Collect gentxs & finalize provider-chain genesis
    echo "Collecting gentxs on provider-chain-validator1"
    vagrant ssh provider-chain-validator1 -- $PROVIDER_APP --home $PROVIDER_HOME genesis collect-gentxs || true
  # fi

  # Set blocks_per_epoch to 5 for testing purposes
  vagrant ssh provider-chain-validator1 -- "jq '.app_state.provider.params.blocks_per_epoch = \"5\"' $PROVIDER_HOME/config/genesis.json | sponge $PROVIDER_HOME/config/genesis.json"
  
  # Distribute provider genesis
  echo "Distributing provider-chain genesis file..."
  vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/genesis.json files/generated/genesis_provider.json
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp files/generated/genesis_provider.json provider-chain-validator${i}:$PROVIDER_HOME/config/genesis.json
  done
  
  echo ">>> STARTING PROVIDER CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh provider-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh provider-chain-validator${i} -- "$PROVIDER_APP --home $PROVIDER_HOME start --log_level $CHAIN_LOG_LEVEL --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --grpc.enable true --grpc.address 0.0.0.0:9090 --minimum-gas-prices 0icsstake > /var/log/chain.log 2>&1 &"
    echo "[provider-chain-validator${i}] started $PROVIDER_APP: watch output at /var/log/chain.log"
  done
  echo "Done starting provider chain"
}

# Wait for the provider chain to finalize a block
function waitForProviderChain() {
  echo "Waiting for provider chain to finalize a block..."

  MAX_ITERATIONS=30
  ITERATION=0
  PROVIDER_LATEST_HEIGHT=""

  while [[ ! $PROVIDER_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $PROVIDER_LATEST_HEIGHT -lt 1 ]] && [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    PROVIDER_LATEST_HEIGHT=$(vagrant ssh provider-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
    ITERATION=$((ITERATION+1))
  done

  if [[ $ITERATION -eq $MAX_ITERATIONS ]]; then
    echo ">>> PROVIDER CHAIN launch failed. Max iterations reached."
    echo "exiting"
    TEST_PROVIDER_LAUNCH="false"
    exit 1
  else
    echo ">>> PROVIDER CHAIN successfully launched. Latest block height: $PROVIDER_LATEST_HEIGHT"
    TEST_PROVIDER_LAUNCH="true"
  fi
}