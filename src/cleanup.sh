set -e

# copy all generated files to ./tests
function copyGeneratedFiles() {
  echo "Success! Copying generated files to ./tests/* ..."
  find ./ -maxdepth 1 -type f ! \( -name destroy.sh -o -name README.md -o -name setup.sh -o -name test.sh -o -name Vagrantfile \) -exec cp {} ./tests \;
  echo "Success! Copying hermes_config.toml to ./tests/* ..."
  cp hermes_config.toml ./tests
}

function getLogs() {
  echo "Getting logs..."
  for i in $(seq 1 $NUM_VALIDATORS); do
    if [ $i -eq 1 ]; then
      vagrant scp provider-chain-validator${i}:/var/log/hermes.log ./tests/hermes.log
    fi
    vagrant scp provider-chain-validator${i}:/var/log/chain.log ./tests/chainlog_provider-chain-validator${i}.log
    vagrant scp consumer-chain-validator${i}:/var/log/hermes.log ./tests/chainlog_consumer-chain-validator${i}.log
  done
}

function cleanUp() {
  echo "Killing services..."
  for i in $(seq 1 $NUM_VALIDATORS); do
    if [ $i -eq 1 ]; then
      vagrant ssh provider-chain-validator${i} -- "sudo pkill hermes"
      echo "[provider-chain-validator${i}] stopped hermes"
    fi
    vagrant ssh provider-chain-validator${i} -- "sudo pkill $PROVIDER_APP"
    echo "[provider-chain-validator${i}] stopped $PROVIDER_APP"
    vagrant ssh consumer-chain-validator${i} -- "sudo pkill $CONSUMER_APP"
    echo "[consumer-chain-validator${i}] stopped $CONSUMER_APP"
  done
}