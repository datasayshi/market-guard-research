# Market Guard and Launch Guard research

Executable recovery baselines for:

- **Market Guard v0.38**, retaining the v0.33 shared-core architecture.
- **Launch Guard 30 v1.1**, advancing the v1.0 candidate.
- **Launch Guard 60 v0.4**, advancing the v0.3 profile.

Current evidence level: **compiled standalone references + Foundry fuzz tests + executable Python state-machine models**. This repository does **not** yet contain a deployable Uniswap v4 hook, measured production-hook gas, an audit, or fork/replay evidence.

See [RECOVERY_AND_TEST_STATUS.md](RECOVERY_AND_TEST_STATUS.md) for Market Guard and [LAUNCH_GUARD_TEST_STATUS.md](LAUNCH_GUARD_TEST_STATUS.md) for the Launch Guard specifications and evidence boundaries.

## Run

```sh
forge build
forge test -vv
python3 model/reference.py --steps 1000000 --seed 38
python3 model/launch_guard_reference.py --steps 1000000 --seed 304
```

Solidity is pinned to 0.8.26 in `foundry.toml`. This checkout also includes Linux Foundry binaries under `tools/`; use `./tools/forge` when Forge is not installed globally.
