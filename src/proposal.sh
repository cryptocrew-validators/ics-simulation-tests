set -e


function createConsumer() {
  SPAWN_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))"') # leave 120 sec for pre-spawtime key-assignment test
  cat > files/generated/create_consumer.json <<EOT
{
  "chain_id": "consumer-chain-1",
  "metadata": {
    "name": "consumer-chain-1",
    "description": "Adding consumer-chain-1",
    "metadata": "{}"
  },
  "initialization_parameters": {
    "initial_height": {
     "revision_number": 1,
     "revision_height": 1
    },
    "genesis_hash": "",
    "binary_hash": "",
    "spawn_time": "$SPAWN_TIME",
    "unbonding_period": 1209600000000000,
    "ccv_timeout_period": 2419200000000000,
    "transfer_timeout_period": 1800000000000,
    "consumer_redistribution_fraction": "0.5",
    "blocks_per_distribution_transmission": 10,
    "historical_entries": 10000,
    "distribution_transmission_channel": ""
  },
  "power_shaping_parameters": {
    "top_N": 0,
    "validators_power_cap": 100,
    "validator_set_cap": 100,
    "allowlist": [],
    "denylist": [],
    "min_stake": 0,
    "allow_inactive_vals": true
  }
}
EOT

  vagrant scp files/generated/create_consumer.json provider-chain-validator1:/home/vagrant/create_consumer.json

  # Create and submit the consumer addition proposal
  echo "Creating consumer from provider-chain-validator1... "
  vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME tx provider create-consumer /home/vagrant/create_consumer.json --from provider-chain-validator1 $PROVIDER_FLAGS"
  echo "Consumer created."

  optIn
  whiteListDenom
}

function calculateIbcDenom() {
  local path="transfer/channel-1"
  local denom=$CONSUMER_FEE_DENOM

  # Combine path and base denom
  local combined="${path}/${denom}"

  # Compute the SHA256 hash and convert to uppercase
  local hash=$(echo -n "$combined" | sha256sum | awk '{print $1}' | tr 'a-f' 'A-F')

  echo "ibc/${hash}"
}

function whiteListDenom() {
  CONSUMER_IBC_DENOM=$(calculateIbcDenom)
  cat > files/generated/register_denom.json <<EOT
{
    "messages": [
        {
            "@type": "/interchain_security.ccv.provider.v1.MsgChangeRewardDenoms",
            "denoms_to_add": [
             "$CONSUMER_IBC_DENOM"
            ],
            "denoms_to_remove": [],
            "authority": "cosmos10d07y265gmmuvt4z0w9aw880jnsr700j6zn9kn"
           }
       ],
    "metadata": "ipfs://CID",
    "deposit": "10000000icsstake",
    "title": "Change Reward Denoms",
    "summary": "Whitelisting the consumer token denom"
}
EOT

  vagrant scp files/generated/register_denom.json provider-chain-validator1:/home/vagrant/register_denom.json

  echo "Submitting MsgChangeRewardDenom from provider-chain-validator1..."
  vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal /home/vagrant/register_denom.json --from provider-chain-validator1 $PROVIDER_FLAGS"
  echo "Reward Denom Change submitted."

  voteForDenom
}

function voteForDenom() {
  echo "Waiting for Reward Denom Change proposal to go live..."
  sleep 7

  for i in $(seq 1 $NUM_VALIDATORS); do
    echo "Voting 'yes' from provider-chain-validator${i}..."
    vagrant ssh provider-chain-validator${i} -- "$PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS"
  done
}


# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {
  # PROP_TITLE="Create the Consumer chain"
  # PROP_DESCRIPTION='This is the proposal to create the consumer chain \"consumer-chain\".'
  
  # PROP_CONSUMER_BINARY_SHA256=
  # PROP_CONSUMER_RAW_GENESIS_SHA256=$(sha256sum raw_genesis.json | awk '{ print $1 }')
  # PROP_SOFT_OPT_OUT_THRESHOLD=0.05
  # if [ -z "$ORIG_PROP_NR" ]; then
    
    # Prepare proposal file
    # PROP_CONSUMER_REDISTRIBUTION_FRACTION=0.75
    # PROP_BLOCKS_PER_REDISTRIBUTION_FRACTION=150
    # PROP_HISTORICAL_ENTRIES=10

    # times-string would be better but currently gaiad wants nanoseconds here

  # else

    # use default values for proposal
    if [ -z "$CONSUMER_ICS_TYPE" ]; then
      CONSUMER_ICS_TYPE="rs"
    fi

    PROP_SPAWN_TIME=$(vagrant ssh consumer-chain-validator1 -- 'date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))"') # leave 120 sec for pre-spawtime key-assignment test
    PROP_TITLE="consumer-addition-proposal"
    PROP_DESCRIPTION="launch the $CONSUMER_ICS_TYPE consumer chain"
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

    # times-string would be better but currently gaiad wants nanoseconds here
    # SDK47: Error: can't unmarshal Any nested proto *v1.MsgExecLegacyContent: can't unmarshal Any nested proto *types.ConsumerAdditionProposal: 
    # bad Duration: time: missing unit in duration "1728000000000000"
    # PROP_UNBONDING_PERIOD=$((UNBONDING_PERIOD_SECONDS * 1000000000))
    # PROP_CCV_TIMEOUT_PERIOD=$((CCV_TIMEOUT_PERIOD_SECONDS * 1000000000))
    # PROP_TRANSFER_TIMEOUT_PERIOD=$((TRANSFER_TIMEOUT_PERIOD_SECONDS * 1000000000))
  # fi
  if [[ "$CONSUMER_ICS_TYPE" == "rs" ]]; then
    echo "CONSUMER_ICS_TYPE set to RS -> defaulting to PSS TOP-95 chain"
    CONSUMER_ICS_TYPE=pss
    CONSUMER_TOPN_VALUE=95
  fi
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

  cat > files/generated/prop.json <<EOT
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

  # deprecated
#     echo "Quick simulation: creating REPLICATED SECURITY consumer addition proposal from provider validator 1..."
#     cat > prop.json <<EOT
# {
#   "title": "$PROP_TITLE",
#   "description": "$PROP_DESCRIPTION",
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
#   "soft_opt_out_threshold": "$PROP_SOFT_OPT_OUT_THRESHOLD",
#   "deposit": "10000000icsstake"
# }
# EOT
#   fi
  # cat files/generated/prop.json
  
  vagrant scp files/generated/prop.json provider-chain-validator1:/home/vagrant/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal /home/vagrant/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS"
  echo "Consumer addition proposal submitted"
}

function optIn() {
  echo "Waiting for consumer to be created..."
  sleep 7

  for i in $(seq 1 $NUM_VALIDATORS); do
    echo "Opting in from provider-chain-validator${i}..."
    vagrant ssh provider-chain-validator${i} -- "$PROVIDER_APP --home $PROVIDER_HOME tx provider opt-in 0 --from provider-chain-validator${i} $PROVIDER_FLAGS"
  done
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