#!/bin/bash

# node logs piped to /var/log/icstest.log

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

# Start all virtual machines, collect gentxs & start provider chain
function startProviderChain() {
  echo "Starting vagrant VMs, waiting for PC to produce blocks..."
  vagrant plugin install vagrant-scp
  vagrant up

  sleep 1

  # Copy gentxs to the first validator of provider chain, collect gentxs
  vagrant scp "provider-chain-validator2" $PROVIDER_HOME/config/gentx/*.json gentx2.json
  vagrant scp gentx2.json $provider-chain-validator1:$PROVIDER_HOME/config/gentx/gentx2.json
  vagrant scp "provider-chain-validator3" $PROVIDER_HOME/config/gentx/*.json gentx3.json
  vagrant scp gentx3.json $provider-chain-validator1:$PROVIDER_HOME/config/gentx/gentx3.json
  rm gentx2.json gentx3.json

  vagrant ssh "provider-chain-validator1" $PROVIDER_APP --home $PROVIDER_HOME collect-gentxs
  
  # Wait for the first validator to collect gentxs
  while ! vagrant ssh "provider-chain-validator1" test -f $PROVIDER_HOME/config/genesis.json; do sleep 1; done

  # Distribute genesis file from the first validator to validators 2 and 3
  vagrant scp "provider-chain-validator1:$PROVIDER_APP/config/genesis.json" genesis.json
  vagrant scp genesis.json "provider-chain-validator2:$PROVIDER_APP/config/genesis.json" 
  vagrant scp genesis.json "provider-chain-validator3:$PROVIDER_APP/config/genesis.json" 
  
  for i in {1..3} ; do 
    $(get_terminal_command) "vagrant ssh \"provider-chain-validator${i}\" \"tail -f /var/log/icstest.log\"" &
$PROVIDER_APP --home $PROVIDER_HOME start &> /var/log/icstest.log &
  done
}

# Wait for the provider to finalize a block
function waitForProviderChain() {
  echo "Waiting for Provider Chain to finalize a block..."
  PROVIDER_LATEST_HEIGHT=""
  while [[ ! $PROVIDER_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $PROVIDER_LATEST_HEIGHT -lt 1 ]]; do
    PROVIDER_LATEST_HEIGHT=$(vagrant ssh "provider-chain-validator1" 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
  done
  echo ">> PROVIDER CHAIN successfully launched. Latest block height: $PROVIDER_LATEST_HEIGHT"
}

# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {
  
  # Prepare proposal file
  echo "Preparing consumer addition proposal..."

  CONSUMER_BINARY_SHA256=$(vagrant ssh "consumer-chain-validator1" "sha256sum $(which $CONSUMER_APP)" | awk '{ print $1 }')
  CONSUMER_RAW_GENESIS_SHA256=$(vagrant ssh "consumer-chain-validator1" "sha256sum $DAEMON_HOME/genesis/raw_genesis.json" | awk '{ print $1 }')
  SPAWN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))")
  cat > prop.json <<EOT
{
  "title": "Create the Consumer chain",
  "description": "This is the proposal to create the consumer chain \"consumer-chain\".",
  "chain_id": "consumer-chain",
  "initial_height": {
      "revision_height": 1,
  },
  "genesis_hash": "$CONSUMER_BINARY_SHA256",
  "binary_hash": "$CONSUMER_RAW_GENESIS_SHA256",
  "spawn_time": "$SPAWN_TIME",
  "deposit": "1icsstake"
} 
EOT
<<<<<<< HEAD
  vagrant scp prop.json provider-chain-validator1:/home/root/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  RES=$(vagrant ssh "provider-chain-validator1" "$PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal consumer-addition /home/root/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS")
=======
  scp prop.json provider-chain-validator1:/home/vagrant/prop.json
  rm prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  RES=$(ssh "provider-chain-validator1" "$PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal consumer-addition /home/vagrant/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS")
>>>>>>> e6cf8d3b0f6979cc935b538b97e1dae79f81bb48
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
    RES=$(vagrant ssh "provider-chain-validator${i}" "$PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS")
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
    vagrant scp "provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json" "priv_validator_key${i}.json"
    vagrant scp "priv_validator_key${i}.json" "consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json" 
    rm "priv_validator_key${i}.json" 
  done

  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh "provider-chain-validator1" "$PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done
  echo "Consumer addition proposal passed"

  echo "Querying CCV consumer state and finalizing consumer chain genesis on each consumer validator..."
  CONSUMER_CCV_STATE=$(vagrant ssh "provider-chain-validator1" "$PROVIDER_APP query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "ccv.json"
  for i in {1..3} ; do 
<<<<<<< HEAD
    vagrant scp "ccv.json" "consumer-chain-validator${i}:/home/root/ccv.json"
    vagrant ssh "consumer-chain-validator${i}" "jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' $CONSUMER_HOME/config/raw_genesis.json /home/root/ccv.json > $CONSUMER_HOME/config/genesis.json"
=======
    scp "ccv.json" "consumer-chain-validator${i}:/home/vagrant/ccv.json"
    ssh "consumer-chain-validator${i}" "jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' $CONSUMER_HOME/config/raw_genesis.json /home/vagrant/ccv.json > $CONSUMER_HOME/config/genesis.json"
>>>>>>> e6cf8d3b0f6979cc935b538b97e1dae79f81bb48
  done
  rm "ccv.json"
}

function startConsumerChain() {
  for i in {1..3} ; do 
    $(get_terminal_command) "vagrant ssh \"consumer-chain-validator${i}\" \"tail -f /var/log/icstest.log\"" &
$CONSUMER_APP --home $CONSUMER_HOME start &> /var/log/icstest.log &
  done
}

function assignKeyPreLaunch() {
  echo "Assigning keys pre-launch..."
  
  # TODO
}

function assignKeyPostLaunch() {
  echo "Assigning keys post-launch..."
  
  # TODO
}

function main() {
  loadEnv
  startAndWaitForProviderChain
  proposeConsumerAdditionProposal
  voteConsumerAdditionProposal
  prepareConsumerChain
  startConsumerChain
  # assignKeyPreLaunch
  # assignKeyPostLaunch
}

main
echo "All tests passed!"