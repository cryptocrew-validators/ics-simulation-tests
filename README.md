# Interchain Simulation Tests

This repository contains a test suite for interchain staking between a provider chain (Gaia) and a consumer chain (Neutron). The test simulates the process of creating a consumer chain and the validator key-assignment feature.

It bootstraps a local provider testnet with 3 validators, proposes a `consumer-addition-proposal`, tests the `key-assignment` feature and launches the `consumer-chain`

## Requirements

- min 12 core CPU, 64GB RAM

- [Vagrant](https://www.vagrantup.com/downloads.html)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)
- [jq](https://stedolan.github.io/jq/download/)

## Setup

1. Clone this repository:

```bash
git clone https://github.com/clemensgg/ics-simulation-tests
cd ics-simulation-tests
```

## Configuration

Modify the `.env` file to set up the required environment variables. These variables determine the provider and consumer chains' repositories, versions, applications, home directories, Go sources, and genesis sources

## Running the Test

```bash
./test.sh
```

_-> please note node provision with vagrant takes about 15mins_

The script will perform the following steps:

1. Load environment variables from the .env file.
2. Start the provider chain and wait for it to produce blocks.
3. Propose a consumer addition proposal from provider validator 1.
4. Vote "yes" on the consumer addition proposal from all provider validators.
5. Prepare the consumer chain by copying private validator keys and finalizing the genesis.
6. Test key assignment pre consumer chain launch.
7. Start the consumer chain.
8. Create IBC paths between provider and consumer chain.
9. Start a persistent IBC relayer.
10. Test key assignment post consumer chain launch.
**11. Upon successful completion, you should see the message "All tests passed!".**

Watch node output on each validator: 
```sh
tail -f/var/log/chain.log
```
Watch relayer output on `provider-chain-validator1`: 
```sh
tail -f/var/log/relayer.log
```

## License

This project is licensed under the Apache License 2.0.