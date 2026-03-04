// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Invariants:
// Protokol tidak boleh pernah bangkrut / kekurangan jaminan
// Pengguna tidak boleh membuat stablecoin dengan faktor kesehatan yang buruk
// Seorang pengguna hanya boleh dilikuidasi jika mereka memiliki faktor kesehatan yang buruk

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";

contract ContinueOnRevertInvariants is StdInvariant, Test {
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public weth;
    address public wbtc;

    // Handler
    ContinueOnRevertHandler handler;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (,, weth, wbtc) = helperConfig.activeNetworkConfig();
        handler = new ContinueOnRevertHandler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupplyDollars() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposited = ERC20Mock(weth).balanceOf(address(engine));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, wethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, wbtcDeposited);

        console.log("weth Value: %s", wethValue);
        console.log("wbtc Value: %s", wbtcValue);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
