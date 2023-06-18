# Manifold Governance [![Github Actions][gha-badge]][gha] [![Foundry][foundry-badge]][foundry] [![License: MIT][license-badge]][license]



<p align="center">
    <img src="./assets/banner.png" alt="daobox-banner" />
    <br>
    <i>Manifold Governance is an Aragon OSx DAO Template that includes a veToken, Fee Distributor, and a Voting Plugin <br>
</p>

<p align="center">

  <a href="https://discord.gg/EWRMHjqQVf">DAOBox: DAO Development Discord</a>
  <br>
</p>
<hr>

<br/>

## What's Inside

- [Forge](https://github.com/foundry-rs/foundry/blob/master/forge): compile, test, fuzz, format, and
  deploy smart contracts
- [Forge Std](https://github.com/foundry-rs/forge-std): collection of helpful contracts and
  cheatcodes for testing
- [Solhint](https://github.com/protofire/solhint): linter for Solidity code
- [Prettier Plugin Solidity](https://github.com/prettier-solidity/prettier-plugin-solidity): code
  formatter for non-Solidity files

<br/>

## Quick Start

1. copy the `.env.example` to `.env` and set the variables
2. install the depencencies 
```bash
pnpm install
forge build
```
3. run the integration test 
```
forge test -vvv 
```


## License

This project is licensed under MIT.
