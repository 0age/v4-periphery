// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryValidation.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {IPoolManager, PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";

contract NonfungiblePositionManager is
    ERC721,
    PeripheryImmutableState,
    INonfungiblePositionManager,
    PeripheryValidation
{
    using PoolIdLibrary for PoolKey;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    struct CallbackData {
        address sender;
        MintParams params;
    }

    // details about the uniswap position
    struct Position {
        PoolKey poolKey;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    constructor(PoolManager _poolManager, address _WETH9)
        ERC721("Uniswap V4 Positions NFT-V1", "UNI-V4-POS")
        PeripheryImmutableState(_poolManager, _WETH9)
    {}

    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (tokenId, liquidity, amount0, amount1) = abi.decode(
            poolManager.lock(abi.encode(CallbackData(msg.sender, params))), (uint256, uint128, uint256, uint256)
        );
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolId poolId = data.params.poolKey.toId();
        MintParams memory params = data.params;
        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
        );
        BalanceDelta delta = poolManager.modifyPosition(
            params.poolKey,
            IPoolManager.ModifyPositionParams(params.tickLower, params.tickUpper, int256(int128(liquidity)))
        );

        uint256 tokenId = _nextId++;
        _mint(params.recipient, tokenId);

//        bytes32 positionKey = PositionKey.compute(address(this), params.tickLower, params.tickUpper);
//        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);
//        poolManager.getPosition(poolId, address(this), params.tickLower, params.tickUpper);

        if (delta.amount0() > 0) {
            IERC20(Currency.unwrap(params.poolKey.currency0)).transferFrom(
                data.sender, address(poolManager), uint256(int256(delta.amount0()))
            );
            poolManager.settle(params.poolKey.currency0);
        }
        if (delta.amount1() > 0) {
            IERC20(Currency.unwrap(params.poolKey.currency1)).transferFrom(
                data.sender, address(poolManager), uint256(int256(delta.amount1()))
            );
            poolManager.settle(params.poolKey.currency1);
        }
        return abi.encode(tokenId, liquidity, delta.amount0(), delta.amount1());
    }
}
