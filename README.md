# Interchain Simulation Tests

This repository contains a test suite for a simulated process of migrating a standalone Cosmos SDK chain to a consumer chain that is being secured by a provider chain.

For clarification purposes:
*   Sovereign Chain = a standalone blockchain
*   Provider Chain = a blockchain that provides security to a consumer chain by sharing it's validator set
*   Consumer Chain = a blockchain which is being secured by the validator set of a provider chain

The test suite bootstraps a local provider testnet as well as a local sovereign testnet.
The sovereign chain proposes a `software-upgrade-proposal` that converts them to a consumer chain and the provider chains proposes a `consumer-addition-proposal`. Additionally, `key-assignment` features can be tested.

A test journal is written to `files/logs/result.log`

## Hardware Requirements
For a recommended setup with 5 consumer nodes and 5 provider nodes, the following requirements apply:
- 16GB RAM and a 4-core CPU (Minimum)
- 32GB RAM and an 8-core CPU (Recommended)
- (The test suite can be run with less than 5 validators, but then weird behaviour may appear.)
## Sofware Requirements
- [Vagrant](https://www.vagrantup.com/downloads.html)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)
- [jq](https://stedolan.github.io/jq/download)
- [moreutils](https://joeyh.name/code/moreutils)

## Prerequisites
If the test suite is run with the default IP-Address ranges for the virtual machines,
the `/etc/vbox/networks.conf` file must be altered to include the following line:  
`* 0.0.0.0/0 ::/0`  
If the file does not exist, it needs to be created first.

## Setup

1. Clone this repository:

```bash
git clone https://github.com/clemensgg/ics-simulation-tests
cd ics-simulation-tests
git switch ics-consumer-migration
```

## Configuration

Modify the `.env` file to set up the required environment variables. These variables determine the number of validators and the provider and consumer chains' repositories, versions, applications, home directories, Go sources, and genesis sources

If you wish to use your own consumer addition proposal, it needs to be put into `files/user`.

To lessen the strain on your internet connection and to speed up the setup process, it is recommended to use a caching server on your host machine.
In the `.env` file, change the variable `CACHE_SERVER` to `true`. Squid caching server needs to be installed on your machine.
On debian, you can install it with this command:

`apt install squid`

An example configuration file can be found in config/squid_example.conf.


## Running the Test

Run tests:
```bash
bash test.sh
```

_-> please note node provision with vagrant takes about 15mins_

The script will perform the following steps:

1. Load environment variables from the .env file.
2. Start the provider chain and wait for it to start producing blocks.
3. (Optional) Assigns a consumer key to validator 1 on the provider chain
3. Start the sovereign chain and wait for it to start producing blocks.
4. Proposes a software upgrade proposal on the sovereign chain.
5. Switches out the binaries on the sovereign chain for the upgraded binaries.
7. Propose a consumer addition proposal on the provider chain.
8. Once the consumer addition proposal has passed and the consumer spawn time has been reached, the ccv-state is queried on the provider chain and integrated into the genesis file of the consumer chain.
9. Once the sovereign chain has reached it's upgrade height it will restart with the same validator set to finish the post-upgrade block.
10. The sovereign chain will restart once more, now with the validator keys of the provider chain, and is now a consumer chain.
11. The test will gather the IBC client of the provider chain and the newly created IBC client of the consumer chain.
8. Create IBC paths between provider and consumer chain.
9. Start a persistent IBC relayer.
10. (Optional) Test key assignment post consumer chain migration.
11. **Upon successful completion, you should see the message "All tests passed!".**

Watch node output on provider chain validators: 
```sh
tail -f /var/log/chain.log
```
Watch node outpot on consumer chain validators pre-upgrade:
```sh
tail -f /var/log/sovereign.log
```
Watch node outpot on consumer chain validators post-upgrade:
```sh
tail -f /var/log/consumer.log
```
Watch relayer output on `provider-chain-validator1`: 
```sh
tail -f /var/log/hermes.log
```

---
Clean up:
```sh
bash destroy.sh
```
Destroy manually:
```
VBoxManage list runningvms | awk '{print $2;}' | xargs -I vmid VBoxManage controlvm vmid poweroff
VBoxManage list vms | awk '{print $2;}' | xargs -I vmid VBoxManage unregistervm --delete vmid
rm .provisioned
```

## License

This project is licensed under the Apache License 2.0.