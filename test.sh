#!/bin/bash

# node logs piped to /var/logs/chain.log
# relayer logs piped to /var/logs/relayer.log

PROVIDER_FLAGS="--chain-id provider-chain --gas 500000 --gas-prices 1.0icsstake --keyring-backend test -y"
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
  . ./src/cleanup.sh
  . ./src/additional.sh
}

function showResults() {
  echo "Test Results: "
  if [ "$TEST_PROVIDER_LAUNCH" == "true" ]; then
    echo "Provider chain launch: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo "Provider chain launch: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi
  
  if [ "$TEST_CONSUMER_LAUNCH" == "true" ]; then
    echo "Consumer chain launch: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo "Consumer chain launch: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_IBC_CONNECTION" == "true" ]; then
    echo "IBC connection creation: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo "IBC connection creation: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_IBC_CHANNEL" == "true" ]; then
    echo "IBC channel creation: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo "IBC channel creation: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_DELEGATION_CONSUMER" == "true" ]; then
    echo "Delegation update on consumer chain: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo "Delegation update on consumer chain: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi
  
  if [ "$TEST_JAIL_PROVIDER" == "true" ]; then
    echo "Validator jailing on provider chain: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  else
    echo "Validator jailing on provider chain: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  # if [ "$TEST_JAIL_CONSUMER" == "true" ]; then
  #   echo "Validator jailing on consumer chain: OK"
  #   TESTS_PASSED=$((TESTS_PASSED+1))
  # else
  #   echo "Validator jailing on consumer chain: FAILED"
  #   TESTS_FAILED=$((TESTS_FAILED+1))
  # fi

  echo "Tests passed: $TESTS_PASSED"
  echo "Tests failed: $TESTS_FAILED"
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

  # Run tests
  call_and_log startProviderChain
  call_and_log waitForProviderChain
  call_and_log manipulateConsumerGenesis
  if $PERMISSIONLESS ; then
    call_and_log createConsumer
    call_and_log optIn
    call_and_log calculateIbcDenom
    call_and_log whiteListDenoms
  elif
    call_and_log proposeConsumerAdditionProposal
    call_and_log voteConsumerAdditionProposal
  fi
  if $KEY_ASSIGNMENT ; then
    call_and_log assignConsumerKey "1-prelaunch-newkey"
  fi
  call_and_log waitForSpawnTimeOptIn
  call_and_log prepareConsumerChain
  call_and_log startConsumerChain
  call_and_log waitForConsumerChain
  call_and_log prepareRelayer
  call_and_log createIbcPaths
  call_and_log testConnection
  call_and_log testChannel
  call_and_log startRelayer
  call_and_log delegate
  #call_and_log jailProvider

  if $KEY_ASSIGNMENT ; then
    call_and_log validateAssignedKey "1-prelaunch-newkey"
    
    call_and_log testKeyAssignment "2-postlaunch-newkey"
    call_and_log validateAssignedKey "2-postlaunch-newkey"

    call_and_log testKeyAssignment "3-postlaunch-samekey"
    call_and_log validateAssignedKey "3-postlaunch-samekey"
  fi

  call_and_log getLogs
  if $CLEANUP_ON_FINISH ; then
    call_and_log cleanUp
  fi

  showResults
}

main

echo "Finished! Check logs of additional details."


