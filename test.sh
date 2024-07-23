#!/bin/bash

# node logs piped to /var/logs/chain.log
# relayer logs piped to /var/logs/relayer.log

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 1icsstake --keyring-backend test -y"
CONSUMER_FLAGS="--chain-id $CONSUMER_CHAIN_ID --gas 400000 --gas-prices ${CONSUMER_FEE_AMOUNT}${CONSUMER_FEE_DENOM} --keyring-backend test -y"
RELAYER_MNEMONIC="genre inch matrix flag bachelor random spawn course abandon climb negative cake slow damp expect decide return acoustic furnace pole humor giraffe group poem"
HERMES_BIN=/home/vagrant/.hermes/bin/hermes
HERMES_CONFIG=/home/vagrant/.hermes/config.toml
TESTS_PASSED=0
TESTS_FAILED=0

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

  # Save current file descriptors for stdout and stderr
  exec 3>&1 4>&2

  # Start logging and redirect stdout and stderr to log file and terminal
  echo "--- Running $function_name $argument" | tee -a ./files/logs/result.log >&3
  exec 1>>./files/logs/result.log 2>&1

  # Call the function
  $function_name "$argument"

  # Restore file descriptors (and stop logging to file)
  exec 1>&3 2>&4

  # End logging
  echo "--- Finished $function_name $argument" | tee -a ./files/logs/result.log >&3
}

function sourceDependencies() {
  . ./src/provision.sh
  . ./src/provider.sh
  . ./src/proposal.sh
  . ./src/keyAssignment.sh
  . ./src/relayer.sh
  . ./src/consumer.sh 
  . ./src/migrate.sh
  . ./src/cleanup.sh
  . ./src/additional.sh
}

function main() {
  # Load .env file
  loadEnv

  # Dependencies
  sourceDependencies

  if $CLEAR_FILES_ON_START ; then
    clearFilesAndLogs
  fi
  
  # Provision
  provisionVms

  echo "Starting tests..."
  echo "For more info during the run, follow the log with:"
  echo "tail -f $(pwd)/files/logs/result.log"

  #Run tests
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
    call_and_log assignConsumerKey "provider-newkey-1"
  fi
  call_and_log switchBinaries
  call_and_log waitForSpawnTime
  sleep 10 # wait for provider module to recognize that the spawn time has passed
  call_and_log fetchCCVState
  call_and_log applyCCVState
  call_and_log waitForUpgradeHeight
  call_and_log restartChain
  sleep 5 # wait for consumer chain to finalize post-upgrade block
  call_and_log getClientIDs
  call_and_log distributeProviderValidatorKeys
  call_and_log restartChain
  call_and_log createIbcPaths
  call_and_log testConnection
  call_and_log testChannel
  call_and_log startRelayer
  call_and_log delegate
  # call_and_log jailProvider
  call_and_log getLogs
  # call_and_log cleanUp

  showResults
}

main

echo "Finished! Check logs of additional details."


