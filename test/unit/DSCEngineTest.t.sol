// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/deployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockFailedMintDSC} from "test/mocks/MockFailedMintDsc.sol";
import {MockFailedTransfer} from "test/mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "test/mocks/MockFailedTransferFrom.sol";
import {MockMoreDebtDSC} from "test/mocks/MockMoreDebtDsc.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is StdCheats, Test {
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = makeAddr("user");

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
    }

    ////////////////
    // Owner Test //
    ////////////////
    function testOwnerIsDscEngine() public view {
        console.log("Expected Owner: ", address(engine));
        console.log("Actual Owner: ", dsc.owner());
        assertEq(dsc.owner(), address(engine));
    }

    //////////////////////
    // Constructor Test //
    //////////////////////
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testRevertsIfDscAddressIsZero() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__RevertZeroAddress.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(0));
    }

    ///////////////////
    // Price Test    //
    ///////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30.000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 amountUsdInWei = 100 ether;
        // $2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, amountUsdInWei);
        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////
    function testRevertIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approveInternal(address(engine), user, amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnaprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", user, amountCollateral);
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositeCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(user);
        uint256 expectedDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedDscMinted, totalDscMinted);
        assertEq(amountCollateral, expectedDepositAmount);
    }

    function testDepositCollateralUpdateCollateralMapping() public depositedCollateral {
        uint256 collateralDeposited = engine.getCollateralBalanceOfUser(user, weth);
        assert(amountCollateral == collateralDeposited);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(user);
        ERC20Mock(weth).approveInternal(user, address(engine), amountCollateral);

        vm.expectEmit(true, true, true, true);
        emit DSCEngine.CollateralDeposited(user, weth, amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfTransferFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom(owner);
        tokenAddresses.push(address(mockCollateralToken));
        priceFeedAddresses.push(wethUsdPriceFeed);
        // DSCEngine menerima parameter ketiga sebagai dscAddress, bukan tokenAddress yang digunakan sebagai jaminan.
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        mockCollateralToken.mint(user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockCollateralToken), amountCollateral);
        vm.stopPrank();
    }

    //////////////////////////////////////
    // depositCollateralAndMintDsc Test //
    //////////////////////////////////////
    function testRevertIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        amountToMint =
        ((amountCollateral * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision());
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositCollateralAndMintDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositCollateral() public depositCollateralAndMintDsc {
        uint256 balanceUser = dsc.balanceOf(user);
        assertEq(balanceUser, amountToMint);
    }

    ////////////////////
    // mintDsc Tests  //
    ////////////////////
    function testRevertIfMintFails() public {
        // Arrange setUp
        address owner = msg.sender;
        MockFailedMintDSC mockDsc = new MockFailedMintDSC(owner);
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        vm.startPrank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockEngine));
        vm.stopPrank();

        // Arrange user
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockEngine), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__MintedFailed.selector);
        mockEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertIfMintAmountZero() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertIfAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        amountToMint =
            (amountCollateral * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(user); // Lupa nambahin baris ini, jadi test ini gagal karena user belum approve collateralnya ke engine, sehingga collateralValueInUsd = 0, dan health factor = 0, yang mana lebih kecil dari MIN_HEALTH_FACTOR.
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, amountCollateral));

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(user);
        engine.mintDsc(amountToMint);

        assertEq(dsc.balanceOf(user), amountToMint);
        vm.stopPrank();
    }

    function testCannotMintWithoutDepositingCollateral() public {
        vm.startPrank(user);

        uint256 expectedHealthFactor = engine.calculateHealthFactor(amountToMint, 0);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ////////////////////
    // burnDsc Tests  //
    ////////////////////
    function testRevertIfBurnAmountIsZero() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testCanBurnDsc() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(engine), amountToMint);
        engine.burnDsc(amountToMint);
        vm.stopPrank();

        // Assert
        uint256 balanceUser = dsc.balanceOf(user);
        assertEq(balanceUser, 0);
    }

    ////////////////////////////
    // redeemCollateral Tests //
    ////////////////////////////
    function testRevertIfTransferFails() public {
        // Arrange
        address owner = msg.sender;
        vm.startPrank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer(owner);
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [wethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);
        mockDsc.transferOwnership(address(mockEngine));
        vm.stopPrank();

        // Act / Assert
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockEngine), amountCollateral);
        mockEngine.depositCollateral(address(mockDsc), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfTokenNotAllowed() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.redeemCollateral(address(0), amountCollateral);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBeforeRedeem = engine.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceBeforeRedeem, amountCollateral);
        engine.redeemCollateral(weth, amountCollateral);
        uint256 userBalanceAfterRedeem = engine.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        engine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    //////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////
    function testMustRedeemMoreThanZero() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth, amountCollateral, 0);
        vm.stopPrank();
    }

    function testMustRedeemAllowedToken() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.redeemCollateralForDsc(address(0), amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemForDsc() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        dsc.approve(address(engine), amountToMint);
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    /////////////////////////
    // HealthFactor Tests  //
    /////////////////////////
    function testProperlyReportsHealthFactor() public depositCollateralAndMintDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(expectedHealthFactor, healthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositCollateralAndMintDsc {
        int256 ethUsdPriceFeed = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdPriceFeed);

        uint256 healthFactor = engine.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assertEq(healthFactor, 0.9 ether);
    }

    ///////////////////////
    // liquidation Tests //
    ///////////////////////
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - setUp
        address owner = msg.sender;
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(wethUsdPriceFeed, owner);
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        vm.startPrank(owner);
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockEngine));
        vm.stopPrank();

        // Arrange user
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockEngine), amountCollateral);
        mockEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockEngine), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockEngine), debtToCover);
        // Act
        int256 ethUsdPriceFeed = 18e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdPriceFeed);
        // Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockEngine.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositCollateralAndMintDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdPriceFeed = 18e8; // 1 ETH = $18

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdPriceFeed);
        uint256 userHealthFactor = engine.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.liquidate(weth, user, amountToMint); // We are covering their whole debt.
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutsIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, amountToMint)
            + (engine.getTokenAmountFromUsd(weth, amountToMint)
                * engine.getLiquidationBonus()
                / engine.getLiquidationPrecision());
        uint256 hardCodeExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodeExpected);
        assertEq(liquidatorWethBalance, expectedWeth);   
    }

    function testUserHasSomeEthAfterLiquidation() public liquidated {
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, amountToMint)
            + (engine.getTokenAmountFromUsd(weth, amountToMint)
                * engine.getLiquidationBonus()
                / engine.getLiquidationPrecision());
        
        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 epectedUserCollateralValueInUsd = engine.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);
        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(user);
        uint256 hardCodeExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, hardCodeExpectedValue);
        assertEq(userCollateralValueInUsd, epectedUserCollateralValueInUsd);
    }

    function testLiquidatorTakesOnUserDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////
    // View & Pure Function Test //
    ///////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = engine.getTokenPriceFeed(weth);
        assertEq(priceFeed, wethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMintHealthFactor() public view {
        uint256 mintHealthFactor = engine.getMintHealthFactor();
        assertEq(mintHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(user);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDscMinted() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        uint256 dscMinted = engine.getDscMinted(user);
        assertEq(dscMinted, amountToMint);
        vm.stopPrank();
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        uint256 expectedCollateralBalance = engine.getCollateralBalanceOfUser(user, weth);
        assertEq(expectedCollateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();

        uint256 collateralValue = engine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedPrecision = 100;
        uint256 actualPrecision = engine.getLiquidationPrecision();
        assertEq(expectedPrecision, actualPrecision);
    }
}
