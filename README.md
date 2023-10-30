# Interchain Simulation Tests

This repository contains a test suite for a simulated process of bootstrapping an ICS consumer chain that is being secured by a provider chain.

--> Find the sovereign-to-consumer migration on the [`ics-consumer-migration`](https://github.com/cryptocrew-validators/ics-simulation-tests/tree/ics-consumer-migration) branch.

For clarification purposes:
*   Provider Chain = a blockchain that provides security to a consumer chain by sharing it's validator set
*   Consumer Chain = a blockchain which is being secured by the validator set of a provider chain

The test suite bootstraps a local provider testnet.
The provider chains proposes a `consumer-addition-proposal`. Additionally, `key-assignment` features can be tested.

A test journal is written to `files/logs/result.log`

## Hardware Requirements
For a recommended setup with 4 consumer nodes and 4 provider nodes, the following requirements apply:
- at least 32GB RAM and a Quad Core CPU
- (The test suite can be run with less than 4 validators, but then weird behaviour may appear.)

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


## Running the Test

Run tests:
```bash
bash test.sh
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
11. **Upon successful completion, you should see the message "All tests passed!".**

Watch node output on validators: 
```sh
tail -f /var/log/chain.log
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