set -e

# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {
  PROP_TITLE="Create the Consumer chain"
  PROP_DESCRIPTION='This is the proposal to create the consumer chain \"consumer-chain\".'
  PROP_SUMMARY='Launching a consumer chain with an opt-in (top_N=0).'
  PROP_SPAWN_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 180))"') # leave extra time for pre-spawtime key-assignment test
  PROP_CONSUMER_BINARY_SHA256=$(vagrant ssh consumer-chain-validator1 -- "sha256sum /usr/local/bin/$CONSUMER_APP" | awk '{ print $1 }')
  PROP_CONSUMER_RAW_GENESIS_SHA256=$(sha256sum raw_genesis.json | awk '{ print $1 }')
  PROP_TOP_N=0
  if [ -z "$ORIG_PROP_NR" ]; then
    
    # Prepare proposal file
    PROP_CONSUMER_REDISTRIBUTION_FRACTION=0.75
    PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION=150
    PROP_HISTORICAL_ENTRIES=1000
    PROP_CCV_TIMEOUT_PERIOD="2419200s"
    PROP_TRANSFER_TIMEOUT_PERIOD="1800s"
    PROP_UNBONDING_PERIOD="10800s"
  else

    # Download original proposal and construct proposal file
    echo "Downloading ORIGINAL consumer addition proposal..."
    curl https://raw.githubusercontent.com/hyphacoop/ics-testnets/main/pss-devnet/devnet-optin-one/optin-one-proposal.json > original_prop.json
    # PROP_TITLE=$(jq -r '.proposal.content.title' original_prop.json)
    # PROP_DESCRIPTION=$(jq -r '.proposal.content.description' original_prop.json)

    PROP_CONSUMER_BINARY_SHA256=$(jq -r '.binary_hash' original_prop.json)
    PROP_CONSUMER_RAW_GENESIS_SHA256=$(jq -r '.genesis_hash' original_prop.json)
    PROP_CONSUMER_REDISTRIBUTION_FRACTION=$(jq -r '.consumer_redistribution_fraction' original_prop.json)
    PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION=$(jq -r '.blocks_per_distribution_transmission' original_prop.json)
    PROP_HISTORICAL_ENTRIES=$(jq -r '.historical_entries' original_prop.json)
    PROP_UNBONDING_PERIOD="10800s"
    PROP_CCV_TIMEOUT_PERIOD="2419200s"
    PROP_TRANSFER_TIMEOUT_PERIOD="1800s"
  fi

#   cat > prop.json <<EOT
# {
#   "title": "$PROP_TITLE",
#   "description": "$PROP_DESCRIPTION",
#   "summary": "$PROP_SUMMARY",
#   "chain_id": "consumer-chain",
#   "initial_height": {
#       "revision_height": 1
#   },
#   "genesis_hash": "$PROP_CONSUMER_BINARY_SHA256",
#   "binary_hash": "$PROP_CONSUMER_RAW_GENESIS_SHA256",
#   "spawn_time": "$PROP_SPAWN_TIME",
#   "consumer_redistribution_fraction": "$PROP_CONSUMER_REDISTRIBUTION_FRACTION",
#   "blocks_per_distribution_transmission": $PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION,
#   "historical_entries": $PROP_HISTORICAL_ENTRIES,
#   "ccv_timeout_period": $PROP_CCV_TIMEOUT_PERIOD,
#   "transfer_timeout_period": $PROP_TRANSFER_TIMEOUT_PERIOD,
#   "unbonding_period": $PROP_UNBONDING_PERIOD, 
#   "top_N": "$PROP_TOP_N",
#   "deposit": "10000000icsstake"
# }
# EOT
  cat > prop.json <<EOT
{
 "messages": [
        {
            "@type": "/cosmos.gov.v1.MsgExecLegacyContent",
            "content": {
                "@type": "/interchain_security.ccv.provider.v1.ConsumerAdditionProposal",
                "title": "$PROP_TITLE",
                "description": "$PROP_DESCRIPTION",
                "chain_id": "consumer-chain",
                "initial_height": {
                    "revision_number": "0",
                    "revision_height": "1"
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
                "top_N": 100
            },
            "authority": "cosmos10d07y265gmmuvt4z0w9aw880jnsr700j6zn9kn"
        }
    ],
 "metadata": "ipfs://CID",
 "deposit": "10000000icsstake",
 "title": "$PROP_TITLE",
 "summary": "$PROP_SUMMARY"
}
EOT


  cat prop.json
  
  vagrant scp prop.json provider-chain-validator1:/home/vagrant/prop.json

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
function waitForProposal() {
  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done

  echo "Consumer addition proposal passed"
}