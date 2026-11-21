// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DemoToken
/// @notice Open-faucet testnet ERC-20 used by SynapseGuardVault for reproducible Base Sepolia intent tests.
contract DemoToken is ERC20 {
    uint8 private immutable _customDecimals;
    uint256 public immutable maxFaucetMint;

    error FaucetAmountExceeded(uint256 requested, uint256 maxAllowed);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 maxFaucetMint_)
        ERC20(name_, symbol_)
    {
        _customDecimals = decimals_;
        maxFaucetMint = maxFaucetMint_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /// @notice Mint bounded test tokens for demo runs and cross-chain validation.
    function faucetMint(address to_, uint256 amount_) external {
        if (amount_ > maxFaucetMint) revert FaucetAmountExceeded(amount_, maxFaucetMint);
        _mint(to_, amount_);
    }
}
