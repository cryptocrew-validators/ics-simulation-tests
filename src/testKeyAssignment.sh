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

  UPDATED_PUBKEY='{"@type":"/cosmos.crypto.ed25519.PubKey","key":"'$(cat priv_validator_key1_UPDATED_"$1".json | jq -r '.pub_key.value')'"}'
  echo "New PubKey: $UPDATED_PUBKEY"

  echo "Assigning updated key on provider-chain-validator1"
  vagrant ssh provider-chain-validator1 -- sudo $PROVIDER_APP --home $PROVIDER_HOME tx provider assign-consensus-key consumer-chain "'"$UPDATED_PUBKEY"'" --from provider-chain-validator1 $PROVIDER_FLAGS

  sleep 2
  echo "Copying key $1 to consumer-chain-validator1"
  vagrant scp priv_validator_key1_UPDATED_"$1".json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json 
}