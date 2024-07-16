set -e

# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {

  PROP_SPAWN_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))"') # leave 120 sec for pre-spawtime key-assignment test
  PROP_TITLE="consumer-addition-proposal"
  PROP_DESCRIPTION="launch the consumer chain"
  PROP_CONSUMER_BINARY_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sha256sum /usr/local/bin/$CONSUMER_APP" | awk '{ print $1 }')
  PROP_CONSUMER_RAW_GENESIS_SHA256=$(sha256sum files/generated/raw_genesis_consumer.json | awk '{ print $1 }')
  PROP_CONSUMER_REDISTRIBUTION_FRACTION="0.75"
  PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION="100"
  PROP_HISTORICAL_ENTRIES="10000"
  PROP_UNBONDING_PERIOD="10800s"
  PROP_CCV_TIMEOUT_PERIOD="2419200s"
  PROP_TRANSFER_TIMEOUT_PERIOD="1800s"

  # Or: download original proposal and constuct proposal file
  if [ ! -z "$ORIG_PROP_SOURCE" ]; then
    echo "Downloading ORIGINAL consumer addition proposal..."
    curl -s $ORIG_PROP_SOURCE > original_prop.json
    PROP_TITLE=$(jq -r '.proposal.content.title' original_prop.json)
    PROP_DESCRIPTION=$(jq -r '.proposal.content.description' original_prop.json)

    PROP_CONSUMER_BINARY_SHA256=$(jq -r '.proposal.content.binary_hash' original_prop.json) 
    PROP_CONSUMER_RAW_GENESIS_SHA256=$(jq -r '.proposal.content.genesis_hash' original_prop.json)
    PROP_CONSUMER_REDISTRIBUTION_FRACTION=$(jq -r '.proposal.content.consumer_redistribution_fraction' original_prop.json)
    PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION=$(jq -r '.proposal.content.blocks_per_distribution_transmission' original_prop.json )
    PROP_HISTORICAL_ENTRIES=$(jq -r '.proposal.content.historical_entries' original_prop.json)

    # Extract durations in seconds
    PROP_UNBONDING_PERIOD=$(jq -r '.proposal.content.unbonding_period' original_prop.json)
    PROP_CCV_TIMEOUT_PERIOD=$(jq -r '.proposal.content.ccv_timeout_period' original_prop.json)
    PROP_TRANSFER_TIMEOUT_PERIOD=$(jq -r '.proposal.content.transfer_timeout_period' original_prop.json)
  fi

  # Or: use prop.json passed to /user/prop.json
  if [ -e "files/user/prop.json" ]; then
    cp files/user/prop.json files/generated/prop.json
  else

    if [ -z "$CONSUMER_TOPN_VALUE" ]; then
      echo "CONSUMER_TOPN_VALUE not set for top-n PSS consumer chain, defaulting to 80"
      CONSUMER_TOPN_VALUE=80
    fi
    if [[ "$CONSUMER_TOPN_VALUE" != 0 ]]; then
      echo "Quick simulation: creating PSS TOP-N consumer addition proposal from provider validator 1..."
    fi
    if [[ "$CONSUMER_TOPN_VALUE" == 0 ]]; then
      echo "Quick simulation: creating PSS OPT-IN consumer addition proposal from provider validator 1..."
    fi

    REVISION_NUMBER=0
    if [[ "$CONSUMER_CHAIN_ID" =~ -[0-9]+$ ]]; then
      REVISION_NUMBER=$(echo "$CONSUMER_CHAIN_ID" | grep -oP '-\K[0-9]+')
    fi

    cat > files/generated/prop.json <<EOT
{
 "messages": [
        {
            "@type": "/cosmos.gov.v1.MsgExecLegacyContent",
            "content": {
                "@type": "/interchain_security.ccv.provider.v1.ConsumerAdditionProposal",
                "title": "$PROP_TITLE",
                "description": "$PROP_DESCRIPTION",
                "chain_id": "$CONSUMER_CHAIN_ID",
                "initial_height": {
                    "revision_number": "$REVISION_NUMBER",
                    "revision_height": "$(($CONSUMER_UPGRADE_HEIGHT+3))"
                },
                "genesis_hash": "$PROP_CONSUMER_RAW_GENESIS_SHA256",
                "binary_hash": "$PROP_CONSUMER_BINARY_SHA256",
                "spawn_time": "$PROP_SPAWN_TIME",
                "unbonding_period": "$PROP_UNBONDING_PERIOD",
                "ccv_timeout_period": "$PROP_CCV_TIMEOUT_PERIOD",
                "transfer_timeout_period": "$PROP_TRANSFER_TIMEOUT_PERIOD",
                "consumer_redistribution_fraction": "$PROP_CONSUMER_REDISTRIBUTION_FRACTION",
                "blocks_per_distribution_transmission": $PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION,
                "historical_entries": $PROP_HISTORICAL_ENTRIES,
                "distribution_transmission_channel": "",
                "top_N": $CONSUMER_TOPN_VALUE
            },
            "authority": "cosmos10d07y265gmmuvt4z0w9aw880jnsr700j6zn9kn"
        }
    ],
 "metadata": "ipfs://CID",
 "deposit": "10000000icsstake",
 "title": "$PROP_TITLE",
 "summary": "$PROP_DESCRIPTION"
}
EOT

  fi
  
  vagrant scp files/generated/prop.json provider-chain-validator1:/home/vagrant/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal /home/vagrant/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS"
  echo "Consumer addition proposal submitted"
}

# Vote yes on the consumer addition proposal from all provider validators
function voteConsumerAdditionProposal() {
  echo "Waiting for consumer addition proposal to go live..."
  sleep 7

  for i in $(seq 1 $NUM_VALIDATORS); do
    echo "Voting 'yes' from provider-chain-validator${i}..."
    vagrant ssh provider-chain-validator${i} -- "$PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS"
  done
}

# Wait for proposal to pass
function waitForProposalConsumer() {
  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done

  echo "Consumer addition proposal passed"
}