Utility scrips for querying dfusion graph.

# `prices.sh`

Gets all historical batches where a solution pair was traded and reports the
total volumes as well as buy and sell prices in CSV format:

```
./prices.sh DAI USDC
```

## Requirements

Install cURL and jq with yout favourite package manager:

```
sudo apt install curl jq
```
