set -e

# Preperare IBC relayer
function prepareRelayer() {
  echo "Preparing hermes IBC relayer..."
  vagrant ssh provider-chain-validator1 -- "sed -i \"s|account_prefix = 'consumer'|account_prefix = '\\\"$CONSUMER_BECH32_PREFIX\\\"'|g\" /home/vagrant/.hermes/config.toml"
  vagrant ssh provider-chain-validator1 -- "sed -i \"s|denom = 'ustake'|denom = '\\\"$CONSUMER_BECH32_PREFIX\\\"'|g\" /home/vagrant/.hermes/config.toml"
  vagrant ssh provider-chain-validator1 -- "echo $RELAYER_MNEMONIC > .mn && $HERMES_BIN --config $HERMES_CONFIG keys add --chain provider-chain --mnemonic-file .mn || true && $HERMES_BIN --config $HERMES_CONFIG keys add --chain consumer-chain --mnemonic-file .mn || true"
}

# Create the cross-chain-validation and transfer IBC-paths
function createIbcPaths() {
  echo "Creating CCV IBC Paths..."
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG create connection --a-chain consumer-chain --a-client 07-tendermint-0 --b-client 07-tendermint-0"
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG create channel --a-chain consumer-chain --a-port consumer --b-port provider --order ordered --a-connection connection-0 --channel-version 1"
}

# Start IBC Relayer
function startRelayer() {
  echo "Starting relayer..."
  vagrant ssh provider-chain-validator1 -- "sudo touch /var/log/hermes.log && sudo chmod 666 /var/log/hermes.log"
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG start > /var/log/hermes.log 2>&1 &"
  echo "[provider-chain-validator1] started hermes IBC relayer: watch output at /var/log/hermes.log"
}

function testConnection() {
  echo "Querying IBC connection..."
  CONNECTION=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN query connections --chain consumer-chain")
  if echo "$CONNECTION" | grep -q "SUCCESS" && echo "$CONNECTION" | grep -q "connection-0"; then
    echo ">>> IBC Connection was successful."
    TEST_IBC_CONNECTION="true"
  else
    echo ">>> IBC Connection was unsuccessful."
    TEST_IBC_CONNECTION="false"
  fi
}

function testChannel() {
  echo "Querying IBC channel..."
  CHANNEL=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN query channels --chain consumer-chain")
  if echo "$CHANNEL" | grep -q "SUCCESS" && echo "$CHANNEL" | grep -q "channel-0"; then
    echo ">>> IBC Channels were successfully created."
    TEST_IBC_CHANNEL="true"
  else
    echo ">>> IBC Channels could not be created."
    TEST_IBC_CHANNEL="false"
  fi
}