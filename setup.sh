#!/bin/bash

# Update and install required packages, set timezone to UTC
sudo apt-get update
sudo apt-get install -yy git build-essential curl jq unzip moreutils net-tools
sudo timedatectl set-timezone UTC

function loadEnv {
  ENV=/home/vagrant/.env
  if test -f $ENV ; then 
      export $(grep "^[^#;]" $ENV | xargs)
      echo "loaded configuration from ENV file: $ENV"
  else
      echo "ENV file not found at $ENV"
      exit 1
  fi
}

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

function setNodeVars() {
  if [ "$CHAIN_ID" == "provider-chain" ]; then
    DAEMON_NAME=$PROVIDER_APP
    DAEMON_HOME=$PROVIDER_HOME
    DAEMON_REPO=$PROVIDER_REPO
    DAEMON_VERSION=$PROVIDER_VERSION
    DAEMON_GO_SOURCE=$PROVIDER_GO_SOURCE
  elif [ "$CHAIN_ID" == "consumer-chain" ]; then
    DAEMON_NAME=$CONSUMER_APP
    DAEMON_HOME=$CONSUMER_HOME
    DAEMON_REPO=$CONSUMER_REPO
    DAEMON_VERSION=$CONSUMER_VERSION
    DAEMON_GO_SOURCE=$CONSUMER_GO_SOURCE
  fi
}

function installGo() {
  wget -4 $DAEMON_GO_SOURCE -O $(basename $DAEMON_GO_SOURCE)
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xvzf $(basename $DAEMON_GO_SOURCE)
  rm $(basename $DAEMON_GO_SOURCE)
  mkdir -p /home/vagrant/go/bin
  export GOROOT=/usr/local/go
  export GOPATH=/home/vagrant/go
  export GO111MODULE=on
  export PATH=$PATH:$GOROOT/bin
}

function installNode() {
  LOCAL_REPO=$DAEMON_NAME-core
  if [ -d $LOCAL_REPO ] ; then
    rm -r $LOCAL_REPO
  fi
  mkdir $LOCAL_REPO
  git clone $DAEMON_REPO $LOCAL_REPO
  cd $LOCAL_REPO
  git checkout $DAEMON_VERSION
  make install
  sudo mv /home/vagrant/go/bin/$DAEMON_NAME /usr/local/bin
  cd ..
  rm -rf $LOCAL_REPO
}

function initNode() {
  NODE_MONIKER="${CHAIN_ID}-validator${NODE_INDEX}"
  $DAEMON_NAME init "$NODE_MONIKER" --chain-id "$CHAIN_ID" --home $DAEMON_HOME
}

function manipulateGenesis() {
  if [ "$CHAIN_ID" == "provider-chain" ]; then
    sed -i 's/stake/icsstake/g' $DAEMON_HOME/config/genesis.json
    jq '.app_state.staking.params.unbonding_time = "300s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
    jq '.app_state.gov.voting_params.voting_period = "60s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
    jq '.app_state.gov.params.deposit_params.min_deposit[0].amount = "1"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
  elif [ "$CHAIN_ID" == "consumer-chain" ]; then
    rm $DAEMON_HOME/config/genesis.json
    wget $CONSUMER_GENESIS_SOURCE -O $DAEMON_HOME/config/raw_genesis.json
    jq --arg chainid "$CHAIN_ID" '.chain_id = $chainid' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
  fi
  GENESIS_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))")
  jq --arg time "$GENESIS_TIME" '.genesis_time = $time' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
}

function genTx() {
  if [ "$CHAIN_ID" == "provider-chain" ]; then
    $DAEMON_NAME --home $DAEMON_HOME keys add "$NODE_MONIKER" --keyring-backend test
    $DAEMON_NAME --home $DAEMON_HOME add-genesis-account $($DAEMON_NAME keys --home $DAEMON_HOME show "$NODE_MONIKER" -a --keyring-backend test) 1500000000000icsstake --keyring-backend test
    $DAEMON_NAME --home $DAEMON_HOME gentx "$NODE_MONIKER" 1000000000icsstake --chain-id "$CHAIN_ID" --keyring-backend test
    
    # Copy gentxs to the first validator of provider chain, collect gentxs
    if [ "$NODE_INDEX" != "1" ]; then
      scp $DAEMON_HOME/config/gentx/*.json "${CHAIN_ID}-validator1:$DAEMON_HOME/config/gentx/"
    elif [ "$NODE_INDEX" == "1" ]; then
      sleep 5
      $DAEMON_NAME --home $DAEMON_HOME collect-gentxs
    fi
  fi
}

function startProviderChain() {
  if [ "$CHAIN_ID" == "provider-chain" ]; then
    if [ "$NODE_INDEX" == "1" ]; then
      $DAEMON_NAME --home $DAEMON_HOME start &
    else
      # Wait for the first validator to collect gentxs
      while ! ssh "${CHAIN_ID}-validator1" test -f $DAEMON_HOME/config/genesis.json; do sleep 2; done

      # Get genesis file and persistent_peers from the first validator
      scp "${CHAIN_ID}-validator1:$DAEMON_HOME/config/genesis.json" $DAEMON_HOME/config/genesis.json
      $(get_terminal_command) "ssh \"${CHAIN_ID}-validator${NODE_INDEX}\" \"tail -f /var/log/icstest.log\"" &
$DAEMON_NAME --home $DAEMON_HOME start &> /var/log/icstest.log &
    fi
  fi
}

function configNode() {
  PERSISTENT_PEERS=$(for i in {1..3}; do
    IP_PART=$( [ "$CHAIN_ID" == "provider-chain" ] && echo "33" || echo "34" )
    echo -n "${CHAIN_ID}-validator${i}@192.168.${IP_PART}.1${i}:26656,"
  done | sed 's/,$//')
  sed -i "s/persistent_peers = \"\"/persistent_peers = \"$PERSISTENT_PEERS\"/g" $DAEMON_HOME/config/config.toml
}

main() {
  loadEnv
  setNodeVars
  installGo
  installNode
  initNode
  manipulateGenesis
  configNode
  genTx
  startProviderChain
}

main && echo "SUCCESS >> provider chain started!"