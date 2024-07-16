set -e

# Prepare IBC relayer
function prepareRelayer() {
  echo "Preparing hermes IBC relayer..."
  vagrant ssh provider-chain-validator1 -- "sed -i \"s|account_prefix = 'consumer'|account_prefix = '$CONSUMER_BECH32_PREFIX'|g\" /home/vagrant/.hermes/config.toml"
  vagrant ssh provider-chain-validator1 -- "sed -i \"s|denom = 'ustake'|denom = '$CONSUMER_FEE_DENOM'|g\" /home/vagrant/.hermes/config.toml"
  vagrant ssh provider-chain-validator1 -- "echo $RELAYER_MNEMONIC > .mn && $HERMES_BIN --config $HERMES_CONFIG keys add --chain provider-chain --mnemonic-file .mn || true"
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG keys add --chain $CONSUMER_CHAIN_ID --mnemonic-file .mn --hd-path \"m/44'/118'/0'/0/0\" || true"
}

function getClientIDs() {
  echo "Fetching client IDs for both chains..."
  CLIENT_ID_PROVIDER=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME q provider list-consumer-chains -o .json | jq -r '.chains[0].client_id' | sed 's/\x1b\[[0-9;]*m//g'")
  CLIENT_ID_CONSUMER=$(vagrant ssh consumer-chain-validator1 -- "grep -oP 'client-id=\K[^ ]+' /var/log/consumer.log | head -n 1 | sed 's/\x1b\[[0-9;]*m//g'")
  echo "Provider client ID: $CLIENT_ID_PROVIDER"
  echo "Consumer client ID: $CLIENT_ID_CONSUMER"
}

# Create the cross-chain-validation and transfer IBC-paths
function createIbcPaths() {
  echo "Creating CCV IBC Paths..."
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG create connection --a-chain $CONSUMER_CHAIN_ID --a-client 07-tendermint-0 --b-client 07-tendermint-0"
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG create channel --a-chain $CONSUMER_CHAIN_ID --a-port consumer --b-port provider --order ordered --a-connection connection-0 --channel-version 1"
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
  CONNECTION=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN query connections --chain $CONSUMER_CHAIN_ID")
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
  CHANNEL=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN query channels --chain $CONSUMER_CHAIN_ID")
  if echo "$CHANNEL" | grep -q "SUCCESS" && echo "$CHANNEL" | grep -q "channel-0"; then
    echo ">>> IBC Channels were successfully created."
    TEST_IBC_CHANNEL="true"
  else
    echo ">>> IBC Channels could not be created."
    TEST_IBC_CHANNEL="false"
  fi
}