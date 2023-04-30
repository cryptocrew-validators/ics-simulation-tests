# Interchain Simulation Tests

This repository contains a test suite for interchain staking between a provider chain (Gaia) and a consumer chain (Neutron). The test simulates the process of creating a consumer chain and the validator key-assignment feature.

It bootstraps a local provider testnet with 3 validators, proposes a `consumer-addition-proposal`, tests the `key-assignment` feature and launches the `consumer-chain`

## Requirements

- [Vagrant](https://www.vagrantup.com/downloads.html)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)
- [jq](https://stedolan.github.io/jq/download/)

## Setup

1. Clone this repository:

```bash
git clone https://github.com/your-repo/interchain-staking-test.git
cd interchain-staking-test
```

## Configuration

Modify the .env file to set up the required environment variables. These variables determine the provider and consumer chains' repositories, versions, applications, home directories, Go sources, and genesis sources:

```ini
PROVIDER_REPO=https://github.com/cosmos/gaia
PROVIDER_VERSION=v9.0.3
PROVIDER_APP=gaiad
PROVIDER_HOME=/home/root/.gaia
PROVIDER_GO_SOURCE=https://go.dev/dl/go1.18.10.linux-amd64.tar.gz

CONSUMER_REPO=https://github.com/neutron-org/neutron
CONSUMER_VERSION=v1.0.0-rc1
CONSUMER_APP=neutrond
CONSUMER_HOME=/home/root/.neutron
CONSUMER_GO_SOURCE=https://go.dev/dl/go1.20.3.linux-amd64.tar.gz
CONSUMER_GENESIS_SOURCE=https://cloudflare-ipfs.com/ipfs/QmQZFY51F2nJYk8FixjR4MtWkmpGw5mGFUZrCQCyg64r76
```

## Running the Test

```bash
./test.sh
```

The script will perform the following steps:

1. Load environment variables from the .env file.
2. Start the provider chain and wait for it to produce blocks.
3. Propose a consumer addition proposal from provider validator 1.
4. Vote "yes" on the consumer addition proposal from all provider validators.
5. Prepare the consumer chain by copying private validator keys and finalizing the genesis.
6. Test key assignment pre consumer chain launch.
7. Start the consumer chain.
8. Test key assignment post consumer chain launch.
7. Upon successful completion, you should see the message "All tests passed!".

## License

This project is licensed under the Apache License 2.0.