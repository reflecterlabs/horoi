#!/usr/bin/env bash
# Cheat-oracle: push a new BTC/USD price into OracleRelayer (Unichain Sepolia).
#
# Usage:
#   ./cheat_oracle.sh <delta_pct> [base]
#
# Examples:
#   ./cheat_oracle.sh -20            # current * 0.80  (BTC drops 20%)
#   ./cheat_oracle.sh +5             # current * 1.05  (BTC pumps 5%)
#   ./cheat_oracle.sh 0 60000        # set BTC to exactly $60,000
#   ./cheat_oracle.sh -10 50000      # set BTC to $50,000 * 0.90 = $45,000
#
# The script reads the current oracle price (or `base` if provided), applies the
# delta, and pushes the new value via OracleRelayer.updatePrice().
set -euo pipefail

# ---- Resolve project root + .env ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT/contracts/.env"
AGENT_ENV="$ROOT/agent/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: missing $ENV_FILE (need PRIVATE_KEY)" >&2
    exit 1
fi
if [[ ! -f "$AGENT_ENV" ]]; then
    echo "ERROR: missing $AGENT_ENV (need contract addresses)" >&2
    exit 1
fi

set -a
source "$ENV_FILE"
source "$AGENT_ENV"
set +a

ORACLE="${ORACLE_RELAYER_ADDRESS:?ORACLE_RELAYER_ADDRESS missing in agent/.env}"
WBTC="${WBTC_ADDRESS:?WBTC_ADDRESS missing}"
USDC="${USDC_ADDRESS:?USDC_ADDRESS missing}"
RPC="${RPC_URL:-https://sepolia.unichain.org}"
PK="${PRIVATE_KEY:?PRIVATE_KEY missing in contracts/.env}"

# ---- Args ----
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <delta_pct> [base_usd]" >&2
    echo "  delta_pct: signed integer, e.g. -20 or +5 or 0" >&2
    echo "  base_usd : optional override (otherwise read current oracle)" >&2
    exit 2
fi

DELTA_PCT="$1"
BASE_OVERRIDE="${2:-}"

# ---- Determine baseline (BTC/USD in human dollars) ----
if [[ -n "$BASE_OVERRIDE" ]]; then
    BASE_USD="$BASE_OVERRIDE"
    echo "Using provided base: \$${BASE_USD}"
else
    echo "Reading current oracle price…"
    PRICE_WAD=$(cast call --rpc-url "$RPC" "$ORACLE" "getPriceWad(address,address)(uint256)" "$WBTC" "$USDC")
    if [[ "$PRICE_WAD" == "0" ]]; then
        BASE_USD=60000
        echo "Oracle uninitialised — defaulting to baseline \$60000"
    else
        BASE_USD=$(python3 -c "print(int(int('$PRICE_WAD') / 10**18))")
        echo "Current oracle: \$${BASE_USD}"
    fi
fi

# ---- Compute new price (human dollars) ----
NEW_USD=$(python3 -c "
import decimal
decimal.getcontext().prec = 50
base = decimal.Decimal('$BASE_USD')
delta = decimal.Decimal('$DELTA_PCT') / decimal.Decimal('100')
new_p = base * (decimal.Decimal('1') + delta)
print(int(new_p))
")

# Sanity bounds
if [[ "$NEW_USD" -le 0 ]]; then
    echo "ERROR: computed new price <= 0" >&2
    exit 3
fi

NEW_WAD=$(python3 -c "
import decimal
decimal.getcontext().prec = 50
print(int(decimal.Decimal('$NEW_USD') * 10**18))
")

echo "Delta: ${DELTA_PCT}%  →  new price: \$${NEW_USD}  (WAD ${NEW_WAD})"

# ---- Push ----
echo "Calling OracleRelayer.updatePrice(WBTC, USDC, ${NEW_WAD})…"
TX=$(cast send \
    --rpc-url "$RPC" \
    --private-key "$PK" \
    --json \
    "$ORACLE" \
    "updatePrice(address,address,uint256)" \
    "$WBTC" "$USDC" "$NEW_WAD" \
    2>&1)

# Extract tx hash from json
TX_HASH=$(echo "$TX" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('transactionHash',''))" 2>/dev/null || echo "")
if [[ -n "$TX_HASH" ]]; then
    echo "Tx: $TX_HASH"
else
    echo "$TX"
fi

# ---- Verify ----
echo "Verifying…"
STORED_WAD=$(cast call --rpc-url "$RPC" "$ORACLE" "getPriceWad(address,address)(uint256)" "$WBTC" "$USDC")
STORED_USD=$(python3 -c "print(int(int('$STORED_WAD') / 10**18))")
echo "Stored: \$${STORED_USD} (WAD ${STORED_WAD})"
echo "Done."
