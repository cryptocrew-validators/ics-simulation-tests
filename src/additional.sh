
function delegate() {
    VALIDATOR_ADDRESS=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME keys show provider-chain-validator1 --bech val --keyring-backend test -a")
    #echo "VALIDATOR ADDRESS: $VALIDATOR_ADDRESS"


    VOTING_POWER_PRE=$(checkVotingPower "consumer-chain-validator1")
    VOTING_POWER_POST=0

    echo "Running delegate transaction..."
    vagrant ssh provider-chain-validator2 -- "$PROVIDER_APP --home $PROVIDER_HOME tx staking delegate $VALIDATOR_ADDRESS 5000000icsstake --chain-id provider-chain --from provider-chain-validator2 --keyring-backend test -y"
    echo "Delegate transaction complete."

    echo "Waiting for transaction to validator set change to arrive on consumer chain..."

    MAX_ITERATIONS=30
    ITERATION=0

    while [[ $ITERATION < $MAX_ITERATIONS ]] && [[ $VOTING_POWER_POST <= $VOTING_POWER_PRE ]]; do
        VOTING_POWER_POST=$(checkVotingPower "consumer-chain-validator1")
        sleep 2
        ITERATION=$((ITERATION+1))
    done

    if [[ $ITERATION == $MAX_ITERATIONS ]]; then
        echo ">>> Delegation failed, could not confirm Voting Power update on consumer chain after 60 seconds."
        TEST_DELEGATION_CONSUMER="false"
    else
        echo ">>> Delegation has successfully arrive on consumer chain." 
        echo "Voting Power before delegation: $VOTING_POWER_PRE"
        echo "Voting Power after delegation: $VOTING_POWER_POST"
        TEST_DELEGATION_CONSUMER="true"
    fi
}

function jailConsumer() {
    echo "Running jail on consumer chain..."
    #VALIDATOR_ADDRESS=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME keys show provider-chain-validator1 --bech val --keyring-backend test -a")
    
    echo "Stopping $CONSUMER_APP..."
    vagrant ssh consumer-chain-validator1 -- "pkill $CONSUMER_APP"

    echo "Copying duplicate private validator key to validator..."
    vagrant scp files/generated/priv_validator_key2.json consumer-chain-validator1:$CONSUMER_HOME/config/priv_validator_key.json

    echo "Restarting $CONSUMER_APP..."
    vagrant ssh consumer-chain-validator1 -- "$CONSUMER_APP --home $CONSUMER_HOME start --rpc.laddr tcp://0.0.0.0:26657 --grpc.address 0.0.0.0:9090> /var/log/consumer.log 2>&1 &"
    

    MAX_ITERATIONS=30
    ITERATION=0
    VOTING_POWER=$(checkVotingPower "consumer-chain-validator1")

    while [[ $ITERATION < $MAX_ITERATIONS ]] && [[ $VOTING_POWER != 0 ]]; do
        VOTING_POWER=$(checkVotingPower "consumer-chain-validator1")
        ITERATION=$((ITERATION+1))
        sleep 2
    done

    if [[ $VOTING_POWER == 0 ]]; then
        echo "Validator has been jailed."
    else
        echo "Could not confirm that validator has been jailed within 60 seconds."
    fi
}

function jailProvider() {
    echo "Running jail on provider chain..."
    #VALIDATOR_ADDRESS=$(vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME keys show provider-chain-validator1 --bech val --keyring-backend test -a")
    
    echo "Stopping $PROVIDER_APP..."
    vagrant ssh provider-chain-validator1 -- "pkill $PROVIDER_APP"

    echo "Copying duplicate private validator key to validator..."
    vagrant scp files/generated/priv_validator_key2.json provider-chain-validator1:$PROVIDER_HOME/config/priv_validator_key.json

    echo "Restarting $PROVIDER_APP..."
    vagrant ssh provider-chain-validator1 -- "$PROVIDER_APP --home $PROVIDER_HOME start --log_level trace --pruning nothing --rpc.laddr tcp://0.0.0.0:26657 --grpc.address 0.0.0.0:9090> /var/log/chain.log 2>&1 &"
    
    echo "Waiting for validator to get jailed on provider chain..."
    MAX_ITERATIONS=30
    ITERATION=0
    VOTING_POWER_PROVIDER=$(checkVotingPower "provider-chain-validator1")
    VOTING_POWER_CONSUMER=$(checkVotingPower "consumer-chain-validator2")

    while [[ $ITERATION < $MAX_ITERATIONS ]] && [[ $VOTING_POWER_PROVIDER != 0 ]]; do
        VOTING_POWER_PROVIDER=$(checkVotingPower "provider-chain-validator1")
        ITERATION=$((ITERATION+1))
        sleep 2
    done

    if [[ $VOTING_POWER_PROVIDER == 0 ]]; then
        echo ">>> Validator has been successfully jailed on provider chain."
        TEST_JAIL_PROVIDER="true"
    else
        echo ">>> Jailing failed, could not confirm that validator has been jailed within 60 seconds on provider chain."
        TEST_JAIL_PROVIDER="false"
    fi

    echo "Waiting for validator set change to arrive on consumer chain..."
    MAX_ITERATIONS=30
    ITERATION=0

    while [[ $ITERATION < $MAX_ITERATIONS ]] && [[ $VOTING_POWER_CONSUMER != 0 ]]; do
        VOTING_POWER_CONSUMER=$(checkVotingPower "consumer-chain-validator2")
        ITERATION=$((ITERATION+1))
        sleep 2
    done

    if [[ $VOTING_POWER_CONSUMER == 0 ]]; then
        echo ">>> Validator has been successfully jailed on consumer chain."
        TEST_JAIL_CONSUMER="true"
    else
        echo ">>> Jailing failed, could not confirm that validator has been jailed within 60 seconds on consumer chain."
        TEST_JAIL_PROVIDER="false"
    fi
    
}

function checkVotingPower() {
    if [ $# -eq 0 ]; then
        echo "No validator name provided"
        return 1
    fi

    local validator_name=$1
    local VOTING_POWER=$(vagrant ssh "$validator_name" -- 'curl -s http://localhost:26657/status | jq -r ".result.validator_info.voting_power"')
    echo "$VOTING_POWER"
}



