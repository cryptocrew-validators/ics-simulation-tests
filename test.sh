#!/bin/bash

# node logs piped to /home/vagrant/icstest.log

set -e

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 0.25icsstake --keyring-backend test"

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
  echo "Starting vagrant VMs, waiting for PC to produce blocks..."
  vagrant plugin install vagrant-scp
  vagrant up

  sleep 1
  echo "Getting peerlists, editing configs..."
  configPeers

  for i in {1..3}; do
    vagrant ssh provider-chain-validator${i} -- "sudo chmod -R 777 $PROVIDER_HOME"
    vagrant ssh consumer-chain-validator${i} -- "sudo chmod -R 777 $CONSUMER_HOME"
  done
  
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

  COLLECTED=$(vagrant ssh provider-chain-validator1 -- sudo cat $PROVIDER_HOME/config/genesis.json | grep $VAL_ACCOUNT3)
  if [ -z "$COLLECTED" ] ; then
    echo "Collecting gentxs on provider-chain-validator1"
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account $VAL_ACCOUNT2 1500000000000icsstake --keyring-backend test
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME add-genesis-account $VAL_ACCOUNT3 1500000000000icsstake --keyring-backend test
    vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME collect-gentxs
  fi

  # Distribute genesis file from the first validator to validators 2 and 3
  echo "Distributing genesis file from provider-chain-validator1 to provider-chain-validator2 and provider-chain-validator3"
  vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/genesis.json genesis.json
  vagrant scp genesis.json provider-chain-validator2:$PROVIDER_HOME/config/genesis.json
  vagrant scp genesis.json provider-chain-validator3:$PROVIDER_HOME/config/genesis.json 
  
  echo ">> STARTING PROVIDER CHAIN"
  for i in {1..3} ; do 
    vagrant ssh provider-chain-validator${i} -- "sudo touch /var/log/provider_chain.log && sudo chmod 666 /var/log/provider_chain.log"
    vagrant ssh provider-chain-validator${i} -- "sudo $PROVIDER_APP --home $PROVIDER_HOME start > /var/log/provider_chain.log 2>&1 &"
    echo "[provider-chain-validator${i}] started $PROVIDER_APP: watch output at /var/log/provider_chain.log"
  done
}

# Wait for the provider to finalize a block
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

  CONSUMER_BINARY_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sudo sha256sum /usr/local/bin/$CONSUMER_APP" | awk '{ print $1 }')
  echo "Consumer binary sha256: $CONSUMER_BINARY_SHA256"
  CONSUMER_RAW_GENESIS_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sudo sha256sum $CONSUMER_HOME/config/raw_genesis.json" | awk '{ print $1 }')
  echo "Consumer genesis sha256: $CONSUMER_RAW_GENESIS_SHA256"
  SPAWN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))")
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
  "deposit": "1icsstake"
} 
EOT
  cat prop.json
  vagrant scp prop.json provider-chain-validator1:/home/vagrant/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  RES=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal consumer-addition /home/vagrant/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS")
  if [ -z "$RES" ]; then
    echo "Error submitting consumer addition proposal"
    exit 1
  fi
  echo "Consumer addition proposal submitted successfully"
}

# Vote yes on the consumer addition proposal from all provider validators
function voteConsumerAdditionProposal() {
  echo "Voting on consumer addition proposal..."

  for i in {1..3} ; do 
    echo "Voting 'yes' from provider-chain-validator${i}..."
    RES=$(vagrant ssh provider-chain-validator${i} -- "sudo $PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS")
    if [ -z "$RES" ]; then
      echo "Error voting on consumer addition proposal"
      exit 1
    fi
    echo "Voted 'yes' from provider-chain-validator${i} successfully"
  done
}

# Prepare consumer chain: copy private validator keys and finalizing genesis
function prepareConsumerChain() {
  echo "Preparing consumer chain..."

  for i in {1..3} ; do 
    echo "Copying private validator keys from provider-chain-validator${i} to consumer-chain-validator${i}..."
    vagrant scp provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json priv_validator_key${i}.json
    vagrant scp priv_validator_key${i}.json consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json
    rm "priv_validator_key${i}.json" 
  done

  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done
  echo "Consumer addition proposal passed"

  echo "Querying CCV consumer state and finalizing consumer chain genesis on each consumer validator..."
  CONSUMER_CCV_STATE=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "ccv.json"
  for i in {1..3} ; do 
    vagrant scp ccv.json consumer-chain-validator${i}:/home/vagrant/ccv.json
    vagrant ssh consumer-chain-validator${i} "sudo jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' $CONSUMER_HOME/config/raw_genesis.json /home/vagrant/ccv.json > $CONSUMER_HOME/config/genesis.json"
  done
  rm "ccv.json"
}

function assignKey() {
  echo "Generating new key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP init --chain-id provider-chain --home /home/vagrant/tmp
  vagrant scp provider-chain-validator1:/home/vagrant/tmp/config/priv_validator_key.json priv_validator_key.json
  vagrant ssh provider-chain-validator1 -- suro rm -rf /home/vagrant/tmp

  NEW_PUBKEY='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"'$(cat priv_validator_key.json | jq -r '.pub_key.value')'"}'
  echo PubKey: $NEW_PUBKEY
  echo "Copying new key to consumer-chain-validator1"
  vagrant scp priv_validator_key.json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json 

  echo "Assining new key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME  tx provider assign-consensus-key consumer-chain $NEW_PUBKEY --from provider-chain-validator1 $PROVIDER_FLAGS
}

function startConsumerChain() {
  echo ">> STARTING CONSUMER CHAIN"
  for i in {1..3} ; do 
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/consumer_chain.log && sudo chmod 666 /var/log/consumer_chain.log"
    vagrant ssh consumer-chain-validator${i} -- "sudo $CONSUMER_APP --home $CONSUMER_HOME start > /var/log/consumer_chain.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/consumer_chain.log"
  done
}

function assignKeyPreLaunch() {
  echo "Assigning keys pre-launch..."
  assignKey
}

function assignKeyPostLaunch() {
  echo "Assigning keys post-launch..."
  assignKey
}

function main() {
  loadEnv
  startProviderChain
  waitForProviderChain
  proposeConsumerAdditionProposal
  voteConsumerAdditionProposal
  prepareConsumerChain
  assignKeyPreLaunch
  startConsumerChain
  assignKeyPostLaunch
}

main
echo "All tests passed!"