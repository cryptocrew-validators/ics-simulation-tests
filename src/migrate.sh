set -e

function proposeUpgradeSovereign() {

# ACCOUNT=$(vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP --home $CONSUMER_HOME keys show consumer-chain-validator1 --keyring-backend test -a")
    
 cat > files/generated/upgrade_proposal.json <<EOT

  {
 "messages": [
  {
   "@type": "/cosmos.upgrade.v1beta1.MsgSoftwareUpgrade",
   "authority": "stride10d07y265gmmuvt4z0w9aw880jnsr700jefnezl",
   "plan": {
    "name": "$CONSUMER_UPGRADE_NAME",
    "time": "0001-01-01T00:00:00Z",
    "height": "$CONSUMER_UPGRADE_HEIGHT",
    "info": "",
    "upgraded_client_state": null
   }
  }
 ],
 "metadata": "ipfs://CID",
 "deposit": "10000000$CONSUMER_FEE_DENOM",
 "title": "$CONSUMER_UPGRADE_TITLE",
 "summary": "$CONSUMER_UPGRADE_SUMMARY"
}

EOT
  cat files/generated/upgrade_proposal.json
  
  vagrant scp files/generated/upgrade_proposal.json consumer-chain-validator1:/home/vagrant/upgrade_proposal.json

  # Create and submit the upgrade proposal
  echo "Submitting software upgrade proposal from consumer-chain-validator1..."
  vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP --home $CONSUMER_HOME tx gov submit-proposal /home/vagrant/upgrade_proposal.json --from consumer-chain-validator1 $CONSUMER_FLAGS"
  echo "Software upgrade proposal submitted"
}


# Vote yes on the software upgrade proposal from all sovereign validators
function voteSoftwareUpgradeProposal() {
  echo "Waiting for software upgrade proposal to go live..."
  sleep 7

  for i in $(seq 1 $NUM_VALIDATORS); do
    echo "Voting 'yes' from consumer-chain-validator${i}..."
    vagrant ssh consumer-chain-validator${i} -- "$CONSUMER_APP --home $CONSUMER_HOME tx gov vote 1 yes --from consumer-chain-validator${i} $CONSUMER_FLAGS"
  done
}

# Wait for proposal to pass
function waitForProposalUpgrade() {
  echo "Waiting for software upgrade proposal to pass on consumer-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP --home $CONSUMER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done
  echo "Software upgrade proposal passed"
}

# Switches out the old binary for the new binary to be ready post-upgrade
function switchBinaries() {
    echo "Switching out binary for new version on consumer-chain..."
    for i in $(seq 1 $NUM_VALIDATORS); do
        vagrant ssh consumer-chain-validator${i} -- mv /usr/local/bin/newbin /usr/local/bin/$CONSUMER_APP
    done
    echo "Successfully switched binaries"
}

# Generate and distribute ccv state
function fetchCCVState() {
  vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME q provider consumer-genesis consumer-chain -o json > $PROVIDER_HOME/config/ccv-state.json"
  vagrant scp provider-chain-validator1:$PROVIDER_HOME/config/ccv-state.json files/generated/ccv-state.json
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp files/generated/ccv-state.json consumer-chain-validator${i}:$CONSUMER_HOME/config/ccv-state.json
  done

}
# Create ccv.json by adding ccv state to genesis file
function applyCCVState() {
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' $CONSUMER_HOME/config/genesis.json $CONSUMER_HOME/config/ccv-state.json > $CONSUMER_HOME/config/ccv.json"
  done
}

# Restarting the sovereign chain (now consumer chain), after ccv.json has been added and the binary has been switched
function restartChain() {
  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant ssh consumer-chain-validator${i} -- "pkill $CONSUMER_APP"
    vagrant ssh consumer-chain-validator${i} -- "$CONSUMER_APP --home $CONSUMER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --grpc.address 0.0.0.0:9090> /var/log/consumer.log 2>&1 &"
    echo "[consumer-chain-validator${i}] started $CONSUMER_APP: watch output at /var/log/consumer.log"
  done
}

# Fetching the private validator keys from the provider chain validators and giving them to the consumer chain validators
function distributeProviderValidatorKeys() {
  # Key assignment is only tested on the first validator in the list,
  # so the other validators still need the validator keys from the provider-chain validators
  # If key assignment is set to true, the first consumer-chain validator is skipped when copying the keys from the provider-chain
  if $KEY_ASSIGNMENT; then
    j=2
  else
    j=1
  fi

  for i in $(seq $j $NUM_VALIDATORS); do
    vagrant scp provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json files/generated/provider_priv_validator_key${i}.json
  done
  for i in $(seq $j $NUM_VALIDATORS); do
    vagrant scp files/generated/provider_priv_validator_key${i}.json consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json
  done
}

function waitForUpgradeHeight() {
  echo "Waiting for sovereign chain to reach upgrade height..."
  SOVEREIGN_LATEST_HEIGHT=""
  while [[ ! $SOVEREIGN_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $SOVEREIGN_LATEST_HEIGHT -lt 1 ]] || [[ $SOVEREIGN_LATEST_HEIGHT -lt $CONSUMER_UPGRADE_HEIGHT ]]; do
    SOVEREIGN_LATEST_HEIGHT=$(vagrant ssh consumer-chain-validator1 -- 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
  done
  echo ">>> Sovereign chain has reached upgrade height. Latest block height: $SOVEREIGN_LATEST_HEIGHT"
}


