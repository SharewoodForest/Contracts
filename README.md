# Sharewood Forest — Contracts

Claim-link gifts for ERC20 tokens (stock tokens, stablecoins) on Robinhood Chain.

## How it works
1. The app generates a one-time **claim key** in the sender's browser.
2. Sender calls `createGift(token, amount, claimKeyAddress, duration)`. The gift amount is
   escrowed and the fee (charged on top, max 5%) goes to the treasury.
3. The claim link contains the claim key's private half, e.g. `sharewoodforest.app/claim#<id>-<key>`
   (after `#`, so it never reaches any server).
4. The recipient's app signs `claimDigest(id, recipientWallet)` with the claim key and calls `claim`.
   Signatures are bound to the recipient, so a copied transaction can't be redirected. Anyone
   can submit the claim, so a relayer can pay gas for brand-new users.
5. Unclaimed gifts can be refunded to the sender after expiry (fee not refunded).

## Safety properties
- The owner can never move escrowed funds. There is no withdraw function.
- Pausing only blocks new gifts; claims and refunds always work.
- Token allowlist (on by default); fee-on-transfer tokens are rejected.
- Fee hard-capped at 5%; ownership transfer is two-step.

## Commands
```
forge install
forge test
cp .env.example .env   # fill in
source .env
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --private-key $PRIVATE_KEY
```
After deploying, allowlist each token: `setTokenAllowed(token, true)`.

Get an audit or independent review before holding meaningful value.
