## UR Contracts

## Mantlescan - Addresses

- CryptoDeposit: https://mantlescan.xyz/address/0xd08B421A33F9b09A59E2ebf72afEF2365ce5b083
- URAccount: https://mantlescan.xyz/address/0x4a05148119683E0A41b52fb973EEF0EE81536c47
- CardAuthorizationMarqeta: https://mantlescan.xyz/address/0xb9d38DDE25f67D57af5b91C254F869F90d483d05
- Fiat24CNH: https://mantlescan.xyz/address/0xa0af0C397CB0A52F5E8Bc7BB89068dDDfaE9F211
- Fiat24USD: https://mantlescan.xyz/address/0xD598839598bBF508b97697b7D9e80054D4bcaaCC

## Usage

### Dependency

```shell
# forge install Uniswap/v3-core --no-commit
# forge install Uniswap/v3-periphery --no-commit
# forge install openzeppelin/openzeppelin-contracts@v4.4.1 --no-commit
# forge install openzeppelin/openzeppelin-contracts-upgradeable@v4.4.1 --no-commit
# npm install @layerzerolabs/oapp-evm-upgradeable

forge install
npm install

# forge remappings > remappings.txt
# forge remove openzeppelin/openzeppelin-contracts -f
# forge remove openzeppelin/openzeppelin-contracts-upgradeable -f
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
$ forge test -vvvv --match-contract Fiat24CardReserveTest --match-test test_DepositReserve
$ forge test -vvv --fork-url mantle
```

### Format

```shell
$ forge fmt src
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
