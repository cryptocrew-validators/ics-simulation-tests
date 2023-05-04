set -e

# Preperare IBC relayer
function prepareRelayer() {
  echo "Preparing hermes IBC relayer..."
  vagrant ssh provider-chain-validator1 -- "sudo echo $RELAYER_MNEMONIC > .mn && sudo $HERMES_BIN --config $HERMES_CONFIG keys add --chain provider-chain --mnemonic-file .mn || true && sudo $HERMES_BIN --config $HERMES_CONFIG keys add --chain consumer-chain --mnemonic-file .mn || true"
}

# Create the cross-chain-validation and transfer IBC-paths
function createIbcPaths() {
  echo "Creating CCV IBC Paths..."
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN --config $HERMES_CONFIG create connection --a-chain consumer-chain --a-client 07-tendermint-0 --b-client 07-tendermint-0"
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN --config $HERMES_CONFIG create channel --a-chain consumer-chain --a-port consumer --b-port provider --order ordered --a-connection connection-0 --channel-version 1"
}

# Start IBC Relayer
function startRelayer() {
  echo "Starting relayer..."
  vagrant ssh provider-chain-validator1 -- "sudo touch /var/log/hermes.log && sudo chmod 666 /var/log/hermes.log"
  vagrant ssh provider-chain-validator1 -- "sudo $HERMES_BIN --config $HERMES_CONFIG start > /var/log/hermes.log 2>&1 &"
  echo "[provider-chain-validator1] started hermes IBC relayer: watch output at /var/log/hermes.log"
}