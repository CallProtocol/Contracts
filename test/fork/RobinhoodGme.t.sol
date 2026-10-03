// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ForkConfig} from "./ForkConfig.sol";
import {ForkTest} from "./ForkTest.sol";

/// @notice 冒烟：Robinhood Chain（chainId 4663）的分叉连得通，且读到的确实是真实的 GME。
///
/// 这里**不**测业务逻辑 —— 它证明的是「后面所有针对真实抵押品的分叉测试，地基是通的」。
/// 抵押品必须用真合约而不是 mock 的理由（发行方门控只有真合约测得准）见 issue #5。
contract RobinhoodGmeForkTest is ForkTest {
    IERC20Metadata internal gme;

    function setUp() public {
        selectFork(ForkConfig.robinhood());
        gme = IERC20Metadata(ForkConfig.GME);
    }

    function test_readsRealGmeTotalSupplyAndDecimals() public view {
        assertGt(ForkConfig.GME.code.length, 0, unicode"GME 地址上没有代码");

        uint8 decimals = gme.decimals();
        uint256 totalSupply = gme.totalSupply();

        // EIP-8056 下拆股改的是 uiMultiplier 而不是 balanceOf，decimals 恒为 18；
        // M1 一律按 raw balanceOf 记账，这条正是那个前提。
        assertEq(decimals, 18, "GME.decimals()");
        assertGt(totalSupply, 0, "GME.totalSupply()");
        assertEq(gme.symbol(), "GME", "GME.symbol()");

        console2.log(
            string.concat(
                "  GME: ",
                gme.name(),
                unicode" · totalSupply=",
                vm.toString(totalSupply),
                unicode" raw · decimals=",
                vm.toString(uint256(decimals))
            )
        );
    }
}
