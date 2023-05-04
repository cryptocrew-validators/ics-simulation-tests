# KeyAssignment test function
function testKeyAssignment() {
  echo "Assigning Key: $1"
  TMP_DIR_EXISTS=$(vagrant ssh provider-chain-validator1 -- "[ -d /home/vagrant/tmp ] && echo '/home/vagrant/tmp directory exists' || echo '/home/vagrant/tmp directory does not exist, creating...'")
  echo $TMP_DIR_EXISTS
  if [[ "$1" == *"newkey"* ]]; then
    if [[ "$TMP_DIR_EXISTS" == *"exists"* ]]; then
      vagrant ssh provider-chain-validator1 -- "sudo rm -rf /home/vagrant/tmp"
    fi
    echo "Generating NEW key for KeyAssignment test on provider-chain-validator1"
    vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP init --chain-id provider-chain --home /home/vagrant/tmp tempnode && sudo chmod -R 777 /home/vagrant/tmp"
  elif [[ "$1" == *"samekey"* ]]; then
    echo "Using the PREVIOUS (SAME) key for KeyAssignment test on provider-chain-validator1, checking location..."
    if [[ "$TMP_DIR_EXISTS" == *"does not exist"* ]]; then
      vagrant ssh provider-chain-validator1 -- "sudo mkdir /home/vagrant/tmp && sudo cp -r $PROVIDER_HOME* /home/vagrant/tmp && sudo chmod -R 777 /home/vagrant/tmp"
    fi
  fi

  vagrant scp provider-chain-validator1:/home/vagrant/tmp/config/priv_validator_key.json priv_validator_key1_UPDATED_"$1".json

  UPDATED_PUBKEY_VALUE=$(cat priv_validator_key1_UPDATED_"$1".json | jq -r '.pub_key.value')
  UPDATED_PUBKEY='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"'$UPDATED_PUBKEY_VALUE'"}'
  echo "New PubKey: $UPDATED_PUBKEY_VALUE"

  echo "Assigning updated key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME tx provider assign-consensus-key consumer-chain "'"$UPDATED_PUBKEY"'" --from provider-chain-validator1 $PROVIDER_FLAGS

  sleep 2
  echo "Copying key $1 to consumer-chain-validator1"
  vagrant scp priv_validator_key1_UPDATED_"$1".json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json 
  sleep 2
}

function validateAssignedKey() {
  echo "Validating new pubkey."
  echo "Restarting $CONSUMER_APP on consumer-chain-validator1..."
  vagrant ssh consumer-chain-validator1 -- "sudo pkill $CONSUMER_APP"
  sleep 1
  vagrant ssh consumer-chain-validator1 -- "sudo $CONSUMER_APP --home $CONSUMER_HOME start --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 > /var/log/chain.log 2>&1 &"
  CONSUMER_PUBKEY=""
  while [ -z "$CONSUMER_PUBKEY" ]; do
    VALIDATOR_INFO=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.validator_info"')
    CONSUMER_PUBKEY=$(echo $VALIDATOR_INFO | jq -r ".pub_key.value")
    VOTING_POWER=$(echo $VALIDATOR_INFO | jq -r ".voting_power")
    sleep 2
  done

  echo "Consumer-chain-validator1 restarted, new pubkey: $CONSUMER_PUBKEY"
  if [[ "$CONSUMER_PUBKEY" != "$UPDATED_PUBKEY_VALUE" ]]; then
    echo "New validator pubkey does not match assigned key!"
    echo "New pubkey: $CONSUMER_PUBKEY"
    echo "Assigned pubkey: $UPDATED_PUBKEY_VALUE"
    exit 1
  fi

  count=0
  while [[ "$VP" == "0" ]] && [ $count -le 10 ]; do
    echo "Waiting up to 30 seconds for IBC valset update to arrive."
    VALIDATOR_INFO=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.validator_info"')
    VOTING_POWER=$(echo $VALIDATOR_INFO | jq -r ".voting_power")
    sleep 3
  done

  if [[ "$VP" == "0" ]]; then
    echo "Valset update not received on consumer-chain within 30 seconds!"
    echo "Check the relayer log on provider-chain-validator1: /var/log/relayer.sh"
    echo "If you can find the valset update in the relayer log, it has not been properly propagated on the consumer-chain! This could point to a possible issue with the consumer-chain software."
    exit 1
  fi
  echo "Key Assignment test passed!"
}