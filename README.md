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
forge test        # 24 tests, including a real evmnet round from test/fixtures/evmnet.json
```

Solidity 0.8.26, EVM `cancun`, `via_ir`, `bytecode_hash = "none"`. The only submodule is forge-std (pinned to
`b013eff2`). The BLS library is vendored in [`vendor/bls-solidity`](vendor/bls-solidity/VENDORED.md) (randa-mu's
bls-solidity at `11af179a`, MIT, unchanged).

## How a draw works

1. **Fees arrive.** Every Tombola trade pays Pons' creator tax (5%) into the Pons fee escrow for the splitter.
   Anyone calls `TombolaSplitter.harvest()`: it claims and forwards the ETH via `fundRegular()` / `fundMega()`
   and a plain send to the team wallet (rounding dust goes to the team). If the team wallet rejects the send, its
   share waits in the splitter as `teamOwed` (anyone may retry with `payTeam()`); the pots are funded regardless.
2. **Snapshot, then commit.** At a due slot the keeper rebuilds the eligibility list from the token's `Transfer`
   logs at `snapshotTime` (algorithm below), publishes it (every wallet, balance, hold start, weight, plus the root),
   and calls `commit(track, snapshotTime, drandRound, amount, root, totalWeight)`. The contract requires
   `snapshotTime <= block.timestamp` and at most `MAX_SNAPSHOT_AGE` (30 minutes) old,
   `beacon.roundTime(drandRound) >= snapshotTime + COMMIT_DELAY` **and** `>= block.timestamp + COMMIT_DELAY`
   (10 minutes), `roundTime <= block.timestamp + MAX_LEAD` (1 day), that the round isn't already proven on chain,
   `amount <= pot[track]` (and below 2^128), one open draw per track, and a consistent list: `totalWeight == 0`
   pins exactly `EMPTY_ROOT = keccak256("")`, anything else pins a non-zero, non-empty root. `amount` moves from
   the pot into `reserved`. The snapshot is the chain state at the last block with `timestamp <= snapshotTime`.
3. **The window.** Between the commit and the round (at least 10 minutes) the list is public and the randomness
   does not exist yet. Anyone can recompute the list; the guardian may `cancel(id)` a draw whose list is wrong.
4. **Settle.** Once the round is published the keeper calls `settle(id, drandSignature, winner, cumulativeBefore, weight, proof)`:
   - `beacon.prove(round, signature)` verifies the BLS signature (reverts `InvalidSignature` on a bad one) and
     stores `randomness = keccak256(signature)`.
   - `randomWord = uint256(keccak256(abi.encode(randomness, id)))`, `target = randomWord % totalWeight` with the
     **pinned** `totalWeight`.
   - The leaf `keccak256(bytes.concat(keccak256(abi.encode(winner, cumulativeBefore, weight))))` must verify
     against the **pinned** `root` (OpenZeppelin sorted-pair Merkle), with `weight > 0` and
     `cumulativeBefore + weight <= totalWeight`.
   - `target` must fall in `[cumulativeBefore, cumulativeBefore + weight)`; the winner may not be the zero address,
     the draw contract or the splitter (the keeper excludes them from the list).
   - The draw records the random word and winner; the prize leaves `reserved` and is sent to the winner with a
     50,000 gas stipend. A failed send is credited to `unclaimed[winner]`: claimable by anyone for them
     (`claim`), redirectable by the winner itself (`redirectCredit`, for contracts that can't receive plain ETH),
     and returned to the regular pot by anyone after a year uncollected (`expireCredit`).
5. **Nobody eligible:** a draw committed with `totalWeight == 0` can only be `rollover(id, signature)`-ed: it
   proves the round for the record and returns the prize to its pot. A draw with an eligible list cannot be rolled
   over, so a known winner can't be re-drawn.
6. **Something is wrong:** the guardian (a cold wallet) may `cancel(id)` a committed draw **only while its round is
   still in the future**; once the round's time has passed nobody can cancel (the outcome is public), until seven
   days later, when anyone may, so a dead keeper can't lock a prize. The prize returns to its pot.
7. **Keeper rotation:** the guardian may `setKeeper()` when no draw is open (a leaked hot key, a new server).

`solvent()` states the accounting invariant: `balance >= potRegular + potMega + reserved + unclaimedTotal`.

## Trust model

The contracts enforce:

- the list (root, total weight) and the drand round were committed on chain before anyone could know the round
  (round time at least 10 minutes after both the snapshot and the commit block, at most a day ahead, not yet
  proven), and the snapshot is at most 30 minutes older than the commit;
- the randomness is drand's (BLS verified on chain) and the winner's index is `randomWord mod` the pinned total;
- the winner is in the pinned list with the weight the keeper claimed, and the selection index falls in the
  winner's cumulative range;
- a rollover is only possible for a draw pinned as empty, and no cancel is possible between the round's time and
  seven days after it;
- pots only leave as settled prizes (or back into the pot on rollover/cancel/expiry). No privileged withdraw exists.

The contracts cannot enforce that the pinned list is complete and the weights honest: the keeper is trusted to
build an honest list. Anyone can prove a dishonest list from public data (the token's `Transfer` logs) in the
window between the commit and the round, and the guardian can cancel it in that window. The keeper can choose
*when* to commit (within the slot's lateness), but neither which outcome a round will give nor, once it is known,
whether to accept it. A leaked keeper key can commit a dishonest list; the guardian's window and a rotation are the
answer, not the contract. A lost keeper key with no rotation freezes the pots: the guardian must rotate it.

Privileged roles: `keeper` (commit, settle, rollover; replaceable by the guardian between draws), `guardian`
(immutable: cancel before the round, rotate the keeper), `splitter` (immutable, named but not gated: anyone may
fund the pots). The team fee wallet only receives.

## Verifying a draw yourself

The keeper's verifier (`verify-draw.mjs`, Node + viem) will be mirrored into this repository; until then the
algorithm is specified here so a reader can recompute every draw from an RPC and drand alone.

Inputs: the `TombolaDraw` address, the token address, the block the token launched at, and the draw `id`.

1. `getDraw(id)` gives `snapshotTime`, `drandRound`, `amount`, `root`, `totalWeight`, `randomWord`, `winner`.
2. **Commit-before-randomness.** `beacon.roundTime(drandRound) >= snapshotTime + COMMIT_DELAY`; the block of
   the `Committed(id, ...)` log has a timestamp at least `COMMIT_DELAY` below `roundTime` and at most
   `MAX_SNAPSHOT_AGE` above `snapshotTime`; the log's `root` and `totalWeight` equal the draw's.
3. **Randomness.** Fetch drand's signature for `drandRound` from `https://api.drand.sh/v2/beacons/evmnet/rounds/<round>`.
   `beacon.isValid(round, signature)` must be true, `beacon.randomness(round) == keccak256(signature)`, and
   `randomWord == uint256(keccak256(abi.encode(randomness, id)))`.
4. **Snapshot block.** The last block whose timestamp is `<= snapshotTime`.
5. **Replay.** Take every `Transfer(from, to, value)` of the token from launch through the snapshot block, in
   (blockNumber, logIndex) order, skipping `value == 0`, and keep `{balance, holdStart}` per address:
   - for `from != 0`: `balance -= value; holdStart = blockTimestamp` (any outgoing transfer resets the clock);
   - for `to != 0`: if `balance == 0` then `holdStart = blockTimestamp` (first tokens since empty start the
     clock; later inbound transfers don't restart it); `balance += value`.
   Infra addresses are excluded and each published snapshot names the set: the Pons curve, the Uniswap v4 PoolManager,
   Pons' locker, the draw contract, the splitter, the zero and dead addresses.
6. **Weights.** For each address, `weightFor(balance, holdStart, snapshotTime)`, exactly as the contract's pure
   function: 0 if `balance < 10,000e18` or held under 30 minutes; otherwise `balance * mult / 1e18` with
   `mult = 3e18` once held 72 hours, else `1e18 + held * 2e18 / 72 hours`.
7. **The list.** Eligible wallets (weight > 0) sorted by ascending address; `cumulativeBefore` is the running sum;
   `totalWeight` is the final sum. Leaf `i = keccak256(bytes.concat(keccak256(abi.encode(address, cumulativeBefore, weight))))`.
   Pad the leaves to a power of two by repeating the last leaf; parent = `keccak256(min(a,b) ++ max(a,b))`. The
   root must equal the draw's `root` and the sum its `totalWeight` (both pinned at commit). An empty list pins
   `keccak256("")` with `totalWeight` 0, and such a draw is rolled over, never settled.
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
