#!/bin/bash

# Update and install required packages, set timezone to UTC
sudo apt-get update -qq
sudo apt-get install -qq git build-essential curl jq unzip moreutils net-tools
sudo timedatectl set-timezone UTC

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
  wget -4 -q $DAEMON_GO_SOURCE -O $(basename $DAEMON_GO_SOURCE)
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf $(basename $DAEMON_GO_SOURCE)
  rm $(basename $DAEMON_GO_SOURCE)
  mkdir -p /home/vagrant/go/bin
  echo 'export GOROOT=/usr/local/go' >> /home/vagrant/.bashrc
  echo 'export GOPATH=/home/vagrant/go' >> /home/vagrant/.bashrc
  echo 'export GO111MODULE=on' >> /home/vagrant/.bashrc
  echo 'export PATH=$PATH:$GOROOT/bin' >> /home/vagrant/.bashrc
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
    sudo chown vagrant:vagrant /usr/local/bin/$DAEMON_NAME 
    sudo chmod 777 /usr/local/bin/$DAEMON_NAME
    cd ..
}

function buildNewBinary() {
  cd $LOCAL_REPO
  git checkout v12.1.0
  echo "Installing new binary"
  make install

  sudo mv /home/vagrant/go/bin/$DAEMON_NAME /usr/local/bin/newbin
  sudo chown vagrant:vagrant /usr/local/bin/newbin
  sudo chmod 777 /usr/local/bin/newbin
  sudo chmod -R 777 /usr/local/bin
  cd ..
}

function initNode() {
  NODE_MONIKER="${CHAIN_ID}-validator${NODE_INDEX}"
  $DAEMON_NAME init "$NODE_MONIKER" --chain-id "$CHAIN_ID" --home $DAEMON_HOME
}

function manipulateGenesis() {
  if [ "$CHAIN_ID" == "provider-chain" ]; then
    sed -i 's/stake/icsstake/g' $DAEMON_HOME/config/genesis.json
    jq '.app_state.staking.params.unbonding_time = "1814400s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
    jq '.app_state.gov.voting_params.voting_period = "60s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
  
    GENESIS_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))")
    jq --arg time "$GENESIS_TIME" '.genesis_time = $time' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
  elif [[ "$CHAIN_ID" == "consumer-chain" && "$CONSUMER_MIGRATION" == "true" ]]; then
    if [ -f /home/vagrant/migration_state_export.json ] ; then
      echo "found state export for sovereign chain, creating genesis..."
      rm $DAEMON_HOME/config/genesis.json
      jq '.app_state.staking.validators = []' migration_state_export.json > $DAEMON_HOME/config/genesis.json
    else
      jq '.app_state.staking.params.unbonding_time = "1814400s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
      jq '.app_state.gov.voting_params.voting_period = "60s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
      jq '.app_state.gov.params.voting_period = "60s"' $DAEMON_HOME/config/genesis.json | sponge $DAEMON_HOME/config/genesis.json
    fi
  fi
}

function genTx() {
  if [ "$CHAIN_ID" == "provider-chain" ]; then
    $DAEMON_NAME --home $DAEMON_HOME keys add "$NODE_MONIKER" --keyring-backend test
    $DAEMON_NAME --home $DAEMON_HOME add-genesis-account $($DAEMON_NAME keys --home $DAEMON_HOME show "$NODE_MONIKER" -a --keyring-backend test) 1500000000000icsstake --keyring-backend test
    $DAEMON_NAME --home $DAEMON_HOME gentx "$NODE_MONIKER" 1000000000icsstake --chain-id "$CHAIN_ID" --keyring-backend test
  fi
  if [[ "$CHAIN_ID" == "consumer-chain" && "$CONSUMER_MIGRATION" == "true" ]]; then
    $DAEMON_NAME --home $DAEMON_HOME keys add "$NODE_MONIKER" --keyring-backend test
    $DAEMON_NAME --home $DAEMON_HOME add-genesis-account $($DAEMON_NAME keys --home $DAEMON_HOME show "$NODE_MONIKER" -a --keyring-backend test) 1500000000000"$CONSUMER_FEE_DENOM" --keyring-backend test
    $DAEMON_NAME --home $DAEMON_HOME gentx "$NODE_MONIKER" 1000000000$CONSUMER_FEE_DENOM --chain-id "$CHAIN_ID" --keyring-backend test
  fi
}



function installRelayer() {
  if [ "$CHAIN_ID" == "provider-chain" ] && [ "$NODE_INDEX" == "1" ]; then
    echo "Installing Rust and Cargo"
    mkdir /home/vagrant/.cargo || true
    sudo apt install cargo -qq
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        
    # Add the /home/vagrant/.cargo/bin directory to the PATH environment variable
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> /home/vagrant/.bashrc
    export PATH="/home/vagrant/.cargo/bin:$PATH"

    source /home/vagrant/.bashrc
    sudo chmod -R 777 /home/vagrant/.cargo

    # Install ibc-relayer-cli crate and build the hermes binary
    echo "Installing ibc-relayer-cli crate and building the hermes binary"
    mkdir -p /home/vagrant/.hermes/bin

    # Check if the current Ubuntu version is not 22.04 (Jammy)
    ubuntu_version=$(lsb_release -rs)
    if [ "$ubuntu_version" != "22.04" ] || [ -z "$HERMES_SOURCE" ]; then
      cargo install ibc-relayer-cli --bin hermes --locked
      sudo cp /root/.cargo/bin/hermes /home/vagrant/.hermes/bin
    else
      wget -4 -q $HERMES_SOURCE -O $(basename $HERMES_SOURCE)
      tar -C /home/vagrant/.hermes/bin/ -xzf $(basename $HERMES_SOURCE)
    fi

    sudo chmod 777 /home/vagrant/.hermes/bin/hermes
    sudo chown -R vagrant:vagrant /home/vagrant/.hermes  
  fi
}

function updateOwnerships() {
  echo "Updating ownerships..."
  # sudo chmod -R 777 $DAEMON_HOME
  sudo chown -R vagrant:vagrant $DAEMON_HOME
}

main() {
  loadEnv
  setNodeVars
  installGo
  installNode
  if [[ "$CHAIN_ID" == "consumer-chain" && "$CONSUMER_MIGRATION" == "true" ]]; then
    buildNewBinary
  fi
  initNode
  manipulateGenesis
  genTx
  installRelayer
  updateOwnerships
}

main && echo "SUCCESS >> node provisioned"
