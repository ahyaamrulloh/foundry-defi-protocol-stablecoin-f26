// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

contract ContinueOnRevertHandler is Test {
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    MockV3Aggregator public wethUsdPriceFeed;
    MockV3Aggregator public wbtcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variable
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        wethUsdPriceFeed = MockV3Aggregator(engine.getTokenPriceFeed(address(weth)));
        wbtcUsdPriceFeed = MockV3Aggregator(engine.getTokenPriceFeed(address(wbtc)));
    }

    // FUNCTION TO INTERACT WITH

    ///////////////
    // DSCEngine //
    ///////////////

    function mintAndDepositeCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateral.mint(msg.sender, amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnDsc(uint256 amountDsc) public {
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        dsc.burn(amountDsc);
    }

    function mintDsc(uint256 amountDsc) public {
        amountDsc = bound(amountDsc, 0, MAX_DEPOSIT_SIZE);
        dsc.mint(msg.sender, amountDsc);
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidate, uint256 debtToCover) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.liquidate(address(collateral), userToBeLiquidate, debtToCover);
    }

    /////////////////////////////
    // DecentralizedStableCoin //
    /////////////////////////////
    function transferDsc(uint256 amountDsc, address to) public {
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dsc.transfer(to, amountDsc);
    }

    ////////////////
    // Aggregator //
    ////////////////
    function updateCollateralPrice(int128, /* newPrice */ uint256 collateralSeed) public {
        // int256 newIntPrice = int256(uint256(newPrice));
        int256 newPrice = 1000;
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(engine.getTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(newPrice);
    }

    // Helper function
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function callSummary() external view {
        console.log("Weth total deposited: ", weth.balanceOf(address(engine)));
        console.log("Wbtc total deposited: ", wbtc.balanceOf(address(engine)));
        console.log("Total supply of DSC: ", dsc.totalSupply());
    }
}
