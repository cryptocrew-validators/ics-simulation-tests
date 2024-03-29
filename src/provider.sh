set -e

# Get peerlists for both provider and consumer chain, edit config
function configPeers() {
  PERSISTENT_PEERS_PROVIDER=""
  PERSISTENT_PEERS_CONSUMER=""
  for i in $(seq 1 $NUM_VALIDATORS); do
    NODE_ID_PROVIDER="$(vagrant ssh provider-chain-validator${i} -- $PROVIDER_APP --home $PROVIDER_HOME tendermint show-node-id)@192.168.33.1${i}:26656"
    NODE_ID_CONSUMER="$(vagrant ssh consumer-chain-validator${i} -- $CONSUMER_APP --home $CONSUMER_HOME tendermint show-node-id)@192.168.33.2${i}:26656"
    PERSISTENT_PEERS_PROVIDER="${PERSISTENT_PEERS_PROVIDER},${NODE_ID_PROVIDER}"
    PERSISTENT_PEERS_CONSUMER="${PERSISTENT_PEERS_CONSUMER},${NODE_ID_CONSUMER}"
  done
  PERSISTENT_PEERS_PROVIDER="${PERSISTENT_PEERS_PROVIDER:1}"
  PERSISTENT_PEERS_CONSUMER="${PERSISTENT_PEERS_CONSUMER:1}"
  echo '[provider-chain] persistent_peers = "'$PERSISTENT_PEERS_PROVIDER'"'
  echo '[consumer-chain] persistent_peers = "'$PERSISTENT_PEERS_CONSUMER'"'

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh provider-chain-validator${i} -- "bash -c 'sed -i \"s/persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_PROVIDER\\\"/g\" $PROVIDER_HOME/config/config.toml'"
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sed -i \"s/persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_CONSUMER\\\"/g\" $CONSUMER_HOME/config/config.toml'"
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
  if [[ ! "$GENESIS_JSON" == *"${VAL_ACCOUNTS[1]}"* ]] ; then
    echo "Adding genesis accounts..."

    # Add validator accounts & relayer account
    for i in $(seq 2 $NUM_VALIDATORS); do
      echo ${VAL_ACCOUNTS[i-2]}
      vagrant ssh provider-chain-validator1 -- $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account ${VAL_ACCOUNTS[i-2]} 1500000000000icsstake --keyring-backend test
    done
    vagrant ssh provider-chain-validator1 -- $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account cosmos1l7hrk5smvnatux7fsutvc0zldj3z8gawhd7ex7 1500000000000icsstake --keyring-backend test

    # Collect gentxs & finalize provider-chain genesis
    echo "Collecting gentxs on provider-chain-validator1"
    vagrant ssh provider-chain-validator1 -- $PROVIDER_APP --home $PROVIDER_HOME collect-gentxs
  fi

  # Distribute provider genesis
  echo "Distributing provider-chain genesis file..."
  vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/genesis.json files/generated/genesis_provider.json
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp files/generated/genesis_provider.json provider-chain-validator${i}:$PROVIDER_HOME/config/genesis.json
  done
  
  echo ">>> STARTING PROVIDER CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh provider-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh provider-chain-validator${i} -- "$PROVIDER_APP --home $PROVIDER_HOME start --log_level $CHAIN_LOG_LEVEL --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 > /var/log/chain.log 2>&1 &"
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
    TEST_PROVIDER_LAUNCH="false"
  else
    echo ">>> PROVIDER CHAIN successfully launched. Latest block height: $PROVIDER_LATEST_HEIGHT"
    TEST_PROVIDER_LAUNCH="true"
  fi
}