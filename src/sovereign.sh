set -e

# Get peerlists for the sovereign chain
function configPeersSovereign() {
  PERSISTENT_PEERS_SOVEREIGN=""
  for i in $(seq 1 $NUM_VALIDATORS); do
    NODE_ID_CONSUMER="$(vagrant ssh consumer-chain-validator${i} -- $CONSUMER_APP --home $CONSUMER_HOME tendermint show-node-id)@192.168.57.1${i}:26656"
    PERSISTENT_PEERS_SOVEREIGN="${PERSISTENT_PEERS_SOVEREIGN},${NODE_ID_CONSUMER}"
  done
  PERSISTENT_PEERS_SOVEREIGN="${PERSISTENT_PEERS_SOVEREIGN:1}"
  echo '[sovereign-chain] persistent_peers = "'$PERSISTENT_PEERS_SOVEREIGN'"'

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sed -i \"s/persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_SOVEREIGN\\\"/g\" $CONSUMER_HOME/config/config.toml'"
  done

  #Set grpc interface 
  #vagrant ssh consumer-chain-validator1 -- "bash -c 'sed -i\".bak\" \"/\\[grpc]/!b;n;c\\\\address = \\\"0.0.0.0:9090\\\"\" $CONSUMER_HOME/config/app.toml'"

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
    vagrant scp consumer-chain-validator${i}:$CONSUMER_HOME/config/gentx/$GENTX_FILENAME gentx${i}.json
    vagrant scp gentx${i}.json consumer-chain-validator1:$CONSUMER_HOME/config/gentx/gentx${i}.json
    
    ACCOUNT=$(cat gentx${i}.json | jq -r '.body.messages[0].delegator_address')
    VAL_ACCOUNTS_SOVEREIGN+=($ACCOUNT)
    echo "[consumer-chain-validator${i}] ${VAL_ACCOUNTS_SOVEREIGN[i-2]} (account: consumer-chain-validator${i})"
  done

  # Check if genesis accounts have already been added, if not: collect gentxs
  GENESIS_JSON=$(vagrant ssh consumer-chain-validator1 -- cat $CONSUMER_HOME/config/genesis.json)
  if [[ ! "$GENESIS_JSON" == *"${VAL_ACCOUNTS_SOVEREIGN[0]}"* ]] ; then
    echo "Adding genesis accounts..."

    # Add validator accounts & relayer account
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
  vagrant scp consumer-chain-validator1:$CONSUMER_HOME/config/genesis.json genesis.json
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp genesis.json consumer-chain-validator${i}:$CONSUMER_HOME/config/genesis.json
  done
  
  echo ">>> STARTING SOVEREIGN CHAIN"
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh consumer-chain-validator${i} -- "$CONSUMER_APP --home $CONSUMER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --grpc.address 0.0.0.0:9090> /var/log/chain.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/chain.log"
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