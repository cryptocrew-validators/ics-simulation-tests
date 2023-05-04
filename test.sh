#!/bin/bash

# node logs piped to /var/logs/chain.log
# relayer logs piped to /var/logs/relayer.log

. ./src/provision.sh
. ./src/provider.sh
. ./src/consumerGenesis.sh
. ./src/proposal.sh
. ./src/testKeyAssignment.sh
. ./src/consumer.sh
. ./src/relayer.sh

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 0.25icsstake --keyring-backend test -y"
RELAYER_MNEMONIC="genre inch matrix flag bachelor random spawn course abandon climb negative cake slow damp expect decide return acoustic furnace pole humor giraffe group poem"
HERMES_BIN=/home/vagrant/.hermes/bin/hermes
HERMES_CONFIG=/home/vagrant/.hermes/config.toml

set -e

if ! (command -v sponge > /dev/null 2>&1); then
  echo "moreutils needs to be installed! run: apt install moreutils"
  exit 1
fi

function loadEnv {
  if test -f .env ; then 
    ENV=$(realpath .env)
    while IFS="=" read -r key value; do
      if [[ ! $key =~ ^# && ! -z $key ]]; then
        export "$key=$value"
      fi
    done < "$ENV"
    echo "loaded configuration from ENV file: $ENV"
  else
    echo "ENV file not found at .env"
    exit 1
  fi
}

function main() {
  loadEnv
  provisionVms
  startProviderChain
  waitForProviderChain
  manipulateConsumerGenesis
  proposeConsumerAdditionProposal
  voteConsumerAdditionProposal
  waitForProposal
  testKeyAssignment "1-prelaunch-newkey"
  waitForSpawnTime
  prepareConsumerChain
  startConsumerChain
  waitForConsumerChain
  prepareRelayer
  createIbcPaths
  startRelayer 
    sleep 120 # sleeps to offer more time to watch output, can be removed
  testKeyAssignment "2-postlaunch-newkey" 
    sleep 60 # sleeps to offer more time to watch output, can be removed
  testKeyAssignment "3-postlaunch-samekey" 
    sleep 60 # sleeps to offer more time to watch output, can be removed
}

main
echo "All tests passed!"