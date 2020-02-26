#!/bin/bash

set -e

token=""
pair=""
owner=""
verbose=""
balances="y"
while [[ $# -gt 0 ]]; do
	case $1 in
		-o|--owner) owner=$2; shift;;
		--no-balances) balances="";;
		-v|--verbose) verbose="y";;
		-h|--help) cat << EOF
orders.sh - Retrieve list of current orders.

USAGE:
    $0 [OPTIONS] <TOKEN> [<PAIR>]

OPTIONS:
    -o, --owner         Filter orders to only match a specific owner
        --no-balances   Skip retrieving balances for crates
    -v, --verbose       Prints verbose log messages to STDERR
    -h, --help          Prints this help information

ARGUMENTS:
    TOKEN               The token to find orders for
    PAIR                Optionally only list orders matching a token pair

ENVIRONMENT:
    CONTRACT            The Gnosis Protocol exchange contract address, if the
                        environment variable is not set, the verified contract
                        address will be used.
    ETHEREUM_NODE_URL   The HTTP(S) URL of an ethereum node to use
    INFURA_PROJECT_ID   Optionally, an Infura project ID can be used to connect
                        to an Infura node
EOF
			exit
			;;
		*)
			if [[ -z "$token" ]]; then
				token="$1"
			elif [[ -z "$pair" ]]; then
				pair="$1"
			else
				>&2 cat << EOF
ERROR: Invalid option '$1'.
	   For more information try '$0 --help'
EOF
				exit 1
			fi
			;;
	esac
	shift
done

if [[ -z "$CONTRACT" ]]; then
	CONTRACT="0x6f400810b62df8e13fded51be75ff5393eaa841f"
fi
if [[ -z "$ETHEREUM_NODE_URL" ]]; then
	if [[ -z "$INFURA_PROJECT_ID" ]]; then
		cat << EOF
ERROR: Missing ETHEREUM_NODE_URL or INFURA_PROJECT_ID environment variables.
	   For more information try '$0 --help'
EOF
		exit 1
	fi
	ETHEREUM_NODE_URL="https://mainnet.infura.io/v3/$INFURA_PROJECT_ID"
fi

if [[ -z $token ]]; then
	>&2 cat << EOF
ERROR: Missing TOKEN argument.
	   For more information try '$0 --help'
EOF
	exit 1
fi

log () {
	if [[ "$verbose" == "y" ]]; then
		>&2 echo "DEBUG: $1"
	fi
}

graphql () {
	url=https://api.thegraph.com/subgraphs/name/gnosis/dfusion
	if [[ $1 == "-" ]]; then
		query="$(cat -)"
	else
		query="$1"
	fi
	escaped=$(echo "$query" | sed -E 's/([\\"])/\\\1/g' | sed -z -E 's/[\n\t]/ /g')
	curl -s -X POST $url --data-binary '{ "query": "query { '"$escaped"' }" }'
}

eth_call () {
	url=https://mainnet.infura.io/v3/$INFURA_PROJECT_ID
	curl -s -X POST -H "Content-type:application/json" --data '{"jsonrpc":"2.0","method":"eth_call","params":[{"data":"'$1'","to":"'"$CONTRACT"'"},"latest"],"id":1337}' $url
}

get_token_id () {
	token_id=$(graphql - << EOF |
		tokens(where: {symbol: "$1"}) {
			id
		}
EOF
		jq -r '.data.tokens[0].id'
	)

	if [[ $token_id == "null" ]]; then
		>&2 echo "ERROR: Token $1 is not listed on the exchange"
		exit 1
	fi

	echo $token_id
}

token_id=$(get_token_id $token)
if [[ -n $pair ]]; then
	pair_id=$(get_token_id $pair)
fi
log "using token ID(s) $token_id $pair_id"

get_where_clause () {
	where="where: {$1Token: \"$token_id\""
	if [[ -n $pair_id ]]; then
		where="$where, $2Token: \"$pair_id\""
	fi
	if [[ -n $owner ]]; then
		where="$where, owner: \"$owner\""
	fi
	where="$where}"

	echo $where
}

where_b=$(get_where_clause buy sell)
where_s=$(get_where_clause sell buy)
log "filtering by '$where_b || $where_s'"

props=$(cat << EOF
	owner { id }
	buyToken { address symbol decimals }
	sellToken { address symbol decimals }
	priceNumerator
	priceDenominator
	maxSellAmount
	soldVolume
EOF
)

orders=$(graphql - << EOF
	b: orders($where_b) { $props }
	s: orders($where_s) { $props }
EOF
)

accounts=$(echo "$orders" | jq "$(cat << EOF
	.data.b + .data.s
	| [ .[] | {
		owner: .owner.id,
		token: .sellToken.symbol,
		data: ("0xd4fac45d000000000000000000000000" + .owner.id[2:] + "000000000000000000000000" + .sellToken.address[2:])
	}]
	| unique_by(.data)
EOF
)")

a="{"
for account in $(echo "$accounts" | jq -r '.[] | @base64'); do
	_jq () {
		echo "$account" | base64 --decode | jq "$@"
	}

	if [[ $balances == "y" ]]; then
		log "getting $(_jq -r '.token') balance for $(_jq -r '.owner')"
		balance_hex=$(eth_call $(_jq -r '.data') | jq -r '.result')
		balance=$(python -c "print($balance_hex)")
	else
		balance="1e+78"
	fi
	name=$(_jq -r '.owner + .token')
	a="$a \"${name}\": $balance,"
done
accounts_json="$a \"x\":0}"

result=$(echo "$orders" | jq --argjson a "$accounts_json" "$(cat << EOF
	[.data.b[] | . + {
		price: (
			((.priceDenominator|tonumber) / pow(10; .sellToken.decimals|tonumber)) /
			((.priceNumerator|tonumber) / pow(10; .buyToken.decimals|tonumber))
		),
	}]
	+
	[.data.s[] | . + {
		price: (
			((.priceNumerator|tonumber) / pow(10; .buyToken.decimals|tonumber)) /
			((.priceDenominator|tonumber) / pow(10; .sellToken.decimals|tonumber))
		),
	}]
	| [ .[] | {
		owner: .owner.id,
		sell: .sellToken.symbol,
		buy: .buyToken.symbol,
		volume: ([((.maxSellAmount|tonumber) - (.soldVolume|tonumber)), 0] | max),
		price: .price,
		price_1: (1/.price)
	} | . + {
		balance: ([.volume, \$a[.owner + .sell]] | min),
	}]
EOF
)")

csv () {
	echo $1 | jq -r '(map(keys) | add | unique) as $cols | map(. as $row | $cols | map($row[.])) as $rows | $cols, $rows[] | @csv'
}

csv "$result"
