# Fluid DEX T1 exact-output rounding proof

## Core issue

`_getAmountIn()` computes `amountOut * reserveIn / (reserveOut - amountOut)` with floor division. `_swapOut()` then grosses the result up for fees with another floor division. For an exact-output operation, both divisions should conservatively round the amount paid by the trader upward.

## Closed-cycle construction

Starting reserves are `(x, y)`.

1. Request exact output `a` of Y and pay `q = floor(a*x/(y-a))` X.
2. Pool becomes `(x+q, y-a)`.
3. Reverse direction and request exact output `q` X.
4. Pay `r = floor(q*(y-a)/x)` Y.
5. Pool becomes `(x, y-a+r)`.

Whenever `r < a`, the attacker recovers all X and keeps `a-r` Y. The pool loses exactly `a-r` Y while X returns to its starting reserve. This is a closed-cycle invariant violation and can theoretically be repeated until another protocol limit stops it.

## Required production proof

Do not submit as High/Critical without all of the following:

- deployed in-scope pool and exact fork block;
- fee decoded from `dexVariables2`;
- token decimals and real/imaginary reserves;
- successful two-leg fork trace;
- attacker and pool balances before/after;
- profit after gas;
- repeatability and maximum extractable loss;
- a control implementation using `ceilDiv`;
- evidence that oracle and minimum-reserve checks do not stop exploitation.

At nonzero fees the fee may dominate the rounding gain. Therefore a synthetic zero-fee configuration alone is not bounty-ready.