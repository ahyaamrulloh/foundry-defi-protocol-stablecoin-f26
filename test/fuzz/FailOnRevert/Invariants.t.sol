// SPDX-License-Identifier: MIT

// Apa Invariant kita
// Apa saja sifat - sifat sistem yang harus selalu dipertahankan

pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    DeployDSC deployer;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
        // targetContract(address(engine));
    }

    function invariant_protocolMustHaveMoreCollateral() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethUsdValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcUsdValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethUsdValue);
        console.log("wbtc value: ", wbtcUsdValue);
        console.log("total Supply: ", totalSupply);
        console.log("Times Mint is Called: ", handler.timesMintIsCalled());

        assert(wethUsdValue + wbtcUsdValue >= totalSupply);
    }

    function invariant_getterShouldNotRevert() public view {
        engine.getAdditionalFeedPrecision();
        engine.getCollateralTokens();
        engine.getDsc();
        engine.getLiquidationBonus();
        engine.getLiquidationPrecision();
        engine.getLiquidationThreshold();
        engine.getMintHealthFactor();
        engine.getPrecision();
    }
}
