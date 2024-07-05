#!/bin/bash

. .env

echo ">>> RESETTING CHAINS"
for i in $(seq 1 $NUM_VALIDATORS); do
  echo "Resetting provider-chain-validator${i}..."
  vagrant ssh provider-chain-validator${i} -- "pkill $PROVIDER_APP || true && $PROVIDER_APP tendermint unsafe-reset-all --home $PROVIDER_HOME"
  echo "Resetting $CONSUMER_CHAIN_ID-validator${i}..."
  vagrant ssh consumer-chain-validator${i} -- "pkill $CONSUMER_APP || true && $CONSUMER_APP tendermint unsafe-reset-all --home $CONSUMER_HOME"
done

echo "Cleaning up generated files..."
rm prop.json > /dev/null 2>&1
rm raw_genesis.json > /dev/null 2>&1
rm final_genesis.json > /dev/null 2>&1
rm result.log > /dev/null 2>&1
rm generated/* > /dev/null 2>&1

echo ">>> RESET COMPLETED"