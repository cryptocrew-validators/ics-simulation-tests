set -e

# Get peerlists for the sovereign chain
function configPeersSovereign() {
  PERSISTENT_PEERS_SOVEREIGN=""
  for i in $(seq 1 $NUM_VALIDATORS); do
    NODE_ID_CONSUMER="$(vagrant ssh consumer-chain-validator${i} -- $CONSUMER_APP --home $CONSUMER_HOME tendermint show-node-id)@192.168.33.2${i}:26656"
    PERSISTENT_PEERS_SOVEREIGN="${PERSISTENT_PEERS_SOVEREIGN},${NODE_ID_CONSUMER}"
  done
  PERSISTENT_PEERS_SOVEREIGN="${PERSISTENT_PEERS_SOVEREIGN:1}"
  echo '[sovereign-chain] persistent_peers = "'$PERSISTENT_PEERS_SOVEREIGN'"'

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sed -i \"s/persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_SOVEREIGN\\\"/g\" $CONSUMER_HOME/config/config.toml'"
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sed -i \"s/addr_book_strict = .*/addr_book_strict = false/g\" $CONSUMER_HOME/config/config.toml'"
  done
}

function distributeAuthority() {
    AUTHORITY_KEY=$(vagrant ssh consumer-chain-validator1 -- $CONSUMER_APP --home $CONSUMER_HOME keys show consumer-chain-validator1 -a --keyring-backend test)
    for i in $(seq 1 $NUM_VALIDATORS); do
      vagrant ssh consumer-chain-validator${i} -- "bash -c 'jq \".[\\\"app_state\\\"][\\\"ibc-authority\\\"][\\\"params\\\"].authority = \\\"$AUTHORITY_KEY\\\" | .[\\\"app_state\\\"][\\\"params\\\"].params.authority = \\\"$AUTHORITY_KEY\\\" | .[\\\"app_state\\\"][\\\"upgrade\\\"].params.authority = \\\"$AUTHORITY_KEY\\\"\" $CONSUMER_HOME/config/genesis.json | sponge $CONSUMER_HOME/config/genesis.json'"
      vagrant ssh consumer-chain-validator${i} -- "bash -c 'jq \".[\\\"app_state\\\"][\\\"tokenfactory\\\"][\\\"masterMinter\\\"].address = \\\"$AUTHORITY_KEY\\\" | .[\\\"app_state\\\"][\\\"tokenfactory\\\"][\\\"pauser\\\"].address = \\\"$AUTHORITY_KEY\\\" | .[\\\"app_state\\\"][\\\"tokenfactory\\\"][\\\"blacklister\\\"].address = \\\"$AUTHORITY_KEY\\\" | .[\\\"app_state\\\"][\\\"tokenfactors\\\"][\\\"owner\\\"].address = \\\"$AUTHORITY_KEY\\\"\" $CONSUMER_HOME/config/genesis.json | sponge $CONSUMER_HOME/config/genesis.json'"
    done
}


# Start all virtual machines, collect gentxs & start sovereign chain
function startSovereignChain() {
  sleep 1
  echo "Preparing sovereign-chain with $NUM_VALIDATORS validators."
  echo "Getting peerlists, editing configs..."
  configPeersSovereign
  
  # Copy gentxs to the first validator of sovereign chain, collect gentxs
  echo "Copying gentxs to sovereign-chain-validator1..."
  VAL_ACCOUNTS_SOVEREIGN=()
  for i in $(seq 2 $NUM_VALIDATORS); do
    GENTX_FILENAME=$(vagrant ssh consumer-chain-validator${i} -- "bash -c 'ls $CONSUMER_HOME/config/gentx/ | head -n 1'")
    vagrant scp consumer-chain-validator${i}:$CONSUMER_HOME/config/gentx/$GENTX_FILENAME files/generated/gentx_sovereign${i}.json
    vagrant scp files/generated/gentx_sovereign${i}.json consumer-chain-validator1:$CONSUMER_HOME/config/gentx/gentx${i}.json
    
    ACCOUNT=$(cat files/generated/gentx_sovereign${i}.json | jq -r '.body.messages[0].delegator_address')
    VAL_ACCOUNTS_SOVEREIGN+=($ACCOUNT)
    echo "[consumer-chain-validator${i}] ${VAL_ACCOUNTS_SOVEREIGN[i-2]} (account: consumer-chain-validator${i})"
  done

  # Check if genesis accounts have already been added, if not: collect gentxs
  GENESIS_JSON=$(vagrant ssh consumer-chain-validator1 -- cat $CONSUMER_HOME/config/genesis.json)
  if [[ ! "$GENESIS_JSON" == *"${VAL_ACCOUNTS_SOVEREIGN[0]}"* ]] ; then
    echo "Adding genesis accounts..."

    # Add validator accounts & relayer account
    RELAYER_ACCOUNT_CONSUMER=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --json keys list --chain consumer-chain | grep result | jq -r '.result.default.account'")
    echo "Consumer relayer account: $RELAYER_ACCOUNT_CONSUMER"
    vagrant ssh consumer-chain-validator1 -- $CONSUMER_APP --home $CONSUMER_HOME add-genesis-account $RELAYER_ACCOUNT_CONSUMER 1500000000000"$CONSUMER_FEE_DENOM" --keyring-backend test
    
    for i in $(seq 2 $NUM_VALIDATORS); do
      echo ${VAL_ACCOUNTS_SOVEREIGN[i-2]}
      vagrant ssh consumer-chain-validator1 -- $CONSUMER_APP --home $CONSUMER_HOME add-genesis-account ${VAL_ACCOUNTS_SOVEREIGN[i-2]} 1500000000000"$CONSUMER_FEE_DENOM" --keyring-backend test
    done
  
    # Collect gentxs & finalize provider-chain genesis
    echo "Collecting gentxs on consumer-chain-validator1"
    vagrant ssh consumer-chain-validator1 -- $CONSUMER_APP --home $CONSUMER_HOME collect-gentxs
  fi

  # Distribute sovereign genesis
  echo "Distributing sovereign-chain genesis file..."
  vagrant scp consumer-chain-validator1:$CONSUMER_HOME/config/genesis.json files/generated/genesis_sovereign.json
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp files/generated/genesis_sovereign.json consumer-chain-validator${i}:$CONSUMER_HOME/config/genesis.json
  done
  
  echo ">>> STARTING SOVEREIGN CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/sovereign.log && sudo chmod 666 /var/log/sovereign.log"
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/consumer.log && sudo chmod 666 /var/log/consumer.log"
    vagrant ssh consumer-chain-validator${i} -- "$CONSUMER_APP --home $CONSUMER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --grpc.address 0.0.0.0:9090> /var/log/sovereign.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/sovereign.log"
  done
}

# Wait for sovereign to finalize a block
function waitForSovereignChain() {
  echo "Waiting for Sovereign Chain to finalize a block..."
  SOVEREIGN_LATEST_HEIGHT=""
  while [[ ! $SOVEREIGN_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $SOVEREIGN_LATEST_HEIGHT -lt 1 ]]; do
    SOVEREIGN_LATEST_HEIGHT=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
  done
  echo ">>> SOVEREIGN CHAIN successfully launched. Latest block height: $SOVEREIGN_LATEST_HEIGHT"
}

# Wait for spawn_time to be reached
function waitForSpawnTime() {
  PROP_SPAWN_TIME=$(cat files/generated/consumer_addition_proposal.json | jq -r '.spawn_time')
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