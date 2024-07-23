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
  echo "Collecting logs..."
  vagrant scp provider-chain-validator1:/var/log/hermes.log files/logs/hermes.log

  for i in $(seq 1 $NUM_VALIDATORS); do
    vagrant scp provider-chain-validator${i}:/var/log/chain.log files/logs/chainlog_provider-chain-validator${i}.log
    echo "Wrote log of provider chain to: files/logs/chainlog_provider-chain-validator${i}.log"
    vagrant scp consumer-chain-validator${i}:/var/log/sovereign.log files/logs/consumerlog_consumer-chain-validator${i}-sovereign.log
    vagrant scp consumer-chain-validator${i}:/var/log/consumer.log files/logs/consumerlog_consumer-chain-validator${i}-consumer.log
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

function showResults() {
  echo "Test Results: "
  if [ "$TEST_PROVIDER_LAUNCH" == "true" ]; then
    echo "Provider chain launch: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_PROVIDER_LAUNCH" == "false" ]; then
    echo "Provider chain launch: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi
  
  if [ "$TEST_SOVEREIGN_LAUNCH" == "true" ]; then
    echo "Sovereign chain launch: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_SOVEREIGN_LAUNCH" == "false" ]; then
    echo "Sovereign chain launch: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_CONSUMER_MIGRATION" == "true" ]; then
    echo "Consumer chain launch: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_CONSUMER_MIGRATION" == "false" ]; then
    echo "Consumer chain launch: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_IBC_CONNECTION" == "true" ]; then
    echo "IBC connection creation: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_IBC_CONNECTION" == "false" ]; then
    echo "IBC connection creation: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_IBC_CHANNEL" == "true" ]; then
    echo "IBC channel creation: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_IBC_CHANNEL" == "false" ]; then
    echo "IBC channel creation: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_DELEGATION_CONSUMER" == "true" ]; then
    echo "Delegation update on consumer chain: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_DELEGATION_CONSUMER" == "false" ]; then
    echo "Delegation update on consumer chain: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi
  
  if [ "$TEST_JAIL_PROVIDER" == "true" ]; then
    echo "Validator jailing on provider chain: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_JAIL_PROVIDER" == "false" ]; then
    echo "Validator jailing on provider chain: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  if [ "$TEST_JAIL_CONSUMER" == "true" ]; then
    echo "Validator jailing on consumer chain: OK"
    TESTS_PASSED=$((TESTS_PASSED+1))
  elif [ "$TEST_JAIL_CONSUMER" == "false" ]; then
    echo "Validator jailing on consumer chain: FAILED"
    TESTS_FAILED=$((TESTS_FAILED+1))
  fi

  echo "Tests passed: $TESTS_PASSED"
  echo "Tests failed: $TESTS_FAILED"
}