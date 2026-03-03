// SPDX-License-Identifier: MIT

// Ini dianggap sebagai koin kripto yang bersifat eksogen, terdesentralisasi, terikat (pegged), dan dijamin dengan jaminan kripto dengan volatilitas rendah.

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
pragma solidity ^0.8.30;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Ahya Amrullah
 *
 * Ini adalah kontrak inti dari sistem DSC. Sistem ini dirancang sedemikian rupa agar sesederhana mungkin, dan token-tokennya mempertahankan rasio 1 token == $1.
 * Stablecoin ini memiliki sifat-sifat:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * Ini mirip dengan DAI jika DAI tidak memiliki tata kelola, tidak ada biaya, dan hanya didukung oleh WETH dan WBTC.
 *
 * DSC kami harus selalu “overcollateralized”. Pada titik mana pun, nilai seluruh jaminan tidak boleh kurang dari nilai yang didukung oleh dolar dari seluruh DSC.
 *
 * @notice Kontrak ini merupakan inti dari Sistem DSC. Kontrak ini mengelola semua logika untuk penambangan dan penukaran DSC, serta penyetoran dan penarikan jaminan.
 * @notice Kontrak ini didasarkan secara sangat longgar pada sistem MakerDAO DSS (DAI).
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////
    //  Errors   //
    ///////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintedFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__StalePrice();
    error DSCEngine__RevertZeroAddress();

    ///////////
    // Type  //
    ///////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% collateralization ratio
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1.0
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    mapping(address token => address priceFeed) private sPriceFeed; // tokenToPriceFeeds
    mapping(address user => mapping(address token => uint256 amount)) private sCollateralDeposit; // user => token => amount
    mapping(address user => uint256 amountDscMinted) private sDscMinted;
    address[] private sTokenCollateral;

    DecentralizedStableCoin private immutable I_DSC;

    /////////////////////
    // Events          //
    /////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        _moreThanZero(amount);
        _;
    }

    modifier isAllowedToken(address token) {
        _isAllowedToken(token);
        _;
    }

    ///////////////
    // Functions //
    ///////////////
    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        // check if contract dscAddress
        if (dscAddress == address(0)) {
            revert DSCEngine__RevertZeroAddress();
        }

        // USD Price Feeds
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        // For Example ETH / USD, BTC / USD, SOL / USD, etc.abi
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            sPriceFeed[tokenAddress[i]] = priceFeedAddress[i];
            sTokenCollateral.push(tokenAddress[i]);
        }
        I_DSC = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /**
     * @param tokenCollateralAddress Alamat token yang akan disetorkan sebagai jaminan.
     * @param amountCollateral Jumlah jaminan yang harus disetorkan.
     * @param amountDscToMint Jumlah DSC yang ingin Anda cetak.
     * @notice Fungsi ini memungkinkan pengguna untuk menyetorkan jaminan dan mencetak DSC dalam satu transaksi. Ini mengikuti pola Checks-Effects-Interactions, yang merupakan praktik terbaik untuk menghindari kerentanan keamanan seperti reentrancy.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Follows the Checks-Effects-Interactions pattern.
     * @param tokenCollateralAddress Alamat token yang akan disetorkan sebagai jaminan.
     * @param amountCollateral Jumlah jaminan yang harus disetorkan.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral) // ✅
        isAllowedToken(tokenCollateralAddress) // ✅
        nonReentrant
    {
        sCollateralDeposit[msg.sender][tokenCollateralAddress] += amountCollateral; // ✅
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral); // ✅
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        } // ✅
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToMint The amount of DSC to burn.
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint)
        external
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
    {
        burnDsc(amountDscToMint);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks healt factor
    }

    // untuk menebus jaminan
    // Faktor kesehatan harus lebih dari 1 setelah jaminan ditarik.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        isAllowedToken(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amountDscToMint: Jumlah DSC yang ingin Anda cetak.
     * Anda hanya dapat mencetak DSC jika Anda memiliki jaminan yang cukup / lebih.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // ✅
        sDscMinted[msg.sender] += amountDscToMint; // ✅
        // Jika mereka mencetak terlalu banyak ($150 DSC, $100 ETH)
        _revertHealthFactorIsBroken(msg.sender);
        bool minted = I_DSC.mint(msg.sender, amountDscToMint); // ✅
        if (!minted) {
            revert DSCEngine__MintedFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertHealthFactorIsBroken(msg.sender); // Saya tidak berpikir ini akan pernah terjadi.
    }

    /**
     * @param collateral Alamat jaminan ERC20 yang akan dilikuidasi dari pengguna.
     * @param user Pengguna yang melanggar batas faktor kesehatan. Nilai _healthFactor mereka harus di bawah MIN_HEALTH_FACTOR.
     * @param debtToCover Jumlah DSC yang ingin Anda bakar untuk meningkatkan faktor kesehatan pengguna.
     * @notice Anda dapat melakukan likuidasi sebagian terhadap seorang pengguna.
     * @notice Anda akan mendapatkan bonus likuidasi atas penarikan dana pengguna.
     * @notice Fungsi ini beroperasi dengan asumsi bahwa protokol akan memiliki jaminan berlebih sekitar 200% agar fungsi ini dapat berjalan.
     * @notice Sebuah bug yang diketahui adalah jika protokol tersebut dijamin dengan jaminan sebesar 100% atau kurang, maka kita tidak akan dapat memberikan insentif kepada para likuidator.
     * Misalnya, jika harga jaminan anjlok sebelum siapa pun dapat dilikuidasi.
     *
     * Follow CEI: Checks, Effects, Interactions
     *
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Periksa faktor kesehatan pengguna
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // Kami ingin membakar utang DSC mereka
        // Dan mengambil jaminan mereka
        // Pengguna Buruk: $140 ETH, $100 DSC
        // utang yang perlu ditutupi: $100
        // $100 DSC = ??? ETH?
        // 0.05 ETH
        uint256 tokenAmountToDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // Dan berikan mereka bonus 10%
        // Jadi kami memberikan likuidator $110 WETH untuk $100 DSC
        // Kami harus mengimplementasikan fitur untuk melakukan likuidasi jika protokol menjadi tidak mampu membayar
        // Dan mengalihkan jumlah tambahan ke kas

        // 0.05 ETH * .1 = 0.005 ETH Mendapatkan 0.055 ETH
        uint256 bonusCollateral = (tokenAmountToDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountToDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // we need to burn the DSC.
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertHealthFactorIsBroken(msg.sender);
    }

    //////////////////////////////////////
    // Private & Internal View Function //
    //////////////////////////////////////

    /**
     * @dev Low-level internal function.
     * @notice do not call unless the function calling it is checking for health factors being broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        sDscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = I_DSC.transferFrom(dscFrom, address(this), amountDscToBurn);
        // Kondisi ini secara hipotetis tidak dapat dicapai.
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        I_DSC.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        sCollateralDeposit[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = sDscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Menampilkan seberapa dekat pengguna dengan likuidasi.
     * Jika saldo pengguna turun di bawah 1, maka mereka dapat mengalami likuidasi.
     */
    function _healthFactor(address user) private view returns (uint256) {
        // Total DSC yang dicetak
        // Total nilai jaminan
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // 1. Periksa faktor kesehatan (apakah mereka memiliki jaminan yang cukup)
    // 2. Revert if they don't
    function _revertHealthFactorIsBroken(address user) internal view {
        uint256 userHealtFactor = _healthFactor(user);
        if (userHealtFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealtFactor);
        }
    }

    function _moreThanZero(uint256 amount) internal pure {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
    }

    function _isAllowedToken(address token) internal view {
        if (sPriceFeed[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
    }

    function _getValidatedPrice(address token) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        if (price <= 0) {
            revert DSCEngine__StalePrice();
        }
        return uint256(price);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralLlAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralLlAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /////////////////////////////////////
    // Public & External View Function //
    /////////////////////////////////////
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValudeInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValudeInUsd);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Price of ETH (token)
        // $/ETH ETH?
        // $2000 / ETH, $1000 = 0.5 ETH
        uint256 price = _getValidatedPrice(token);
        // $1000 / $2000 = 0.5 ETH
        return (usdAmountInWei * PRECISION) / (price * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Lakukan looping pada setiap token jaminan, ambil jumlah yang telah mereka setorkan, dan hubungkan dengan
        // harga, untuk mendapatkan nilai USD.
        for (uint256 i = 0; i < sTokenCollateral.length; i++) {
            address token = sTokenCollateral[i];
            uint256 amount = sCollateralDeposit[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        uint256 price = _getValidatedPrice(token);
        return ((price * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getDscMinted(address user) external view returns (uint256) {
        return sDscMinted[user];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return sCollateralDeposit[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMintHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getDsc() external view returns(address) {
        return address(I_DSC);
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return sTokenCollateral;
    }

    function getTokenPriceFeed(address token) external view returns(address) {
        return sPriceFeed[token];
    }
}
