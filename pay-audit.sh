#!/usr/bin/env bash
# Pays IMD 0.5 IMD from the DEPLOYER wallet to open the swarm audit of this repository (job.open@job-1), with the
# exact request in imd-audit-request.json, which IMD's free check already passed. Run it yourself, from this folder:
#   bash pay-audit.sh
# The deployer must hold at least 0.5 IMD and a little ETH on Robinhood Chain. It re-runs IMD's free check first and
# stops on any blocker. Once the request is mined it can't be taken back: four specialists audit the pinned commit,
# a judge ranks what they found, and the report is public at GET https://api.imd.fun/jobs/<id>/report.md.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ../.env; set +a

CAST="${CAST:-$HOME/.foundry/bin/cast.exe}"; command -v "$CAST" >/dev/null 2>&1 || CAST=cast
RPC=https://rpc.mainnet.chain.robinhood.com
INTAKE=0xa43e6f75ee006411f79ac1c84120606c2330de82   # IMD Intake v2 (every chain)
IMD=0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127      # IMD on Robinhood Chain
PRICE=500000000000000000                            # 0.5 IMD
REQ=imd-audit-request.json
BODY=$(python -c "import json,sys; print(json.dumps(json.load(open('$REQ')), separators=(',',':')))")

echo "payer:   $DEPLOYER_ADDRESS"
echo "IMD:     $("$CAST" call $IMD 'balanceOf(address)(uint256)' "$DEPLOYER_ADDRESS" --rpc-url $RPC)"
echo "request: $(python -c "import json; r=json.load(open('$REQ')); print(r['template'], r['repoUrl'], r['baseCommit'][:10])")"

echo "IMD's free check:"
BLOCKERS=$(curl -s -X POST https://api.imd.fun/requests/check -H 'Content-Type: application/json' \
  -d "{\"action\":\"job.open\",\"input\":$BODY}" | python -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('blockers')))")
echo "  blockers: $BLOCKERS"
[ "$BLOCKERS" = "[]" ] || { echo "IMD reports blockers: not paying."; exit 1; }

read -r -p "Pay 0.5 IMD and open the audit now? Type PAY to continue: " ok
[ "$ok" = "PAY" ] || { echo "Stopped, nothing sent."; exit 1; }

"$CAST" send $IMD 'approve(address,uint256)' $INTAKE $PRICE --rpc-url $RPC --private-key "$DEPLOYER_KEY" >/dev/null
echo "approved the intake to take 0.5 IMD"
TX=$("$CAST" send $INTAKE 'request(bytes32,bytes,(address,bytes4),address,uint256)' \
  "$("$CAST" format-bytes32-string 'job.open@job-1')" "$("$CAST" from-utf8 "$BODY")" \
  '(0x0000000000000000000000000000000000000000,0x00000000)' $IMD $PRICE \
  --rpc-url $RPC --private-key "$DEPLOYER_KEY" --json | python -c "import json,sys; d=json.load(sys.stdin); d=d.get('data',d); d=d[0] if isinstance(d,list) else d; print(d.get('transactionHash'), d.get('status'))")
echo "audit requested: $TX"
echo "Send this transaction hash to Claude. The job id comes from the intake's event / GET https://api.imd.fun/jobs;"
echo "the report is at GET https://api.imd.fun/jobs/<id>/report.md once the judge is accepted."
