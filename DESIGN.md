# Tombola on Pons V2

The IMD launch (job fd4dd4be, launch 2326) was parked by IMD's audit judge: a sell tax charged on top of the amount
breaks "sell your whole balance", and a tax taken out of the amount breaks Uniswap v4's settlement. Neither is
fixable without giving up the sell tax, which is the point of the design. So Tombola launches on Pons V2 instead,
where the tax is Pons' own creator tax, charged on buys and sells alike, outside the token.

## What changes, what stays

| | IMD design | Pons design |
| --- | --- | --- |
| Token | custom (hold clock, checkpoints, listed array) | Pons' standard fixed-supply ERC-20, no hooks |
| Tax | 6% in the token, buys and sells | Pons creator tax 5% + Pons base 1% = 6% per side to the trader |
| Where the tax lands | DropVault, in ETH, via tax orders | Pons fee escrow, in ETH; the splitter claims it |
| Split | 3.5 / 1.2 / 0.9 / 0.4 of 6 | 73.33% pot / 20% mega / 6.67% team of the 5.7% that arrives (liquidity folded into the pot) |
| Draw | on chain, enforced by the vault | off chain in the keeper, committed and provable; payouts pushed through a Merkle round |
| Randomness | drand, verified on chain in the vault | drand, the round committed on chain together with the pinned snapshot list, before the round exists; verified by anyone |
| Winner paid | by the vault, in ETH | by the TombolaDraw contract, in ETH, pushed by the keeper (claimable by the winner too) |
| Eligibility | 10,000 tokens, 30 minutes, 1x to 3x over 72 h | the same, computed from Transfer logs |
| Cadence | hourly for 6 h, then every 4 h; mega weekly | the same |
| Site, X bot, verify | read the vault | read TombolaDraw and the published snapshots |

## Contracts (contracts-pons/)

- **TombolaSplitter**: immutable, no admin. Set as Pons' `creatorFeeRecipient`. `harvest()` (anyone) claims the escrow's
  native ETH and splits it POT_BPS / MEGA_BPS / TEAM_BPS to the draw contract's two pots and the team fee wallet.
- **TombolaDraw**: holds the two pots (regular, mega) and runs the draw ledger:
  - `commit(track, snapshotTime, drandRound, potWei, root, totalWeight)` by the keeper: pins the snapshot list and
    records the draw BEFORE its randomness exists.
    Reverts unless `drandRound` is at least COMMIT_DELAY after both the snapshot and this block (and at most a day
    ahead), the snapshot is recent, the list is consistent and `potWei <= pot[track]`.
    The snapshot block is the last block at or before `snapshotTime`; the published snapshot names it.
  - `settle(id, drandSignature, winner, cumulativeBefore, weight, proof)` by anyone once the round is out: the beacon
    verifies the signature on chain (the DrandBeacon already deployed: BLS over BN254); the contract derives the random
    word, checks the winner's leaf against the root and total weight pinned at commit, and pays the winner the amount
    (or credits it, claimable, if the send fails). The winner must be the leaf proven against the pinned root:
    `settle` takes the winner's leaf proof, so the contract checks the winner is IN the pinned list with the claimed
    weight. What it cannot check is that the list is complete and the weights honest: that is what verify-drop
    recomputes from Transfer logs.
  - `rollover(id, drandSignature)`: a draw pinned with an empty list returns its pot; a draw with an eligible list can't be rolled over.
  - Guardian (a cold wallet) may `cancel(id)` a committed draw while its round is still in the future, and rotate the
    keeper between draws; nothing else is privileged. No owner
    withdraw. Pots can only leave as prizes.
- **DrandBeacon**: the one already on Robinhood Chain (0xaf4f...9A0E) is reused as is.

## The keeper (bot/)

Every tick: harvest the splitter when the escrow holds fees; at each due slot build the snapshot from Transfer logs
(balance at the snapshot block, hold start from the last inbound transfer that wasn't a reset, 10,000 minimum,
30-minute gate, 1x to 3x multiplier), publish it (JSON with every wallet, balance, hold start, weight, proof, plus the
Merkle root) to the public tombola-draws repo, and commit the draw with the list's root and total weight; after the
drand round is published, pick `randomWord mod totalWeight` and settle on chain. verify-draw.mjs and the site's Verify
rebuild the snapshot from the chain and drand and check the pinned root, the total and the winner.

## Trust

The contracts enforce: the random round was committed before anyone could know it; the winner is in the list the
keeper pinned; the pot only pays winners. The keeper is trusted to build an honest list. Anyone can prove a dishonest
list from public data in the window between the commit and the round, and the guardian can cancel it in that window. That is the
same trust model Hive runs with, with the drand commitment added so the keeper can't pick the round either.
