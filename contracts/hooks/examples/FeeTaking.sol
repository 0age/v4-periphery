// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "../../BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract FeeTaking is BaseHook, IUnlockCallback, Owned {
    using SafeCast for uint256;

    bytes internal constant ZERO_BYTES = bytes("");
    uint128 private constant TOTAL_BIPS = 10000;
    uint128 private constant MAX_BIPS = 100;
    uint128 public swapFeeBips;

    struct CallbackData {
        address to;
        Currency[] currencies;
    }

    constructor(IPoolManager _poolManager, uint128 _swapFeeBips, address _owner) BaseHook(_poolManager) Owned(_owner) {
        swapFeeBips = _swapFeeBips;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        // fee will be in the unspecified token of the swap
        bool currency0Specified = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) =
            (currency0Specified) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        // if fee is on output, get the absolute output amount
        if (swapAmount < 0) swapAmount = -swapAmount;

        uint256 feeAmount = (uint128(swapAmount) * swapFeeBips) / TOTAL_BIPS;
        // mint ERC6909 instead of take to avoid edge case where PM doesn't have enough balance
        poolManager.mint(address(this), CurrencyLibrary.toId(feeCurrency), feeAmount);

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    function setSwapFeeBips(uint128 _swapFeeBips) external onlyOwner {
        require(_swapFeeBips <= MAX_BIPS);
        swapFeeBips = _swapFeeBips;
    }

    function withdraw(address to, Currency[] calldata currencies) external onlyOwner {
        poolManager.unlock(abi.encode(CallbackData(to, currencies)));
    }

    function unlockCallback(bytes calldata rawData)
        external
        override(IUnlockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        uint256 length = data.currencies.length;
        for (uint256 i = 0; i < length;) {
            uint256 amount = poolManager.balanceOf(address(this), CurrencyLibrary.toId(data.currencies[i]));
            poolManager.burn(address(this), CurrencyLibrary.toId(data.currencies[i]), amount);
            poolManager.take(data.currencies[i], data.to, amount);
            unchecked {
                i++;
            }
        }
        return ZERO_BYTES;
    }
}
