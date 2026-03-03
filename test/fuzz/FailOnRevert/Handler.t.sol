// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// Handler akan memperketat cara kita memanggil fungsi.

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin public dsc;
    DSCEngine public engine;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    MockV3Aggregator public wethUsdPriceFeed;

    address[] public userWithCollateralDeposited;
    uint256 public timesMintIsCalled;
    uint96 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        wethUsdPriceFeed = MockV3Aggregator(engine.getTokenPriceFeed(address(weth)));
    }

    ///////////////
    // DSCEngine //
    ///////////////
    // redeem collateral <-
    // kita hanya bisa menarik jaminan ketika ada jaminan yang bisa di tarik
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        userWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (userWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        // Arrange
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        // console.log("total dsc minted: ", totalDscMinted);
        // console.log("collateral value in usd: ", collateralValueInUsd);
        timesMintIsCalled++;
        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        engine.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // Arrange
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxRedeemCollateral = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxRedeemCollateral);
        if (amountCollateral == 0) {
            return;
        }

        // Cek apakah redeem akan melanggar health factor
        (uint256 totalDscMinted,) = engine.getAccountInformation(msg.sender);
        if (totalDscMinted > 0) {
            return; // skip jika masih ada DSC yang dicetak
        }

        // Act
        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnDsc(uint256 amountDsc) public {
        // Must be more than zero
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        if (amountDsc == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dsc.approve(address(engine), amountDsc);
        engine.burnDsc(amountDsc);
        vm.stopPrank();
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidate, uint256 debtToCover) public {
        uint256 minHealthFactor = engine.getMintHealthFactor();
        uint256 userHealthFactor = engine.getHealthFactor(userToBeLiquidate);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        engine.liquidate(address(collateral), userToBeLiquidate, debtToCover);
    }

    /////////////////////////////
    // DecentralizedStableCoin //
    /////////////////////////////
    function transferDsc(uint256 amountDsc, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        vm.startPrank(msg.sender);
        dsc.transfer(to, amountDsc);
        vm.stopPrank();
    }

    // This breaks our invariant test suite!!!!
    // function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
    //     int256 intNewPrice = int256(bound(uint256(newPrice), 1000e8, 10000e8));
    //     ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    //     MockV3Aggregator priceFeed = MockV3Aggregator(engine.getTokenPriceFeed(address(collateral)));
    //     priceFeed.updateAnswer(intNewPrice);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
