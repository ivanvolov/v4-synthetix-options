// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/console.sol";

import {Position} from "v4-core/libraries/Position.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {OptionMathLib} from "@src/libraries/OptionMathLib.sol";
import {OptionBaseLib} from "@src/libraries/OptionBaseLib.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-core/../test/utils/LiquidityAmounts.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {IWETH} from "@forks/IWETH.sol";
import {BaseOptionHook} from "@src/BaseOptionHook.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IMorpho, MarketParams, Position as MorphoPosition, Id, Market} from "@forks/morpho/IMorpho.sol";
import {IOption} from "@src/interfaces/IOption.sol";

contract CallETH is BaseOptionHook, ERC721 {
    using CurrencySettleTake for Currency;
    using PoolIdLibrary for PoolKey;

    constructor(
        IPoolManager poolManager,
        Id _morphoMarketId
    ) BaseOptionHook(poolManager) ERC721("CallETH", "CALL") {
        morphoMarketId = _morphoMarketId;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override returns (bytes4) {
        console.log(">> afterInitialize");

        USDC.approve(OptionBaseLib.SWAP_ROUTER, type(uint256).max);
        WETH.approve(OptionBaseLib.SWAP_ROUTER, type(uint256).max);
        WSTETH.approve(OptionBaseLib.SWAP_ROUTER, type(uint256).max);
        OSQTH.approve(OptionBaseLib.SWAP_ROUTER, type(uint256).max);

        WSTETH.approve(address(morpho), type(uint256).max);
        USDC.approve(address(morpho), type(uint256).max);

        setTickLast(key.toId(), tick);

        return CallETH.afterInitialize.selector;
    }

    /// @notice  Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function deposit(
        PoolKey calldata key,
        uint256 amount,
        address to
    ) external returns (uint256 optionId) {
        console.log(">> deposit");
        if (amount == 0) revert ZeroLiquidity();
        WSTETH.transferFrom(msg.sender, address(this), amount);

        int24 tickLower;
        int24 tickUpper;
        {
            tickLower = getCurrentTick(key.toId());
            tickUpper = OptionMathLib.tickRoundDown(
                OptionMathLib.getTickFromPrice(
                    OptionMathLib.getPriceFromTick(tickLower) * 2
                ),
                key.tickSpacing
            );
            console.log("Ticks, lower/upper:");
            console.logInt(tickLower);
            console.logInt(tickUpper);

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(tickUpper),
                TickMath.getSqrtPriceAtTick(tickLower),
                amount / 2
            );

            poolManager.unlock(
                abi.encodeCall(
                    this.unlockModifyPosition,
                    (key, int128(liquidity), tickLower, tickUpper)
                )
            );
        }

        morpho.supplyCollateral(
            morpho.idToMarketParams(morphoMarketId),
            WSTETH.balanceOf(address(this)),
            address(this),
            ZERO_BYTES
        );
        optionId = optionIdCounter;

        optionInfo[optionId] = OptionInfo({
            amount: amount,
            tick: getCurrentTick(key.toId()),
            tickLower: tickLower,
            tickUpper: tickUpper,
            created: block.timestamp
        });

        _mint(to, optionId);
        optionIdCounter++;
    }

    function withdraw(
        PoolKey calldata key,
        uint256 optionId,
        address to
    ) external {
        console.log(">> withdraw");
        if (ownerOf(optionId) != msg.sender) revert NotAnOptionOwner();

        //** swap all OSQTH in WSTETH
        uint256 balanceOSQTH = OSQTH.balanceOf(address(this));
        if (balanceOSQTH != 0) {
            uint256 amountWETH = OptionBaseLib.swapExactInput(
                address(OSQTH),
                address(WETH),
                uint256(int256(balanceOSQTH))
            );

            OptionBaseLib.swapExactInput(
                address(WETH),
                address(WSTETH),
                amountWETH
            );
        }

        //** close position into WSTETH & USDC
        {
            (
                uint128 liquidity,
                int24 tickLower,
                int24 tickUpper
            ) = getOptionPosition(key, optionId);

            poolManager.unlock(
                abi.encodeCall(
                    this.unlockModifyPosition,
                    (key, -int128(liquidity), tickLower, tickUpper)
                )
            );
        }

        //** Now we could have, USDC & WSTETH

        //** if USDC is borrowed buy extra and close the position
        morpho.accrueInterest(morpho.idToMarketParams(morphoMarketId)); //TODO: is this sync morpho here or not?
        Market memory m = morpho.market(morphoMarketId);
        MorphoPosition memory p = morpho.position(
            morphoMarketId,
            address(this)
        );
        uint256 usdcToRepay = m.totalBorrowAssets; //TODO: this is a bad huck, fix in the future
        if (usdcToRepay != 0) {
            uint256 balanceUSDC = USDC.balanceOf(address(this));
            if (usdcToRepay > balanceUSDC) {
                console.log("> buy USDC to repay");
                OptionBaseLib.swapExactOutput(
                    address(WSTETH),
                    address(USDC),
                    usdcToRepay - balanceUSDC
                );
            } else {
                console.log("> sell extra USDC");
                OptionBaseLib.swapExactOutput(
                    address(USDC),
                    address(WSTETH),
                    balanceUSDC
                );
            }

            morpho.repay(
                morpho.idToMarketParams(morphoMarketId),
                0,
                p.borrowShares,
                address(this),
                ZERO_BYTES
            );
        }

        morpho.withdrawCollateral(
            morpho.idToMarketParams(morphoMarketId),
            p.collateral,
            address(this),
            address(this)
        );

        WSTETH.transfer(to, WSTETH.balanceOf(address(this)));

        delete optionInfo[optionId];
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta deltas,
        bytes calldata
    ) external virtual override returns (bytes4, int128) {
        console.log(">> afterSwap");
        if (deltas.amount0() == 0 && deltas.amount1() == 0)
            revert NoSwapWillOccur();
        //TODO: add here revert if the pool have enough liquidity but the extra operations is not possible for the current swap magnitude

        int24 tick = getCurrentTick(key.toId());

        if (tick > getTickLast(key.toId())) {
            console.log("> price go up...");

            morpho.borrow(
                morpho.idToMarketParams(morphoMarketId),
                uint256(int256(-deltas.amount1())),
                0,
                address(this),
                address(this)
            );

            uint256 amountOut = OptionBaseLib.swapExactInput(
                address(USDC),
                address(WETH),
                uint256(int256(-deltas.amount1()))
            );
            OptionBaseLib.swapExactInput(
                address(WETH),
                address(OSQTH),
                amountOut
            );
        } else if (tick < getTickLast(key.toId())) {
            console.log("> price go down...");

            MorphoPosition memory p = morpho.position(
                morphoMarketId,
                address(this)
            );
            if (p.borrowShares != 0) {
                //TODO: here implement the part if borrowShares to USDC is < deltas in USDC
                OptionBaseLib.swapOSQTH_USDC_Out(
                    uint256(int256(deltas.amount1()))
                );

                morpho.repay(
                    morpho.idToMarketParams(morphoMarketId),
                    uint256(int256(deltas.amount1())),
                    0,
                    address(this),
                    ZERO_BYTES
                );
            }
        } else {
            console.log("> price not changing...");
        }

        setTickLast(key.toId(), tick);
        return (CallETH.afterSwap.selector, 0);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
