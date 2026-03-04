// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Ahya Amrullah
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * Kontrak ini dimiliki oleh DSCEngine. Merupakan ERC20 token yang
 * hanya bisa di-mint dan di-burn oleh DSCEngine.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // =========================================
    // Errors
    // =========================================
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    // =========================================
    // Constructor
    // =========================================

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    // =========================================
    // External / Public Functions
    // =========================================

    /**
     * @notice Burn sejumlah DSC token
     * @param _amount Jumlah token yang akan dibakar
     */
    function burn(uint256 _amount) public override onlyOwner {
        if (_amount == 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balanceOf(msg.sender) < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    /**
     * @notice Mint sejumlah DSC token ke address tertentu
     * @param _to Address penerima token
     * @param _amount Jumlah token yang akan dicetak
     * @return bool true jika berhasil
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount == 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
