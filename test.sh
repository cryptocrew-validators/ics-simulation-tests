#!/bin/bash

# node logs piped to /var/logs/chain.log
# relayer logs piped to /var/logs/relayer.log

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 0.25icsstake --keyring-backend test -y"
CONSUMER_FLAGS="--chain-id consumer-chain --gas 1000000 --gas-prices 0.25stake --keyring-backend test -y"
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
    . .env
    echo "loaded configuration from ENV file: .env"
  else
    echo "ENV file not found at .env"
    exit 1
  fi
}

function call_and_log() {
  local function_name=$1
  local argument=$2
  echo "--- Running $function_name $argument" | tee -a ./files/logs/result.log
  $function_name $argument 2>&1 | tee -a ./files/logs/result.log
  echo "--- Finished $function_name $argument" | tee -a ./files/logs/result.log
}

function main() {
  # Load .env file
  loadEnv

  # Dependencies
  . ./src/provision.sh
  . ./src/provider.sh
  . ./src/proposal.sh
  . ./src/keyAssignment.sh
  . ./src/relayer.sh
  . ./src/consumer.sh  
  . ./src/migrate.sh
  . ./src/cleanup.sh
  . ./src/additional.sh
  # Clear the log file
  > result.log
  
  # Provision
  provisionVms

  # Run tests
  if $CLEAR_FILES_ON_START ; then
    call_and_log clearFilesAndLogs
  fi
  call_and_log prepareRelayer
  call_and_log startProviderChain
  call_and_log waitForProviderChain
  call_and_log startSovereignChain
  call_and_log waitForSovereignChain
  call_and_log proposeUpgradeSovereign
  call_and_log voteSoftwareUpgradeProposal
  call_and_log waitForProposalUpgrade
  call_and_log proposeConsumerAdditionProposal
  call_and_log voteConsumerAdditionProposal
  call_and_log waitForProposalConsumer
  if $KEY_ASSIGNMENT ; then
    call_and_log assignConsumerKey
  fi
  call_and_log switchBinaries
  call_and_log waitForSpawnTime
  sleep 10 # wait for provider module to recognize that the spawn time has passed
  call_and_log fetchCCVState
  call_and_log applyCCVState
  call_and_log waitForUpgradeHeight
  call_and_log restartChain
  sleep 5 # wait for consumer chain to finalize post-upgrade block
  getClientIDs
  call_and_log distributeProviderValidatorKeys
  call_and_log restartChain
  call_and_log createIbcPaths
  call_and_log startRelayer
  call_and_log delegate
  call_and_log jailConsumer
  call_and_log jailProvider
  call_and_log getLogs
  #call_and_log cleanUp
}

main

echo "All tests passed!"