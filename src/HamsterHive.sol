// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Hamster Hive (HAMSTER)
/// @notice A plain, fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`). There is no owner, no minter, no pause, no blocklist and no transfer fee:
/// after deployment nobody holds any power over the token that an ordinary holder does not have.
/// @dev The contract identifier `HamsterHive` is what the launch records; `name()` and `symbol()` carry
/// the token's own name and ticker. The constructor takes no arguments and calls no other contract, so
/// it deploys on an empty chain and the deployer may be any account or contract.
contract HamsterHive is ERC20 {
    /// @notice The token's decimals. Fixed at 18, the ERC-20 default.
    uint8 public constant DECIMALS = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 HAMSTER with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the whole fixed supply to the deployer.
    /// @dev `msg.sender` is the deployer. On the launch this is the factory, which distributes the
    /// supply afterwards. `_mint` is never reachable again: no function in this contract calls it.
    constructor() ERC20("Hamster Hive", "HAMSTER") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
