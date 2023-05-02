#!/bin/bash

# node logs piped to /var/logs/chain.log

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 0.25icsstake --keyring-backend test -y"
RELAYER_MNEMONIC="genre inch matrix flag bachelor random spawn course abandon climb negative cake slow damp expect decide return acoustic furnace pole humor giraffe group poem"

set -e

if ! (command -v sponge > /dev/null 2>&1); then
  echo "moreutils needs to be installed! run: apt install moreutils"
  exit 1
fi

# Load environment variables from .env file
function loadEnv {
  if test -f .env ; then 
    ENV=$(realpath .env)
    export $(grep "^[^#;]" $ENV | xargs)
    echo "loaded configuration from ENV file: $ENV"
  else
    echo "ENV file not found at .env"
    exit 1
  fi
}

# Determine desktop environment
function get_terminal_command() {
  local desktop_env
  desktop_env="$(echo $XDG_CURRENT_DESKTOP | tr '[:upper:]' '[:lower:]')"

  case $desktop_env in
    *gnome*)
      echo "gnome-terminal --"
      ;;
    *)
      echo "xterm -e"
      ;;
  esac
}

# Get peerlists for both provider and consumer chain, edit config
function configPeers() {
  PERSISTENT_PEERS_PROVIDER=""
  PERSISTENT_PEERS_CONSUMER=""
  for i in {1..3}; do
    NODE_ID_PROVIDER="$(vagrant ssh provider-chain-validator${i} -- sudo $PROVIDER_APP --home $PROVIDER_HOME tendermint show-node-id)@192.168.33.1${i}:26656"
    NODE_ID_CONSUMER="$(vagrant ssh consumer-chain-validator${i} -- sudo $CONSUMER_APP --home $CONSUMER_HOME tendermint show-node-id)@192.168.34.1${i}:26656"
    PERSISTENT_PEERS_PROVIDER="${PERSISTENT_PEERS_PROVIDER},${NODE_ID_PROVIDER}"
    PERSISTENT_PEERS_CONSUMER="${PERSISTENT_PEERS_CONSUMER},${NODE_ID_CONSUMER}"
  done
  PERSISTENT_PEERS_PROVIDER="${PERSISTENT_PEERS_PROVIDER:1}"
  PERSISTENT_PEERS_CONSUMER="${PERSISTENT_PEERS_CONSUMER:1}"
  echo '[provider-chain] persistent_peers = "'$PERSISTENT_PEERS_PROVIDER'"'
  echo '[consumer-chain] persistent_peers = "'$PERSISTENT_PEERS_CONSUMER'"'

  for i in {1..3}; do
    vagrant ssh provider-chain-validator${i} -- "bash -c 'sudo sed -i \"s/persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_PROVIDER\\\"/g\" $PROVIDER_HOME/config/config.toml'"
    vagrant ssh consumer-chain-validator${i} -- "bash -c 'sudo sed -i \"s/persistent_peers = .*/persistent_peers = \\\"$PERSISTENT_PEERS_CONSUMER\\\"/g\" $CONSUMER_HOME/config/config.toml'"
  done
}

# Start all virtual machines, collect gentxs & start provider chain
function startProviderChain() {
  echo "Starting vagrant VMs"
  vagrant plugin install vagrant-scp
  vagrant up

  sleep 1
  echo "Getting peerlists, editing configs..."
  configPeers
  
  # Copy gentxs to the first validator of provider chain, collect gentxs
  echo "Copying gentxs to provider-chain-validator1..."
  GENTX2_FILENAME=$(vagrant ssh provider-chain-validator2 -- "bash -c 'sudo ls $PROVIDER_HOME/config/gentx/ | head -n 1'")
  GENTX3_FILENAME=$(vagrant ssh provider-chain-validator3 -- "bash -c 'sudo ls $PROVIDER_HOME/config/gentx/ | head -n 1'")
  vagrant scp provider-chain-validator2:$PROVIDER_HOME/config/gentx/$GENTX2_FILENAME gentx2.json
  vagrant scp gentx2.json provider-chain-validator1:$PROVIDER_HOME/config/gentx/gentx2.json
  vagrant scp provider-chain-validator3:$PROVIDER_HOME/config/gentx/$GENTX3_FILENAME gentx3.json
  vagrant scp gentx3.json provider-chain-validator1:$PROVIDER_HOME/config/gentx/gentx3.json

  VAL_ACCOUNT2=$(cat gentx2.json | jq -r '.body.messages[0].delegator_address')
  VAL_ACCOUNT3=$(cat gentx3.json | jq -r '.body.messages[0].delegator_address')

  rm gentx2.json gentx3.json

  # Check if genesis accounts have already been added, if not: collect gentxs
  GENESIS_JSON=$(vagrant ssh provider-chain-validator1 -- sudo cat $PROVIDER_HOME/config/genesis.json)
  if [[ ! "$GENESIS_JSON" == *"$VAL_ACCOUNT2"* ]] ; then
    echo "Adding genesis accounts..."
    # Add validator accounts & relayer account
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account $VAL_ACCOUNT2 1500000000000icsstake --keyring-backend test
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account $VAL_ACCOUNT3 1500000000000icsstake --keyring-backend test
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account cosmos1l7hrk5smvnatux7fsutvc0zldj3z8gawhd7ex7 1500000000000icsstake --keyring-backend test
    
    # Collect gentxs & finalize provider-chain genesis
    echo "Collecting gentxs on provider-chain-validator1"
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME collect-gentxs
  fi

  # Distribute genesis file from the first validator to validators 2 and 3
  echo "Distributing genesis file from provider-chain-validator1 to provider-chain-validator2 and provider-chain-validator3"
  vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/genesis.json genesis.json
  vagrant scp genesis.json provider-chain-validator2:$PROVIDER_HOME/config/genesis.json
  vagrant scp genesis.json provider-chain-validator3:$PROVIDER_HOME/config/genesis.json 
  
  echo ">> STARTING PROVIDER CHAIN"
  for i in {1..3} ; do 
    vagrant ssh provider-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh provider-chain-validator${i} -- "sudo $PROVIDER_APP --home $PROVIDER_HOME start --rpc.laddr tcp://0.0.0.0:26657 --rpc.grpc_laddr tcp://0.0.0.0:9099 > /var/log/chain.log 2>&1 &"
    echo "[provider-chain-validator${i}] started $PROVIDER_APP: watch output at /var/log/chain.log"
  done
}

# Wait for provider to finalize a block
function waitForProviderChain() {
  echo "Waiting for Provider Chain to finalize a block..."
  PROVIDER_LATEST_HEIGHT=""
  while [[ ! $PROVIDER_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $PROVIDER_LATEST_HEIGHT -lt 1 ]]; do
    PROVIDER_LATEST_HEIGHT=$(vagrant ssh provider-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
  done
  echo ">> PROVIDER CHAIN successfully launched. Latest block height: $PROVIDER_LATEST_HEIGHT"
}

# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {
  
  # Prepare proposal file
  echo "Preparing consumer addition proposal..."

  # Download and manipulate consumer genesis file
  echo "Downloading consumer genesis file"
  wget -4 $CONSUMER_GENESIS_SOURCE -O raw_genesis.json

  echo "Setting supply to []"
  jq '.app_state.bank.supply = []' raw_genesis.json | sponge raw_genesis.json

  echo "Setting chain_id: consumer-chain"
  jq --arg chainid "consumer-chain" '.chain_id = $chainid' raw_genesis.json | sponge raw_genesis.json
  
  GENESIS_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))")
  echo "Setting genesis time: $GENESIS_TIME" 
  jq --arg time "$GENESIS_TIME" '.genesis_time = $time' raw_genesis.json | sponge raw_genesis.json

  echo "Adding relayer account & balances"
  vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP keys delete relayer --keyring-backend test -y || true"
  CONSUMER_RELAYER_ACCOUNT_ADDRESS=$(vagrant ssh consumer-chain-validator1 -- "echo "$RELAYER_MNEMONIC" | $CONSUMER_APP keys add relayer --recover --keyring-backend test --output json")
  cat > relayer_account_consumer.json <<EOT
{
  "@type": "/cosmos.auth.v1beta1.BaseAccount",
  "address": "$(echo $CONSUMER_RELAYER_ACCOUNT_ADDRESS | jq -r '.address')",
  "pub_key": null,
  "account_number": "1",
  "sequence": "0"
}
EOT
  cat > relayer_balance_consumer.json <<EOT
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
  cat relayer_account_consumer.json
  cat relayer_balance_consumer.json
  jq '.app_state.auth.accounts += [input]' raw_genesis.json relayer_account_consumer.json > raw_genesis_modified.json && mv raw_genesis_modified.json raw_genesis.json
  jq '.app_state.bank.balances += [input]' raw_genesis.json relayer_balance_consumer.json > raw_genesis_modified.json && mv raw_genesis_modified.json raw_genesis.json
  rm relayer_account_consumer.json relayer_balance_consumer.json

  CONSUMER_BINARY_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sudo sha256sum /usr/local/bin/$CONSUMER_APP" | awk '{ print $1 }')
  echo "Consumer binary sha256: $CONSUMER_BINARY_SHA256"
  CONSUMER_RAW_GENESIS_SHA256=$(sha256sum raw_genesis.json | awk '{ print $1 }')
  echo "Consumer genesis sha256: $CONSUMER_RAW_GENESIS_SHA256"
  SPAWN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))") # leave 120 sec for pre-spawtime key-assignment test
  echo "Consumer spawn time: $SPAWN_TIME"
  cat > prop.json <<EOT
{
  "title": "Create the Consumer chain",
  "description": "This is the proposal to create the consumer chain \"consumer-chain\".",
  "chain_id": "consumer-chain",
  "initial_height": {
      "revision_height": 1
  },
  "genesis_hash": "$CONSUMER_BINARY_SHA256",
  "binary_hash": "$CONSUMER_RAW_GENESIS_SHA256",
  "spawn_time": "$SPAWN_TIME",
  "consumer_redistribution_fraction": "0.75",
  "blocks_per_distribution_transmission": 150,
  "historical_entries": 10,
  "ccv_timeout_period": 2419200,
  "transfer_timeout_period": 600,
  "unbonding_period": 1728000, 
  "deposit": "10000000icsstake"
}
EOT
  cat prop.json
  vagrant scp prop.json provider-chain-validator1:/home/vagrant/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal consumer-addition /home/vagrant/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS"
  echo "Consumer addition proposal submitted"
}

# Vote yes on the consumer addition proposal from all provider validators
function voteConsumerAdditionProposal() {
  echo "Waiting for consumer addition proposal to go live..."
  sleep 7

  for i in {1..3} ; do 
    echo "Voting 'yes' from provider-chain-validator${i}..."
    vagrant ssh provider-chain-validator${i} -- "sudo $PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS"
  done
}

function waitForProposal() {
  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done

  echo "Consumer addition proposal passed"

  echo "Waiting 1 block for everything to be propagated..."
  sleep 6
}

function testKeyAssignment() {
  if [[ "$1" == *"newkey"* ]]; then
    echo "Generating NEW key for KeyAssignment test on provider-chain-validator1"
    vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP init --chain-id provider-chain --home /home/vagrant/tmp tempnode && sudo chmod -R 777 /home/vagrant/tmp"
  elif [[ "$1" == *"samekey"* ]]; then
    echo "Using the PREVIOUS (SAME) key for KeyAssignment test on provider-chain-validator1, checking location..."
    TMP_DIR_EXISTS=$(vagrant ssh provider-chain-validator1 -- "[ -d /home/vagrant/tmp ] && echo '/home/vagrant/tmp directory exists' || echo '/home/vagrant/tmp directory does not exist, creating...'")
    echo $TMP_DIR_EXISTS
    if [[ "$TMP_DIR_EXISTS" == *"does not exist"* ]]; then
      vagrant ssh provider-chain-validator1 -- "sudo mkdir /home/vagrant/tmp && sudo cp -r $PROVIDER_HOME* /home/vagrant/tmp && sudo chmod -R 777 /home/vagrant/tmp"
    fi
  fi

  vagrant scp provider-chain-validator1:/home/vagrant/tmp/config/priv_validator_key.json priv_validator_key1_UPDATED_"$1".json

  UPDATED_PUBKEY='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"'$(cat priv_validator_key1_UPDATED_"$1".json | jq -r '.pub_key.value')'"}'
  echo "New PubKey: $UPDATED_PUBKEY"

  echo "Assigning updated key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME tx provider assign-consensus-key consumer-chain "'"$UPDATED_PUBKEY"'" --from provider-chain-validator1 $PROVIDER_FLAGS

  sleep 2
  echo "Copying key $1 to consumer-chain-validator1"
  vagrant scp priv_validator_key1_UPDATED_"$1".json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json 
}


function assignKeyPreLaunchNewKey() {
  echo "Assigning keys pre-launch..."
  testKeyAssignment "1-prelaunch-newkey"
}

function waitForSpawnTime() {
  echo "Waiting for spawn time to be reached: $SPAWN_TIME"
  CURRENT_TIME=$(vagrant ssh provider-chain-validator1 -- "date -u '+%Y-%m-%dT%H:%M:%SZ'")
  CURRENT_TIME_SECONDS=$(date -d "$CURRENT_TIME" +%s)
  SPAWN_TIME_SECONDS=$(date -d "$SPAWN_TIME" +%s)
  REMAINING_SECONDS=$((SPAWN_TIME_SECONDS - CURRENT_TIME_SECONDS))
  echo "ETA: $REMAINING_SECONDS seconds..."
  
  while true; do
    CURRENT_TIME=$(vagrant ssh provider-chain-validator1 -- "date -u '+%Y-%m-%dT%H:%M:%SZ'")
    if [[ "$CURRENT_TIME" > "$SPAWN_TIME" ]]; then
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
  TMP_DIR_EXISTS=$(vagrant ssh provider-chain-validator1 -- "[ -d /home/vagrant/tmp ] && echo '/home/vagrant/tmp directory exists' || echo '/home/vagrant/tmp directory does not exist'")
  if [[ "$TMP_DIR_EXISTS" == *"does not exist"* ]]; then
  echo "Copying ORIGINAL private validator keys from provider-chain-validator1 to consumer-chain-validator1..."
    vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/priv_validator_key.json priv_validator_key1.json
    vagrant scp priv_validator_key1.json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json
  fi

  # Copy all other keys
  for i in {2..3} ; do 
    echo "Copying ORIGINAL private validator keys from provider-chain-validator${i} to consumer-chain-validator${i}..."
    vagrant scp provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json priv_validator_key${i}.json
    vagrant scp priv_validator_key${i}.json consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json
    rm "priv_validator_key${i}.json" 
  done
  
  # TODO - erroring here in script, not in bash...
  echo "Querying CCV consumer state and finalizing consumer chain genesis on provider-chain-validator 2..."
  CONSUMER_CCV_STATE=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "ccv.json"

  jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' raw_genesis.json ccv.json > final_genesis.json
  for i in {1..3} ; do 
    vagrant scp final_genesis.json consumer-chain-validator${i}:$CONSUMER_HOME/config/genesis.json
  done
  rm "ccv.json"
}


function startConsumerChain() {
  echo ">> STARTING CONSUMER CHAIN"
  for i in {1..3} ; do 
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh consumer-chain-validator${i} -- "sudo $CONSUMER_APP --home $CONSUMER_HOME start --rpc.laddr tcp://0.0.0.0:26657 --rpc.grpc_laddr tcp://0.0.0.0:9099 > /var/log/chain.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/chain.log"
  done
}

function prepareRelayer() {
  HERMES_BIN=/home/vagrant/.hermes/bin/hermes
  echo "Preparing hermes IBC relayer..."
  sed -e "0,/account_prefix = .*/s//account_prefix = \"cosmos\"/" \
    -e "0,/denom = .*/s//denom = \"icsstake\"/" \
    -e "1,/account_prefix = .*/s//account_prefix = \"$CONSUMER_BECH32_PREFIX\"/" \
    -e "1,/denom = .*/s//denom = \"$CONSUMER_FEE_DENOM\"/" \
    hermes_config.toml > config.toml

  vagrant scp config.toml provider-chain-validator1:/home/vagrant/.hermes/config.toml
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN config validate"
}

function createIbcPaths() {
  echo "Creating CCV IBC Paths..."
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN create connection --a-chain consumer-chain --a-client 07-tendermint-0 --b-client 07-tendermint-0"
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN create channel --a-chain consumer-chain --a-port consumer --b-port provider --order ordered --a-connection connection-0 --channel-version 1"
}

function startRelayer() {
  echo "Starting relayer..."
  vagrant ssh provider-chain-validator1 -- "sudo touch /var/log/hermes.log && sudo chmod 666 /var/log/hermes.log"
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN start > /var/log/hermes.log 2>&1 &"
  echo "[provider-chain-validator1] started hermes IBC relayer: watch output at /var/log/hermes.log"
}

function assignKeyPostLaunchNewKey() {
  echo "Assigning keys post-launch..."
  testKeyAssignment "2-postlaunch-newkey"
}

function assignKeyPostLaunchSameKey() {
  echo "Assigning keys post-launch..."
  testKeyAssignment "3-postlaunch-samekey"
}

function main() {
  loadEnv
  startProviderChain
  waitForProviderChain
  proposeConsumerAdditionProposal
  voteConsumerAdditionProposal
  waitForProposal
  assignKeyPreLaunchNewKey
  waitForSpawnTime
  prepareConsumerChain
  startConsumerChain
  prepareRelayer
  createIbcPaths
  startRelayer && sleep 120 # sleeps to offer more time to watch output, can be removed
  assignKeyPreLaunchNewKey && sleep 60 # sleeps to offer more time to watch output, can be removed
  assignKeyPreLaunchSameKey && sleep 60 # sleeps to offer more time to watch output, can be removed
}

main
echo "All tests passed!"