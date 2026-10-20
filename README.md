# Tombola contracts (Pons launch)

The on-chain half of [Tombola](https://tombola.lol), a lottery token launched on [Pons V2](https://pons.fun) on
Robinhood Chain. Trading tax on the token lands in Pons' fee escrow as ETH; these contracts split it into prize
pots and pay out draws whose randomness is drand's, committed to before it exists and verified on chain.

Three contracts, all immutable, no owner, no upgrade path, no withdraw:

| Contract | Role |
| --- | --- |
| [`src/TombolaSplitter.sol`](src/TombolaSplitter.sol) | Pons' `creatorFeeRecipient`. `harvest()` (anyone) claims the escrow's ETH and splits it 73.33% / 20% / 6.67% to the draw's regular pot, mega pot and the team fee wallet. |
| [`src/TombolaDraw.sol`](src/TombolaDraw.sol) | Holds the two pots and the draw ledger. The keeper `commit`s a draw to a future drand round, then `settle`s it with drand's signature, the Merkle root of the published eligibility list and the winner's leaf proof. Pays the winner. |
| [`src/DrandBeacon.sol`](src/DrandBeacon.sol) | Verifies drand `evmnet` rounds (BLS on BN254, via the vendored randa-mu library) and stores each proven round's randomness. Already deployed on Robinhood Chain at `0xaf4fe3E1C2B4a6176392291704Fe4b87Df3b9A0E`; reused as is. |

[`DESIGN.md`](DESIGN.md) is the design note: why Tombola moved from an in-token tax to Pons' creator tax, and what
changed.

## Build and test

```sh
git clone --recurse-submodules https://github.com/JJ-ME55/tombola-contracts
cd tombola-contracts
forge build
forge test        # 19 tests, including a real evmnet round from test/fixtures/evmnet.json
```

Solidity 0.8.26, EVM `cancun`, `via_ir`, `bytecode_hash = "none"`. The only submodule is forge-std (pinned to
`b013eff2`). The BLS library is vendored in [`vendor/bls-solidity`](vendor/bls-solidity/VENDORED.md) (randa-mu's
bls-solidity at `11af179a`, MIT, unchanged).

## How a draw works

1. **Fees arrive.** Every Tombola trade pays Pons' creator tax (5%) into the Pons fee escrow for the splitter.
   Anyone calls `TombolaSplitter.harvest()`: it claims and forwards the ETH via `fundRegular()` / `fundMega()`
   and a plain send to the team wallet (rounding dust goes to the team, nothing stays in the splitter).
2. **Commit.** At a due slot the keeper calls `commit(track, snapshotTime, drandRound, amount)`. The contract
   requires `snapshotTime <= block.timestamp`, `beacon.roundTime(drandRound) >= snapshotTime + COMMIT_DELAY`
   (10 minutes), that the round isn't already proven on chain, that `amount <= pot[track]`, and one open draw
   per track. `amount` moves from the pot into `reserved`. The snapshot is the chain state at the last block with
   `timestamp <= snapshotTime`.
3. **Snapshot.** Once the drand round is published, the keeper rebuilds the eligibility list from the token's
   `Transfer` logs (algorithm below), publishes it (every wallet, balance, hold start, weight, plus the root), and
   picks the winner.
4. **Settle.** `settle(id, drandSignature, root, totalWeight, winner, cumulativeBefore, weight, proof)`:
   - `beacon.prove(round, signature)` verifies the BLS signature (reverts `InvalidSignature` on a bad one) and
     stores `randomness = keccak256(signature)`.
   - `randomWord = uint256(keccak256(abi.encode(randomness, id)))`, `target = randomWord % totalWeight`.
   - The leaf `keccak256(bytes.concat(keccak256(abi.encode(winner, cumulativeBefore, weight))))` must verify
     against `root` (OpenZeppelin sorted-pair Merkle), with `weight > 0` and `cumulativeBefore + weight <= totalWeight`.
   - `target` must fall in `[cumulativeBefore, cumulativeBefore + weight)`.
   - The draw records root, total weight, random word and winner; the prize leaves `reserved` and is sent to the
     winner with a 50,000 gas stipend. A failed send is credited to `unclaimed[winner]`, claimable by anyone for them.
5. **Nobody eligible:** `rollover(id, signature, root)` proves the round, pins the (empty-list) root and returns
   the prize to its pot.
6. **Something is wrong:** the guardian (a cold wallet) may `cancel(id)` a committed, unsettled draw, returning the
   prize to the pot. Seven days after the round's time anyone may, so a dead keeper can't lock a pot.

`solvent()` states the accounting invariant: `balance >= potRegular + potMega + reserved + unclaimedTotal`.

## Trust model

The contracts enforce:

- the drand round was committed on chain before anyone could know it (round time at least 10 minutes after the
  snapshot, and not yet proven);
- the randomness is drand's (BLS verified on chain) and the winner's index is `randomWord mod totalWeight`;
- the winner is in the list the keeper pinned, with the weight the keeper claims, and the selection index falls in
  the winner's cumulative range;
- pots only leave as settled prizes (or back into the pot on rollover/cancel). No privileged withdraw exists.

The contracts cannot enforce that the pinned list is complete and the weights honest: the keeper is trusted to
build an honest list. Anyone can prove a dishonest list from public data (the token's `Transfer` logs plus drand)
within minutes, and the guardian can cancel a committed draw before it settles. The keeper can also choose
*when* to commit (and so which future round), but not what that round will contain.

Privileged roles, all immutable: `keeper` (commit, settle, rollover), `guardian` (cancel before settlement),
`splitter` (named but not gated: anyone may fund the pots). The team fee wallet only receives.

## Verifying a draw yourself

The keeper's verifier (`verify-draw.mjs`, Node + viem) will be mirrored into this repository; until then the
algorithm is specified here so a reader can recompute every draw from an RPC and drand alone.

Inputs: the `TombolaDraw` address, the token address, the block the token launched at, and the draw `id`.

1. `getDraw(id)` gives `snapshotTime`, `drandRound`, `amount`, `root`, `totalWeight`, `randomWord`, `winner`.
2. **Commit-before-randomness.** `beacon.roundTime(drandRound) >= snapshotTime + COMMIT_DELAY`, and the block of
   the `Committed(id, ...)` log has a timestamp below `roundTime`.
3. **Randomness.** Fetch drand's signature for `drandRound` from `https://api.drand.sh/v2/beacons/evmnet/rounds/<round>`.
   `beacon.isValid(round, signature)` must be true, `beacon.randomness(round) == keccak256(signature)`, and
   `randomWord == uint256(keccak256(abi.encode(randomness, id)))`.
4. **Snapshot block.** The last block whose timestamp is `<= snapshotTime`.
5. **Replay.** Take every `Transfer(from, to, value)` of the token from launch through the snapshot block, in
   (blockNumber, logIndex) order, skipping `value == 0`, and keep `{balance, holdStart}` per address:
   - for `from != 0`: `balance -= value; holdStart = blockTimestamp` (any outgoing transfer resets the clock);
   - for `to != 0`: if `balance == 0` then `holdStart = blockTimestamp` (first tokens since empty start the
     clock; later inbound transfers don't restart it); `balance += value`.
   Infra addresses (the Pons curve and pool) are excluded; each published snapshot names the excluded set.
6. **Weights.** For each address, `weightFor(balance, holdStart, snapshotTime)`, exactly as the contract's pure
   function: 0 if `balance < 10,000e18` or held under 30 minutes; otherwise `balance * mult / 1e18` with
   `mult = 3e18` once held 72 hours, else `1e18 + held * 2e18 / 72 hours`.
7. **The list.** Eligible wallets (weight > 0) sorted by ascending address; `cumulativeBefore` is the running sum;
   `totalWeight` is the final sum. Leaf `i = keccak256(bytes.concat(keccak256(abi.encode(address, cumulativeBefore, weight))))`.
   Pad the leaves to a power of two by repeating the last leaf; parent = `keccak256(min(a,b) ++ max(a,b))`. The
   root must equal the draw's `root` and the sum its `totalWeight`. An empty list pins `keccak256("")`.
8. **The winner.** `target = randomWord % totalWeight`; the winner is the row with
   `cumulativeBefore <= target < cumulativeBefore + weight`. It must equal the draw's `winner`, and the
   `Settled` log must show that address paid `amount`.

## Deploying

`script/DeployPons.s.sol` deploys `TombolaDraw` and `TombolaSplitter` against the existing beacon (environment:
`BEACON`, `KEEPER`, `GUARDIAN`, `TEAM_FEE_WALLET`, `PONS_ESCROW`); the two reference each other, so the splitter's
address is predicted from the deployer's next nonce. `script/LaunchOnPons.s.sol` launches the token on Pons V2
with the splitter as `creatorFeeRecipient`.

## Audit scope

`src/TombolaDraw.sol` and `src/TombolaSplitter.sol` are the new code. `src/DrandBeacon.sol` and the vendored BLS
library were part of the earlier Tombola design and have been reviewed before; they are included so the system
can be read and tested whole.

## License

MIT.
