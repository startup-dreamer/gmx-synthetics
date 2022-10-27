// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../data/DataStore.sol";
import "../events/EventEmitter.sol";
import "../bank/StrictBank.sol";

import "../deposit/Deposit.sol";
import "../deposit/DepositStore.sol";
import "../withdrawal/Withdrawal.sol";

import "../market/Market.sol";
import "../market/MarketToken.sol";
import "../market/MarketStore.sol";
import "../position/Position.sol";
import "../position/PositionStore.sol";
import "../order/Order.sol";

import "../oracle/Oracle.sol";
import "../price/Price.sol";

import "../fee/FeeReceiver.sol";
import "../fee/FeeUtils.sol";

import "../utils/Calc.sol";
import "../utils/Precision.sol";

library MarketUtils {
    using SafeCast for int256;
    using SafeCast for uint256;

    using Deposit for Deposit.Props;
    using Market for Market.Props;
    using Position for Position.Props;
    using Order for Order.Props;
    using Price for Price.Props;

    // cap max funding APR at 1000%
    uint256 public constant MAX_ANNUAL_FUNDING_FACTOR = 1000 * Precision.FLOAT_PRECISION;

    // 0.0000000001 USD
    uint256 public constant MAX_USD_IMPRECISION = 10 ** 20;

    struct MarketPrices {
        Price.Props indexTokenPrice;
        Price.Props longTokenPrice;
        Price.Props shortTokenPrice;
    }

    error EmptyMarket();
    error InsufficientPoolAmount(uint256 poolAmount, uint256 amount);
    error InsufficientReserve(uint256 reservedUsd, uint256 maxReservedUsd);

    function getMarketTokenPrice(
        DataStore dataStore,
        Market.Props memory market,
        Price.Props memory longTokenPrice,
        Price.Props memory shortTokenPrice,
        Price.Props memory indexTokenPrice,
        bool maximize
    ) internal view returns (uint256) {
        uint256 poolValue = getPoolValue(dataStore, market, longTokenPrice, shortTokenPrice, indexTokenPrice, maximize);
        if (poolValue == 0) { return 0; }

        uint256 supply = getMarketTokenSupply(MarketToken(payable(market.marketToken)));

        // it may be possible for supply to be zero here
        return poolValue * Precision.WEI_PRECISION / supply;
    }

    function getMarketTokenSupply(MarketToken marketToken) internal view returns (uint256) {
        return marketToken.totalSupply();
    }

    function getOutputToken(address inputToken, Market.Props memory market) internal pure returns (address) {
        if (inputToken == market.longToken) {
            return market.shortToken;
        }
        if (inputToken == market.shortToken) {
            return market.longToken;
        }

        revert("MarketUtils: invalid inputToken");
    }

    function getCachedTokenPrice(address token, Market.Props memory market, MarketPrices memory prices) internal pure returns (Price.Props memory) {
        if (token == market.longToken) {
            return prices.longTokenPrice;
        }
        if (token == market.shortToken) {
            return prices.shortTokenPrice;
        }
        if (token == market.indexToken) {
            return prices.indexTokenPrice;
        }

        revert("MarketUtils: invalid token");
    }

    // the secondary price for market.indexToken is overwritten for certain order
    // types, use this value instead of the primary price for positions
    function getMarketPricesForPosition(Market.Props memory market, Oracle oracle) internal view returns (MarketPrices memory) {
        return MarketPrices(
            oracle.getLatestPrice(market.indexToken),
            oracle.getLatestPrice(market.longToken),
            oracle.getLatestPrice(market.shortToken)
        );
    }

    // the value of a market's liquidity pool is the worth of the liquidity provider tokens in the pool - pending trader pnl
    // we use the token index prices to calculate this and ignore price impact since if all positions were closed the
    // net price impact should be zero
    // when minting liquidity provider tokens, the price impact of the token in should be considered
    // when redeeming liquidity provider tokens, the price impact of the token out should be considered
    function getPoolValue(
        DataStore dataStore,
        Market.Props memory market,
        Price.Props memory longTokenPrice,
        Price.Props memory shortTokenPrice,
        Price.Props memory indexTokenPrice,
        bool maximize
    ) internal view returns (uint256) {
        uint256 longTokenAmount = getPoolAmount(dataStore, market.marketToken, market.longToken);
        uint256 shortTokenAmount = getPoolAmount(dataStore, market.marketToken, market.shortToken);

        uint256 value;

        value = longTokenAmount * longTokenPrice.pickPrice(maximize);
        value += shortTokenAmount * shortTokenPrice.pickPrice(maximize);

        value += getTotalBorrowingFees(dataStore, market.marketToken, true);
        value += getTotalBorrowingFees(dataStore, market.marketToken, false);

        uint256 impactPoolAmount = getPositionImpactPoolAmount(dataStore, market.marketToken);
        value += impactPoolAmount * indexTokenPrice.pickPrice(maximize);

        // !maximize should be used for net pnl as a larger pnl leads to a smaller pool value
        // and a smaller pnl leads to a larger pool value
        int256 pnl = getNetPnl(dataStore, market.marketToken, indexTokenPrice, !maximize);

        return Calc.sum(value, -pnl);
    }

    function getNetPnl(DataStore dataStore, address market, Price.Props memory indexTokenPrice, bool maximize) internal view returns (int256) {
        int256 longPnl = getPnl(dataStore, market, indexTokenPrice, true, maximize);
        int256 shortPnl = getPnl(dataStore, market, indexTokenPrice, false, maximize);

        return longPnl + shortPnl;
    }

    function getPnl(DataStore dataStore, address market, Price.Props memory indexTokenPrice, bool isLong, bool maximize) internal view returns (int256) {
        int256 openInterest = getOpenInterest(dataStore, market, isLong).toInt256();
        uint256 openInterestInTokens = getOpenInterestInTokens(dataStore, market, isLong);
        if (openInterest == 0 || openInterestInTokens == 0) {
            return 0;
        }

        uint256 price = indexTokenPrice.pickPriceForPnl(isLong, maximize);

        // openInterest is the cost of all positions, openInterestValue is the current worth of all positions
        int256 openInterestValue = (openInterestInTokens * price).toInt256();
        int256 pnl = isLong ? openInterestValue - openInterest : openInterest - openInterestValue;

        return pnl;
    }

    function getPoolAmount(DataStore dataStore, address market, address token) internal view returns (uint256) {
        return dataStore.getUint(Keys.poolAmountKey(market, token));
    }

    function applyDeltaToPoolAmount(
        DataStore dataStore,
        EventEmitter eventEmitter,
        address market,
        address token,
        int256 delta
    ) internal {
        uint256 nextValue = dataStore.applyDeltaToUint(
            Keys.poolAmountKey(market, token),
            delta
        );

        eventEmitter.emitPoolAmountUpdated(market, token, delta, nextValue);
    }

    function getCappedPositionImpactUsd(
        DataStore dataStore,
        address market,
        Price.Props memory tokenPrice,
        int256 priceImpactUsd
    ) internal view returns (int256) {
        if (priceImpactUsd < 0) {
            return priceImpactUsd;
        }

        uint256 impactPoolAmount = getPositionImpactPoolAmount(dataStore, market);
        int256 maxPositiveImpactUsd = (impactPoolAmount * tokenPrice.min).toInt256();

        if (priceImpactUsd > maxPositiveImpactUsd) {
            priceImpactUsd = maxPositiveImpactUsd;
        }

        return priceImpactUsd;
    }

    function getPositionImpactPoolAmount(DataStore dataStore, address market) internal view returns (uint256) {
        return dataStore.getUint(Keys.positionImpactPoolAmountKey(market));
    }

    function getSwapImpactPoolAmount(DataStore dataStore, address market, address token) internal view returns (uint256) {
        return dataStore.getUint(Keys.swapImpactPoolAmountKey(market, token));
    }

    function applyDeltaToSwapImpactPool(
        DataStore dataStore,
        EventEmitter eventEmitter,
        address market,
        address token,
        int256 delta
    ) internal {
        uint256 nextValue = dataStore.applyDeltaToUint(
            Keys.swapImpactPoolAmountKey(market, token),
            delta
        );

        eventEmitter.emitSwapImpactPoolAmountUpdated(market, token, delta, nextValue);
    }

    function applyDeltaToPositionImpactPool(
        DataStore dataStore,
        EventEmitter eventEmitter,
        address market,
        int256 delta
    ) internal {
        uint256 nextValue = dataStore.applyDeltaToUint(
            Keys.positionImpactPoolAmountKey(market),
            delta,
            true
        );

        eventEmitter.emitPositionImpactPoolAmountUpdated(market, delta, nextValue);
    }

    function applyDeltaToOpenInterest(
        DataStore dataStore,
        EventEmitter eventEmitter,
        address market,
        bool isLong,
        int256 delta
    ) internal {
        uint256 nextValue = dataStore.applyDeltaToUint(
            Keys.openInterestKey(market, isLong),
            delta
        );

        eventEmitter.emitOpenInterestUpdated(market, isLong, delta, nextValue);
    }

    function applyDeltaToCollateralSum(
        DataStore dataStore,
        EventEmitter eventEmitter,
        address market,
        address collateralToken,
        bool isLong,
        int256 collateralDeltaAmount
    ) internal {
        dataStore.applyDeltaToUint(
            Keys.collateralSumKey(market, collateralToken, isLong),
            collateralDeltaAmount
        );

        eventEmitter.emitCollateralSumDelta(market, collateralToken, isLong, collateralDeltaAmount);
    }

    // in case of late liquidations, there may be insufficient collateral to pay for funding fees
    // additionally since funding fees are accounted for in USD while collateral amounts may be in
    // non stablecoins, it is possible that the amount to be paid out exceeds the worth of the collateral
    // in the pool, the fees in the impact pool could be used to cover any shortfalls
    // alternatively the pay out of funding fees could be based on the usd value of pending funding fees
    // and the token value of paid funding fees
    function updateCumulativeFundingFactors(DataStore dataStore, address market) internal {
        (int256 longFundingFactor, int256 shortFundingFactor) = getNextCumulativeFundingFactors(dataStore, market);
        setCumulativeFundingFactor(dataStore, market, true, longFundingFactor);
        setCumulativeFundingFactor(dataStore, market, false, shortFundingFactor);
        dataStore.setUint(Keys.cumulativeFundingFactorUpdatedAtKey(market), block.timestamp);
    }

    function updateCumulativeBorrowingFactor(
        DataStore dataStore,
        Market.Props memory market,
        MarketPrices memory prices,
        bool isLong
    ) internal {
        uint256 borrowingFactor = getNextCumulativeBorrowingFactor(dataStore, market, prices, isLong);
        setCumulativeBorrowingFactor(dataStore, market.marketToken, isLong, borrowingFactor);
        dataStore.setUint(Keys.cumulativeBorrowingFactorUpdatedAtKey(market.marketToken, isLong), block.timestamp);
    }

    function applyDeltaToOpenInterestInTokens(
        DataStore dataStore,
        address market,
        bool isLong,
        int256 sizeDeltaInTokens
    ) internal {
        uint256 openInterestInTokens = getOpenInterestInTokens(dataStore, market, isLong);
        uint256 nextOpenInterestInTokens = Calc.sum(openInterestInTokens, sizeDeltaInTokens);
        dataStore.setUint(Keys.openInterestInTokensKey(market, isLong), nextOpenInterestInTokens);
    }

    function validateReserve(
        DataStore dataStore,
        Market.Props memory market,
        MarketPrices memory prices,
        bool isLong
    ) internal view {
        address reserveToken = isLong ? market.longToken : market.shortToken;
        uint256 reservePoolAmount = getPoolAmount(dataStore, market.marketToken, reserveToken);
        uint256 reserveTokenPrice = isLong ? prices.longTokenPrice.min : prices.shortTokenPrice.min;
        uint256 reservePoolUsd = reservePoolAmount * reserveTokenPrice;

        uint256 reserveFactor = getReserveFactor(dataStore, market.marketToken, isLong);
        uint256 maxReservedUsd = Precision.applyFactor(reservePoolUsd, reserveFactor);

        uint256 reservedUsd;
        if (isLong) {
            // for longs calculate the reserved USD based on the open interest and current indexTokenPrice
            // this works well for e.g. an ETH / USD market with long collateral token as WETH
            // the available amount to be reserved would scale with the price of ETH
            // this also works for e.g. a SOL / USD market with long collateral token as WETH
            // if the price of SOL increases more than the price of ETH, additional amounts would be
            // automatically reserved
            uint256 openInterestInTokens = getOpenInterestInTokens(dataStore, market.marketToken, isLong);
            reservedUsd = openInterestInTokens * prices.indexTokenPrice.max;
        } else {
            // for shorts use the open interest as the reserved USD value
            // this works well for e.g. an ETH / USD market with short collateral token as USDC
            // the available amount to be reserved would not change with the price of ETH
            reservedUsd = getOpenInterest(dataStore, market.marketToken, isLong);
        }

        if (reservedUsd > maxReservedUsd) {
            revert InsufficientReserve(reservedUsd, maxReservedUsd);
        }
    }

    function applySwapImpactWithCap(
        DataStore dataStore,
        EventEmitter eventEmitter,
        address market,
        address token,
        Price.Props memory tokenPrice,
        int256 priceImpactUsd
    ) internal returns (int256) {
        // positive impact: minimize impactAmount, use tokenPrice.max
        // negative impact: maximize impactAmount, use tokenPrice.min
        uint256 price = priceImpactUsd > 0 ? tokenPrice.max : tokenPrice.min;

        int256 impactAmount;

        if (priceImpactUsd > 0) {
            // round positive impactAmount down, this will be deducted from the swap impact pool for the user
            impactAmount = priceImpactUsd / price.toInt256();

            int256 maxImpactAmount = getSwapImpactPoolAmount(dataStore, market, token).toInt256();
            if (maxImpactAmount > impactAmount) {
                impactAmount = maxImpactAmount;
            }
        } else {
            // round negative impactAmount up, this will be deducted from the user
            impactAmount = Calc.roundUpDivision(priceImpactUsd, price.toInt256());
        }

        applyDeltaToSwapImpactPool(
            dataStore,
            eventEmitter,
            market,
            token,
            impactAmount
        );

        return impactAmount;
    }

    function getFundingFees(DataStore dataStore, Position.Props memory position) internal view returns (int256) {
        int256 cumulativeFundingFactor = getCumulativeFundingFactor(dataStore, position.market, position.isLong);
        int256 diffFactor = position.fundingFactor - cumulativeFundingFactor;
        return Precision.applyFactor(position.sizeInUsd, diffFactor);
    }

    function getBorrowingFees(DataStore dataStore, Position.Props memory position) internal view returns (uint256) {
        uint256 cumulativeBorrowingFactor = getCumulativeBorrowingFactor(dataStore, position.market, position.isLong);
        uint256 diffFactor = cumulativeBorrowingFactor - position.borrowingFactor;
        return Precision.applyFactor(position.sizeInUsd, diffFactor);
    }

    function getOpenInterest(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.openInterestKey(market, isLong));
    }

    function getOpenInterestInTokens(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.openInterestInTokensKey(market, isLong));
    }

    // getOpenInterestInTokens * tokenPrice would not reflect pending positive pnl
    // from short positions, getOpenInterestWithPnl should be used if that info is needed
    function getOpenInterestWithPnl(DataStore dataStore, address market, Price.Props memory indexTokenPrice, bool isLong, bool maximize) internal view returns (uint256) {
        uint256 openInterest = getOpenInterest(dataStore, market, isLong);
        int256 pnl = getPnl(dataStore, market, indexTokenPrice, isLong, maximize);
        return Calc.sum(openInterest, pnl);
    }

    function getCollateralSum(DataStore dataStore, address market, address collateralToken,  bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.collateralSumKey(market, collateralToken, isLong));
    }

    function getReserveFactor(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.reserveFactorKey(market, isLong));
    }

    function getFundingFactor(DataStore dataStore, address market) internal view returns (uint256) {
        return dataStore.getUint(Keys.fundingFactorKey(market));
    }

    function getCumulativeFundingFactor(DataStore dataStore, address market, bool isLong) internal view returns (int256) {
        return dataStore.getInt(Keys.cumulativeFundingFactorKey(market, isLong));
    }

    function setCumulativeFundingFactor(DataStore dataStore, address market, bool isLong, int256 value) internal {
        dataStore.setInt(Keys.cumulativeFundingFactorKey(market, isLong), value);
    }

    function getCumulativeFundingFactorUpdatedAt(DataStore dataStore, address market) internal view returns (uint256) {
        return dataStore.getUint(Keys.cumulativeFundingFactorUpdatedAtKey(market));
    }

    function getSecondsSinceCumulativeFundingFactorUpdated(DataStore dataStore, address market) internal view returns (uint256) {
        uint256 updatedAt = getCumulativeFundingFactorUpdatedAt(dataStore, market);
        if (updatedAt == 0) { return 0; }
        return block.timestamp - updatedAt;
    }

    function getBorrowingFactor(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.borrowingFactorKey(market, isLong));
    }

    function getCumulativeBorrowingFactor(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.cumulativeBorrowingFactorKey(market, isLong));
    }

    function setCumulativeBorrowingFactor(DataStore dataStore, address market, bool isLong, uint256 value) internal {
        dataStore.setUint(Keys.cumulativeBorrowingFactorKey(market, isLong), value);
    }

    function getCumulativeBorrowingFactorUpdatedAt(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.cumulativeBorrowingFactorUpdatedAtKey(market, isLong));
    }

    function getSecondsSinceCumulativeBorrowingFactorUpdated(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        uint256 updatedAt = getCumulativeBorrowingFactorUpdatedAt(dataStore, market, isLong);
        if (updatedAt == 0) { return 0; }
        return block.timestamp - updatedAt;
    }

    function updateTotalBorrowing(
        DataStore dataStore,
        address market,
        bool isLong,
        uint256 prevPositionSizeInUsd,
        uint256 prevPositionBorrowingFactor,
        uint256 nextPositionSizeInUsd,
        uint256 nextPositionBorrowingFactor
    ) internal {
        uint256 totalBorrowing = getNextTotalBorrowing(
            dataStore,
            market,
            isLong,
            prevPositionSizeInUsd,
            prevPositionBorrowingFactor,
            nextPositionSizeInUsd,
            nextPositionBorrowingFactor
        );

        setTotalBorrowing(dataStore, market, isLong, totalBorrowing);
    }

    function getNextTotalBorrowing(
        DataStore dataStore,
        address market,
        bool isLong,
        uint256 prevPositionSizeInUsd,
        uint256 prevPositionBorrowingFactor,
        uint256 nextPositionSizeInUsd,
        uint256 nextPositionBorrowingFactor
    ) internal view returns (uint256) {
        uint256 totalBorrowing = getTotalBorrowing(dataStore, market, isLong);
        totalBorrowing -= prevPositionSizeInUsd * prevPositionBorrowingFactor;
        totalBorrowing += nextPositionSizeInUsd * nextPositionBorrowingFactor;

        return totalBorrowing;
    }

    function getNextCumulativeFundingFactors(DataStore dataStore, address market) internal view returns (int256, int256) {
        uint256 durationInSeconds = getSecondsSinceCumulativeFundingFactorUpdated(dataStore, market);
        uint256 fundingFactor = getFundingFactor(dataStore, market);

        uint256 longOpenInterest = getOpenInterest(dataStore, market, true);
        uint256 shortOpenInterest = getOpenInterest(dataStore, market, false);

        int256 longFundingFactor = getCumulativeFundingFactor(dataStore, market, true);
        int256 shortFundingFactor = getCumulativeFundingFactor(dataStore, market, false);

        if (longOpenInterest == 0 || shortOpenInterest == 0) {
            return (longFundingFactor, shortFundingFactor);
        }

        uint256 diffUsd = Calc.diff(longOpenInterest, shortOpenInterest);
        uint256 totalOpenInterest = longOpenInterest + shortOpenInterest;
        int256 adjustedFactor = (fundingFactor * diffUsd / totalOpenInterest * durationInSeconds).toInt256();

        if (longOpenInterest > shortOpenInterest) {
            // negative funding fee for long positions
            longFundingFactor += adjustedFactor;
            // capped positive funding fee for short positions
            shortFundingFactor -= getCappedFundingFactor(adjustedFactor, longOpenInterest, shortOpenInterest, durationInSeconds);
        } else {
            // negative funding fee for short positions
            shortFundingFactor += adjustedFactor;
            // positive funding fee for long positions
            longFundingFactor -= getCappedFundingFactor(adjustedFactor, shortOpenInterest, longOpenInterest, durationInSeconds);
        }

        return (longFundingFactor, shortFundingFactor);
    }

    function getNextCumulativeBorrowingFactor(
        DataStore dataStore,
        Market.Props memory market,
        MarketPrices memory prices,
        bool isLong
    ) internal view returns (uint256) {
        uint256 durationInSeconds = getSecondsSinceCumulativeBorrowingFactorUpdated(dataStore, market.marketToken, isLong);
        uint256 borrowingFactor = getBorrowingFactor(dataStore, market.marketToken, isLong);

        uint256 openInterestWithPnl = getOpenInterestWithPnl(dataStore, market.marketToken, prices.indexTokenPrice, isLong, true);

        uint256 poolAmount = getPoolAmount(dataStore, market.marketToken, isLong ? market.longToken : market.shortToken);
        uint256 poolTokenPrice = isLong ? prices.longTokenPrice.min : prices.shortTokenPrice.min;
        uint256 poolUsd = poolAmount * poolTokenPrice;

        uint256 adjustedFactor = durationInSeconds * borrowingFactor * openInterestWithPnl / poolUsd;
        uint256 cumulativeBorrowingFactor = getCumulativeBorrowingFactor(dataStore, market.marketToken, isLong);

        return cumulativeBorrowingFactor + adjustedFactor;
    }

    // cap the max factor to avoid overflow
    function getCappedFundingFactor(
        int256 adjustedFactor,
        uint256 multiplier,
        uint256 divisor,
        uint256 durationInSeconds
    ) internal pure returns (int256) {
        if (divisor == 0) { return 0; }

        int256 factor = adjustedFactor * multiplier.toInt256() / divisor.toInt256();
        int256 maxFactor = (MAX_ANNUAL_FUNDING_FACTOR * durationInSeconds / (365 days)).toInt256();

        if (factor > maxFactor) {
            return maxFactor;
        }

        return factor;
    }

    function getTotalBorrowingFees(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        uint256 openInterest = getOpenInterest(dataStore, market, isLong);
        uint256 cumulativeBorrowingFactor = getCumulativeBorrowingFactor(dataStore, market, isLong);
        uint256 totalBorrowing = getTotalBorrowing(dataStore, market, isLong);
        return openInterest * cumulativeBorrowingFactor - totalBorrowing;
    }

    // sum of position.borrowingFactor * position.size for all positions of the market
    // if funding is 100% for 100 years, the cumulativeBorrowingFactor could be as high as 100 * 1000 * (10 ** 30)
    // since position.size is a USD value with 30 decimals, under this scenario, there may be overflow issues
    // if open interest exceeds (2 ** 256) / (10 ** 30) / (100 * 100 * (10 ** 30)) => 11,579,209,000,000 USD
    function getTotalBorrowing(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.totalBorrowingKey(market, isLong));
    }

    function setTotalBorrowing(DataStore dataStore, address market, bool isLong, uint256 value) internal returns (uint256) {
        return dataStore.setUint(Keys.totalBorrowingKey(market, isLong), value);
    }

    function usdToMarketTokenAmount(
        uint256 usdValue,
        uint256 poolValue,
        uint256 supply
    ) internal pure returns (uint256) {
        if (supply == 0 || poolValue == 0) {
            return Precision.floatToWei(usdValue);
        }

        // round market tokens down
        return supply * usdValue / poolValue;
    }

    function marketTokenAmountToUsd(
        uint256 marketTokenAmount,
        uint256 poolValue,
        uint256 supply
    ) internal pure returns (uint256) {
        if (supply == 0 || poolValue == 0) {
            return 0;
        }

        return marketTokenAmount * poolValue / supply;
    }

    function validateNonEmptyMarket(Market.Props memory market) internal pure {
        if (market.marketToken == address(0)) {
            revert EmptyMarket();
        }
    }

    function getMarkets(MarketStore marketStore, address[] memory swapPath) internal view returns (Market.Props[] memory) {
        Market.Props[] memory markets = new Market.Props[](swapPath.length);

        for (uint256 i = 0; i < swapPath.length; i++) {
            Market.Props memory market = marketStore.get(swapPath[i]);
            validateNonEmptyMarket(market);
            markets[i] = market;
        }

        return markets;
    }
}
