#!/bin/bash

set -e

if [[ $# -ne 2 ]]; then
	>&2 cat << EOF
prices.sh - Retrieve historical price information for a token pair.

USAGE:
    $0 <BUYTOKEN> <SELLTOKEN>

ARGUMENTS:
    BUYTOKEN        The buy token symbol
    SELLTOKEN       The sell token symbol

EXAMPLE:
    $0 sETH WETH
EOF
	exit 1
fi

graphql () {
	URL=https://api.thegraph.com/subgraphs/name/gnosis/dfusion
	curl -s -X POST $URL --data-binary @- << EOF
{
	"query": "query { $1 }"
}
EOF
}

get_token_id () {
	token_id=$(graphql "tokens(where: {symbol: \\\"$1\\\"}) { id }" | jq -r '.data.tokens[0].id')
	if [[ $token_id == "null" ]]; then
		>&2 echo "ERROR: Token $1 is not listed on the exchange"
		exit 1
	fi

	echo $token_id
}

buy_token=$(get_token_id $1)
sell_token=$(get_token_id $2)

orders=$(graphql "orders(where: {buyToken:\\\"$buy_token\\\", sellToken:\\\"$sell_token\\\"}) { trades { buyVolume, sellVolume, tradeBatchId } }")

trades=$(echo $orders | jq '[.data.orders[].trades[]]')
batches=$(echo $trades | jq 'group_by(.tradeBatchId) | map({"batch": .[0].tradeBatchId|tonumber, trades:[.[] | {buy:.buyVolume|tonumber,sell:.sellVolume|tonumber}]})')
totals=$(echo $batches | jq 'map({batch, buyVolume:([.trades[]|.buy]|add), sellVolume:([.trades[]|.sell]|add)})')
prices=$(echo $totals | jq 'map(. + {buyPrice:(.sellVolume/.buyVolume), sellPrice:(.buyVolume/.sellVolume)})')

prices=$(echo $prices | jq 'map(. + {batchStart: (.batch * 300)|todate, batchEnd: ((.batch+1)*300)|todate})')

echo $prices | jq -r '(map(keys) | add | unique) as $cols | map(. as $row | $cols | map($row[.])) as $rows | $cols, $rows[] | @csv'
