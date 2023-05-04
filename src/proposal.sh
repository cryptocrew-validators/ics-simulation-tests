# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {
  PROP_TITLE="Create the Consumer chain"
  PROP_DESCRIPTION='This is the proposal to create the consumer chain \"consumer-chain\".'
  PROP_SPAWN_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))"') # leave 120 sec for pre-spawtime key-assignment test
  PROP_CONSUMER_BINARY_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sudo sha256sum /usr/local/bin/$CONSUMER_APP" | awk '{ print $1 }')
  PROP_CONSUMER_RAW_GENESIS_SHA256=$(sha256sum raw_genesis.json | awk '{ print $1 }')
  PROP_SOFT_OPT_OUT_THRESHOLD=0.05
  if [ -z "$ORIG_PROP_NR" ]; then
    
    # Prepare proposal file
    PROP_CONSUMER_REDISTRIBUTION_FRACTION=0.75
    PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION=150
    PROP_HISTORICAL_ENTRIES=10

    # times-string would be better but currently gaiad wants nanoseconds here
    PROP_CCV_TIMEOUT_PERIOD=2419200000000000
    PROP_TRANSFER_TIMEOUT_PERIOD=600000000000
    PROP_UNBONDING_PERIOD=1728000000000000
  else

    # Download original proposal and constuct proposal file
    echo "Downloading ORIGINAL consumer addition proposal..."
    curl $ORIG_REST_ENDPOINT/cosmos/gov/v1beta1/proposals/$ORIG_PROP_NR > original_prop.json
    # PROP_TITLE=$(jq -r '.proposal.content.title' original_prop.json)
    # PROP_DESCRIPTION=$(jq -r '.proposal.content.description' original_prop.json)

    PROP_CONSUMER_BINARY_SHA256=$(jq -r '.proposal.content.binary_hash' original_prop.json)
    PROP_CONSUMER_RAW_GENESIS_SHA256=$(jq -r '.proposal.content.genesis_hash' original_prop.json)
    PROP_CONSUMER_REDISTRIBUTION_FRACTION=$(jq -r '.proposal.content.consumer_redistribution_fraction' original_prop.json)
    PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION=$(jq -r '.proposal.content.blocks_per_distribution_transmission' original_prop.json)
    PROP_HISTORICAL_ENTRIES=$(jq -r '.proposal.content.historical_entries' original_prop.json)

    # Extract durations in seconds
    UNBONDING_PERIOD_SECONDS=$(jq -r '.proposal.content.unbonding_period | rtrimstr("s")' original_prop.json)
    CCV_TIMEOUT_PERIOD_SECONDS=$(jq -r '.proposal.content.ccv_timeout_period | rtrimstr("s")' original_prop.json)
    TRANSFER_TIMEOUT_PERIOD_SECONDS=$(jq -r '.proposal.content.transfer_timeout_period | rtrimstr("s")' original_prop.json)

    # times-string would be better but currently gaiad wants nanoseconds here
    PROP_UNBONDING_PERIOD=$((UNBONDING_PERIOD_SECONDS * 1000000000))
    PROP_CCV_TIMEOUT_PERIOD=$((CCV_TIMEOUT_PERIOD_SECONDS * 1000000000))
    PROP_TRANSFER_TIMEOUT_PERIOD=$((TRANSFER_TIMEOUT_PERIOD_SECONDS * 1000000000))
  fi

  cat > prop.json <<EOT
{
  "title": "$PROP_TITLE",
  "description": "$PROP_DESCRIPTION",
  "chain_id": "consumer-chain",
  "initial_height": {
      "revision_height": 1
  },
  "genesis_hash": "$PROP_CONSUMER_BINARY_SHA256",
  "binary_hash": "$PROP_CONSUMER_RAW_GENESIS_SHA256",
  "spawn_time": "$PROP_SPAWN_TIME",
  "consumer_redistribution_fraction": "$PROP_CONSUMER_REDISTRIBUTION_FRACTION",
  "blocks_per_distribution_transmission": $PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION,
  "historical_entries": $PROP_HISTORICAL_ENTRIES,
  "ccv_timeout_period": $PROP_CCV_TIMEOUT_PERIOD,
  "transfer_timeout_period": $PROP_TRANSFER_TIMEOUT_PERIOD,
  "unbonding_period": $PROP_UNBONDING_PERIOD, 
  "soft_opt_out_threshold": "$PROP_SOFT_OPT_OUT_THRESHOLD",
  "deposit": "10000000icsstake"
}
EOT
  cat prop.json
  
  vagrant scp prop.json provider-chain-validator1:/home/vagrant/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal consumer-addition /home/vagrant/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS"
  echo "Consumer addition proposal submitted"
}

# Vote yes on the consumer addition proposal from all provider validators
function voteConsumerAdditionProposal() {
  echo "Waiting for consumer addition proposal to go live..."
  sleep 7

  for i in $(seq 1 $CHAIN_NUM_VALIDATORS); do
    echo "Voting 'yes' from provider-chain-validator${i}..."
    vagrant ssh provider-chain-validator${i} -- "sudo $PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS"
  done
}

# Wait for proposal to pass
function waitForProposal() {
  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh provider-chain-validator1 -- "sudo $PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done

  echo "Consumer addition proposal passed"

  echo "Waiting 1 block for everything to be propagated..."
  sleep 6
}