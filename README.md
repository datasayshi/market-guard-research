# Market Guard research

Executable recovery baseline for Market Guard v0.38, retaining the v0.33 shared-core architecture.

Current evidence level: **compiled standalone reference + Foundry fuzz tests + one-million-transition Python state-machine run**. This repository does **not** yet contain a deployable Uniswap v4 hook, audited fixed-point implementation, measured production gas, or fork/replay evidence.

See [RECOVERY_AND_TEST_STATUS.md](RECOVERY_AND_TEST_STATUS.md) for the recovered specification and explicit evidence boundary.

## Run

```sh
forge build
forge test -vv
python3 model/reference.py --steps 1000000 --seed 38
```

Solidity is pinned to 0.8.26 in `foundry.toml`.
