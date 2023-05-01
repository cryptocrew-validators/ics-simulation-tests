#!/bin/bash

# node logs piped to /var/logs/chain.log

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 0.25icsstake --keyring-backend test -y"
RELAYER_MNEMONIC="genre inch matrix flag bachelor random spawn course abandon climb negative cake slow damp expect decide return acoustic furnace pole humor giraffe group poem"
HERMES_SOURCE=https://github.com/informalsystems/hermes/releases/download/v1.4.0/hermes-v1.4.0-x86_64-unknown-linux-gnu.tar.gz

set -e

if ! (command -v sponge > /dev/null 2>&1); then
  echo "moreutils needs to be installed! run: apt install moreutils"
fi
if ! (command -v hermes > /dev/null 2>&1); then
  wget $HERMES_SOURCE -O hermes.tar.gz
  mkdir -p $HOME/.hermes/bin
  tar -C $HOME/.hermes/bin/ -vxzf hermes.tar.gz
  rm hermes.tar.gz
  export PATH="$HOME/.hermes/bin:$PATH"
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
    vagrant ssh provider-chain-validator${i} -- "sudo $PROVIDER_APP --home $PROVIDER_HOME start --rpc.laddr tcp://0.0.0.0:26657 --rpc.grpc_laddr 0.0.0.0:9090 > /var/log/chain.log 2>&1 &"
    echo "[provider-chain-validator${i}] started $PROVIDER_APP: watch output at /var/log/chain.log"
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

  # Download and manipulate consumer genesis file
  echo "Downloading consumer genesis file"
  wget -4 $CONSUMER_GENESIS_SOURCE -O raw_genesis.json

  echo "Setting chain_id: consumer-chain"
  jq --arg chainid "consumer-chain" '.chain_id = $chainid' raw_genesis.json | sponge raw_genesis.json
  
  GENESIS_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))")
  echo "Setting genesis time: $GENESIS_TIME" 
  jq --arg time "$GENESIS_TIME" '.genesis_time = $time' raw_genesis.json | sponge raw_genesis.json

  echo "Adding relayer account & balances"
  CONSUMER_RELAYER_ACCOUNT_ADDRESS=$(vagrant ssh consumer-chain-validator1 -- "echo $RELAYER_MNEMONIC | $PROVIDER_APP --home $PROVIDER_HOME keys add relayer --recover --keyring-backend test --output json")
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
  "address": "$CONSUMER_RELAYER_ACCOUNT_ADDRESS",
  "coins": [
    {
      "denom": "$CONSUMER_FEE_DENOM",
      "amount": "150000000"
    }
  ]
}
EOT
  jq '.app_state.auth.accounts += [input]' raw_genesis.json relayer_account_consumer.json > raw_genesis_modified.json && mv raw_genesis_modified.json raw_genesis.json
  jq '.app_state.bank.balances += [input]' raw_genesis.json balance.json > raw_genesis_modified.json && mv raw_genesis_modified.json raw_genesis.json
  rm relayer_account_consumer.json && relayer_balance_consumer.json

  CONSUMER_BINARY_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sudo sha256sum /usr/local/bin/$CONSUMER_APP" | awk '{ print $1 }')
  echo "Consumer binary sha256: $CONSUMER_BINARY_SHA256"
  CONSUMER_RAW_GENESIS_SHA256=$(sha256sum raw_genesis.json | awk '{ print $1 }')
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
    echo "Voted 'yes' from provider-chain-validator${i}"
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

  echo "Waiting a block for everything to be propagated..."
  sleep 7

  echo "Querying CCV consumer state and finalizing consumer chain genesis on each consumer validator..."
  CONSUMER_CCV_STATE=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "ccv.json"

  jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' raw_genesis.json ccv.json > final_genesis.json
  for i in {1..3} ; do 
    vagrant scp final_genesis.json consumer-chain-validator${i}:/home/vagrant/genesis.json
  done
  rm "ccv.json"
}

function assignKey() {
  echo "Generating new key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP init --chain-id provider-chain --home /home/vagrant/tmp tempnode && sudo chmod -R 777 /home/vagrant/tmp"
  vagrant scp provider-chain-validator1:/home/vagrant/tmp/config/priv_validator_key.json priv_validator_key.json
  vagrant ssh provider-chain-validator1 -- sudo rm -rf /home/vagrant/tmp

  NEW_PUBKEY='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"'$(cat priv_validator_key.json | jq -r '.pub_key.value')'"}'
  echo "New PubKey: $NEW_PUBKEY"
  echo "Copying new key to consumer-chain-validator1"
  vagrant scp priv_validator_key.json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json 

  echo "Assigning new key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME  tx provider assign-consensus-key consumer-chain "'"$NEW_PUBKEY"'" --from provider-chain-validator1 $PROVIDER_FLAGS
}

function assignKeyPreLaunch() {
  echo "Assigning keys pre-launch..."
  assignKey
}

function startConsumerChain() {
  echo ">> STARTING CONSUMER CHAIN"
  for i in {1..3} ; do 
    vagrant ssh consumer-chain-validator${i} -- "sudo touch /var/log/chain.log && sudo chmod 666 /var/log/chain.log"
    vagrant ssh consumer-chain-validator${i} -- "sudo $CONSUMER_APP --home $CONSUMER_HOME start --rpc.laddr tcp://0.0.0.0:26657 --rpc.grpc_laddr 0.0.0.0:9090 > /var/log/chain.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/chain.log"
  done
}

function prepareRelayer() {
  echo "Preparing hermes IBC relayer..."
  sed -e "0,/account_prefix = .*/s//account_prefix = \"cosmos\"/" \
    -e "0,/denom = .*/s//denom = \"icsstake\"/" \
    -e "1,/account_prefix = .*/s//account_prefix = \"$CONSUMER_BECH32_PREFIX\"/" \
    -e "1,/denom = .*/s//denom = \"$CONSUMER_FEE_DENOM\"/" \
    hermes_config.toml > $HOME/.hermes/config.toml
    hermes config validate
}

function createIbcPaths() {
  echo "Creating CCV IBC Paths..."
  hermes create connection --a-chain consumer-chain --a-client 07-tendermint-0 --b-client 07-tendermint-0
  hermes create channel --a-chain consumer-chain --a-port consumer --b-port provider --order ordered --a-connection connection-0 --channel-version 1
}

function createIbcPaths() {
  echo "Starting relayer..."
  touch hermes.log
  hermes start > hermes.log 2>&1 &
  echo "[local] started hermes IBC relayer: watch output at ./hermes.log"
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
  prepareRelayer
  createIbcPaths
  startRelayer
  assignKeyPostLaunch
}

main
echo "All tests passed!"