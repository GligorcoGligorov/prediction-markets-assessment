# WorldCupBetting — Solution

## What I built

The task was to implement `WorldCupBetting.sol` — a stub contract where every function reverted with "candidate implementation required". I replaced the stub bodies with working logic until all 9 assessment scenarios passed.

```
npx hardhat test test/WorldCupBetting.assessment.test.ts

  World Cup on-chain betting (assessment scenarios)
    ✔ Scenario A: group-stage match with three outcomes (1X2) can be created and resolved
    ✔ Scenario B: knockout yes/no market — winner receives net payout after platform fee
    ✔ Scenario C: oracle cannot resolve before kickoff window closes
    ✔ Scenario D: random fan cannot resolve the match
    ✔ Scenario E: no new stakes after the official resolution timestamp
    ✔ Scenario F: slippage guard rejects bets when minShares is too high
    ✔ Scenario G: secondary market — ticket buyer collects if seller picked the winner
    ✔ Scenario H: stablecoin pool — same lifecycle using ERC20 collateral
    ✔ Scenario I: losing side can settle to record reputation without double-claim

  9 passing (743ms)
```

---

## My approach

I started by reading the test file top to bottom before writing any code. Each scenario told me exactly what the contract needed to do, what revert messages to match, and what edge cases mattered. Then I read `PredictionMarket.sol` (the reference) to understand how the AMM math works, and built `WorldCupBetting` from scratch using that as a guide.

---

## Key decisions

### Share pricing (AMM)

The first person to bet on an outcome gets `amount × 100` shares — a flat rate since there's no pool yet. After that, shares decrease as the pool grows. This means early bettors get better value, which encourages liquidity early in the market's life. It also makes the share price naturally reflect confidence — if a lot of money is already on one side, new bets on that side yield fewer shares.

### Platform fee

The 2% fee is only charged on the winner's payout, not on bets themselves. I track collected fees in a mapping keyed by token address (`address(0)` for ETH, token contract address for ERC20), so the same fee logic works for both collateral types. The owner calls `withdrawFees` to pull out what has accumulated.

### ETH and ERC20 in one contract

Each market has a `tokenAddress` field set at creation. If it's `address(0)`, the market runs on native ETH and reads `msg.value`. Otherwise it calls `transferFrom` on that ERC20 contract. No separate contracts needed — `placeBet`, `claimWinnings`, and `buyPosition` all handle both cases with a single if/else.

### Position trading

A bettor can list their position for sale before the market resolves. When someone buys it, two things happen atomically: `bet.bettor` is updated to the buyer, and the seller receives payment. The underlying bet stays locked in the market pool — what transfers is just the right to claim it. So if the outcome wins, the buyer collects the winnings.

### Losing bettors and reputation

Losing bettors can call `claimWinnings` too. It marks the bet as claimed (preventing a second call) and records a reputation penalty via `ReputationSystem`. No funds are sent. This keeps reputation consistent — every settled bet updates the score regardless of outcome.

### Reentrancy protection

I follow the checks-effects-interactions pattern throughout. `bet.claimed = true` is set before any external call or token transfer. Even if a malicious contract tried to re-enter during an ETH transfer, the bet is already marked claimed and the second call reverts immediately.

---

## How to run

```bash
cd contracts
npm install --legacy-peer-deps
npx hardhat compile
npx hardhat test test/WorldCupBetting.assessment.test.ts
```
