set -e

# KeyAssignment test function
function assignConsumerKey() {
  # echo "Assigning Key: $1"
  # TMP_HOME=/home/vagrant/tmp
  # TMP_DIR_EXISTS=$(vagrant ssh provider-chain-validator1 -- "[ -d $TMP_HOME ] && echo '$TMP_HOME directory exists' || echo '$TMP_HOME directory does not exist, creating...'")
  # echo $TMP_DIR_EXISTS
  # if [[ "$1" == *"newkey"* ]]; then
  #   if [[ "$TMP_DIR_EXISTS" == *"exists"* ]]; then
  #     vagrant ssh provider-chain-validator1 -- "rm -rf $TMP_HOME"
  #   fi
  #   echo "Generating NEW key for KeyAssignment test on provider-chain-validator1"
  #   vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP init --chain-id provider-chain --home $TMP_HOME tempnode && sudo chmod -R 766 $TMP_HOME"
  # elif [[ "$1" == *"samekey"* ]]; then
  #   echo "Using the PREVIOUS (SAME) key for KeyAssignment test on provider-chain-validator1, checking location..."
  #   if [[ "$TMP_DIR_EXISTS" == *"does not exist"* ]]; then
  #     vagrant ssh provider-chain-validator1 -- "mkdir $TMP_HOME && cp -r $PROVIDER_HOME* $TMP_HOME && sudo chmod -R 766 $TMP_HOME"
  #   fi
  # fi

  echo "Fetching consumer pub key from consumer-chain" 
  CONSUMER_PUBKEY=$(vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP tendermint show-validator --home $CONSUMER_HOME")
  echo "CONSUMER_PUBKEY: $CONSUMER_PUBKEY"

  echo "Assigning consumer pub key to validator on provider-chain"
  vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP tx provider assign-consensus-key consumer-chain '$CONSUMER_PUBKEY' --from provider-chain-validator1 --keyring-backend test --chain-id provider-chain --home $PROVIDER_HOME -y"
  sleep 5

  echo "Confirming that the key has been assigned..."
  PROVIDER_VALCONSADDR=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP tendermint show-address --home $PROVIDER_HOME")
  CONSUMER_VALCONSADDR=$(vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP tendermint show-address --home $CONSUMER_HOME")
  CONSUMER_ADDR=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP query provider validator-consumer-key consumer-chain $PROVIDER_VALCONSADDR")
  echo "consumer_address: $CONSUMER_VALCONSADDR"
  echo "$CONSUMER_ADDR"
}

function copyConsumerKey() {
  echo "Copying key $1 to consumer-chain-validator1"
  vagrant scp files/generated/priv_validator_key1_UPDATED_"$1".json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json
}

# Checks if the key has actually been assigned on the consumer chain
function validateAssignedKey() {
  set -e
  echo "Restarting $CONSUMER_APP on consumer-chain-validator1..."
  vagrant ssh consumer-chain-validator1 -- "sudo pkill $CONSUMER_APP"
  sleep 1
  vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP --home $CONSUMER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 > /var/log/consumer.log 2>&1 &"
  echo "Restarted consumer-chain-validator1."

  echo "Validating key assignment consumer-chain-validator1: $1"

  UPDATED_PUBKEY_VALUE=$(cat files/generated/provider_priv_validator_key1.json | jq -r '.pub_key.value')
  UPDATED_PUBKEY='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"'$UPDATED_PUBKEY_VALUE'"}'
  
  CONSUMER_PUBKEY=""
  while [ -z "$CONSUMER_PUBKEY" ]; do
    VALIDATOR_INFO=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.validator_info"')
    CONSUMER_PUBKEY=$(echo $VALIDATOR_INFO | jq -r ".pub_key.value")
    VOTING_POWER=$(echo $VALIDATOR_INFO | jq -r ".voting_power")
    sleep 2
  done
  
  echo "New pubkey: $CONSUMER_PUBKEY"
  echo "Assigned pubkey: $UPDATED_PUBKEY_VALUE"
  if [[ "$CONSUMER_PUBKEY" != "$UPDATED_PUBKEY_VALUE" ]]; then
    echo "New validator pubkey does not match assigned key!"
    exit 1
  fi

  count=0
  while [[ "$VOTING_POWER" == "0" ]]; do
    if [ $count -lt 1 ]; then
      echo "Waiting up to 60 seconds for IBC valset update to arrive."
    fi
    VALIDATOR_INFO=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.validator_info"')
    VOTING_POWER=$(echo $VALIDATOR_INFO | jq -r ".voting_power")
    sleep 3
    count=$((count+1))
    if [ $count -gt 20 ]; then
      break
    fi
  done

  if [[ "$VOTING_POWER" == "0" ]]; then
    echo "Valset update not received on consumer-chain within 60 seconds!"
    echo "Check the relayer log on provider-chain-validator1: /var/log/hermes.log"
    echo "If you can find the valset update in the relayer log, it has not been properly propagated on the consumer-chain! This could point to a possible issue with the consumer-chain software."
    exit 1
  else
    echo "Voting power: $VOTING_POWER"
    echo "Key Assignment test passed!"
  fi
}