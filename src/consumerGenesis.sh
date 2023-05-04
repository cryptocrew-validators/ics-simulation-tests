function manipulateConsumerGenesis() {
  echo "Manipulating consumer raw_genesis file"

  if [ ! -f "raw_genesis.json" ]; then
    # Download and manipulate consumer genesis file
    echo "Downloading consumer genesis file"
    wget -4 $CONSUMER_GENESIS_SOURCE -O raw_genesis.json
  else
    echo "Using local raw_genesis.json file"
  fi

  # Update supply to empty array to pass genesis supply check
  echo "Setting supply to []"
  jq '.app_state.bank.supply = []' raw_genesis.json | sponge raw_genesis.json

  # Update chain_id to `consumer-chain`
  echo "Setting chain_id: consumer-chain"
  jq --arg chainid "consumer-chain" '.chain_id = $chainid' raw_genesis.json | sponge raw_genesis.json
  
  # Update genesis_time to 1min in the past
  GENESIS_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) - 60))"')
  echo "Setting genesis time: $GENESIS_TIME" 
  jq --arg time "$GENESIS_TIME" '.genesis_time = $time' raw_genesis.json | sponge raw_genesis.json

  # Add relayer account and balances
  echo "Adding relayer account & balances"
  vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP keys delete relayer --keyring-backend test -y || true"
  CONSUMER_RELAYER_ACCOUNT_ADDRESS=$(vagrant ssh consumer-chain-validator1 -- "echo "$RELAYER_MNEMONIC" | $CONSUMER_APP keys add relayer --recover --keyring-backend test --output json")
  
  cat > relayer_account_consumer.json <<EOT
{
  "@type": "/cosmos.auth.v1beta1.BaseAccount",
  "address": "$(echo $CONSUMER_RELAYER_ACCOUNT_ADDRESS | jq -r '.address')",
  "pub_key": null,
  "account_number": "1",
  "sequence": "0"
}
EOT

  cat > relayer_balance_consumer.json <<EOT
{
  "address": "$(echo $CONSUMER_RELAYER_ACCOUNT_ADDRESS | jq -r '.address')",
  "coins": [
    {
      "denom": "$CONSUMER_FEE_DENOM",
      "amount": "150000000"
    }
  ]
}
EOT

  cat relayer_account_consumer.json
  cat relayer_balance_consumer.json
  jq '.app_state.auth.accounts += [input]' raw_genesis.json relayer_account_consumer.json > raw_genesis_modified.json && mv raw_genesis_modified.json raw_genesis.json
  jq '.app_state.bank.balances += [input]' raw_genesis.json relayer_balance_consumer.json > raw_genesis_modified.json && mv raw_genesis_modified.json raw_genesis.json
  rm relayer_account_consumer.json relayer_balance_consumer.json
}

manipulateConsumerGenesis