set -e

# Get the client ids from both provider- and consumer-chain
# function fetchClientIDs() {
#   CLIENT_ID_PROVIDER=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME q provider list-consumer-chains -o .json | jq -r '.chains[0].client_id'")
#   CLIENT_ID_CONSUMER=$CLIENT_ID_PROVIDER
# }

# Prepare IBC relayer
function prepareRelayer() {
  echo "Preparing hermes IBC relayer..."
  vagrant ssh provider-chain-validator1 -- "echo $RELAYER_MNEMONIC > .mn && $HERMES_BIN --config $HERMES_CONFIG keys add --chain provider-chain --mnemonic-file .mn || true && $HERMES_BIN --config $HERMES_CONFIG keys add --chain consumer-chain --mnemonic-file .mn || true"

  # fetch relayer accounts for both chains
  # RELAYER_ACCOUNT_PROVIDER=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --json keys list --chain provider-chain | grep result | jq -r '.result.default.account'")
  # RELAYER_ACCOUNT_CONSUMER=$(vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --json keys list --chain consumer-chain | grep result | jq -r '.result.default.account'")
}


# Create the cross-chain-validation and transfer IBC-paths
function createIbcPaths() {
  echo "Fetching client ids for both chains..."
  CLIENT_ID_PROVIDER=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME q provider list-consumer-chains -o .json | jq -r '.chains[0].client_id'")
  CLIENT_ID_CONSUMER=$(vagrant ssh consumer-chain-validator1 -- 'grep "client state updated" /var/log/consumer.log | awk -F"client-id=" "{print \$2}" | awk "{print \$1}" | head -1')
  echo "Provider client ID: $CLIENT_ID_PROVIDER"
  echo "Consumer client ID: $CLIENT_ID_CONSUMER"

  echo "Creating CCV IBC Paths..."
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG create connection --a-chain consumer-chain --a-client $CLIENT_ID_CONSUMER --b-client $CLIENT_ID_PROVIDER"
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG create channel --a-chain consumer-chain --a-port consumer --b-port provider --order ordered --a-connection connection-0 --channel-version 1"
}

# Start IBC Relayer
function startRelayer() {
  echo "Starting relayer..."
  vagrant ssh provider-chain-validator1 -- "sudo touch /var/log/hermes.log && sudo chmod 666 /var/log/hermes.log"
  vagrant ssh provider-chain-validator1 -- "$HERMES_BIN --config $HERMES_CONFIG start > /var/log/hermes.log 2>&1 &"
  echo "[provider-chain-validator1] started hermes IBC relayer: watch output at /var/log/hermes.log"
}