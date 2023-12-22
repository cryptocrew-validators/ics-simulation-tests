set -e

function clearFilesAndLogs() {
    echo "Clearing generated files and logs..."

    # Enable nullglob for this function
    shopt -s nullglob

    # Remove files in files/generated and files/logs
    rm -f files/generated/*
    rm -f files/logs/*

    # Disable nullglob after use
    shopt -u nullglob

    echo "All generated files and logs have been removed."
}

function getLogs() {
  echo "Getting logs..."
  vagrant scp provider-chain-validator1:/var/log/hermes.log files/logs/hermes.log

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp provider-chain-validator${i}:/var/log/chain.log files/logs/chainlog_provider-chain-validator${i}.log
    echo "Wrote log of provider chain to: files/logs/chainlog_provider-chain-validator${i}.log"
    vagrant scp consumer-chain-validator${i}:/var/log/chain.log files/logs/consumerlog_consumer-chain-validator${i}.log
    echo "Wrote log of consumer chain to: files/logs/consumerlog_consumer-chain-validator${i}.log"
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

# copy all generated files to ./tests
function copyGeneratedFiles() {
  echo "Copying generated files to ./tests/*"
  find ./ -maxdepth 1 -type f ! \( -name destroy.sh -o -name result.log -o -name .env -o -name .provisioned -o -name .first_run -o -name .first_run -o -name .gitignore -o -name README.md -o -name hermes_config.toml -o -name setup.sh -o -name test.sh -o -name Vagrantfile \) -exec mv {} ./tests \;
  echo "Copying hermes_config.toml to ./tests/*"
  cp hermes_config.toml ./tests
  echo "Copying .env to ./tests/env"
  cp .env ./tests/env
  echo "Copying result.log to ./tests"
}