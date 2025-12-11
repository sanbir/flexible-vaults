// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
interface IAccessControlEnumerableMinimal {
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
}

import {IDepositQueue} from "../../src/interfaces/queues/IDepositQueue.sol";
import {IRedeemQueue} from "../../src/interfaces/queues/IRedeemQueue.sol";
import {IOracle} from "../../src/interfaces/oracles/IOracle.sol";
import {IShareModule} from "../../src/interfaces/modules/IShareModule.sol";
import {IShareManager} from "../../src/interfaces/managers/IShareManager.sol";

/// @notice Mainnet fork smoke test covering the stRATEGY vault deposit -> redeem lifecycle end to end.
/// Uses real contracts and the live queues (no mocks).
contract StrategyLiveTest is Test {
    // Core addresses for the stRATEGY vault on Ethereum mainnet
    address constant VAULT = 0x277C6A642564A91ff78b008022D65683cEE5CCC5;
    address constant ORACLE = 0x8a78e6b7E15C4Ae3aeAeE3bf0DE4F2de4078c1cD;
    address constant SHARE_MANAGER = 0xcd3c0F51798D1daA92Fb192E57844Ae6cEE8a6c7;
    // First subvault (wstETH strategy leg; routes into Lido stack)
    address constant SUBVAULT_WSTETH = 0x90c983DC732e65DB6177638f0125914787b8Cb78;
    // Alternate subvault (wstETH leg that can represent Aave allocation)
    address constant SUBVAULT_AAVE = 0x893aa69FBAA1ee81B536f0FbE3A3453e86290080;
    address constant SINK = address(0xdead);

    // Queues (wstETH)
    address constant DEPOSIT_QUEUE_WSTETH = 0x614cb9E9D13712781DfD15aDC9F3DAde60E4eFAb;
    address constant REDEEM_QUEUE_WSTETH = 0x1ae8C006b5C97707aa074AaeD42BecAD2CF80Da2;

    // Asset (wstETH)
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // Oracle updater / accept role holder
    address constant ORACLE_UPDATER = 0xd27fFB15Dd00D5E52aC2BFE6d5AFD36caE850081;
    // Timelock (default admin for roles)
    address constant TIMELOCK = 0x8D8b65727729Fb484CB6dc1452D61608a5758596;

    // Fork selector
    string constant ETH_RPC_ENV = "ETH_RPC";

    // Snapshot state captured during the test
    address private user;

    function setUp() external {
        string memory rpc = vm.envString(ETH_RPC_ENV);
        uint256 fork = vm.createSelectFork(rpc); // latest block
        vm.selectFork(fork);
        user = vm.addr(1);
    }

    function test_stRATEGY() external {
        uint256 depositAmount = 0.01 ether;

        // Fund the user with wstETH
        deal(WSTETH, user, depositAmount);

        // Approve, deposit, process pricing, route into strategy, and simulate Lido rewards (scoped to trim locals)
        {
            uint256 subvaultBalanceBefore = IERC20(WSTETH).balanceOf(SUBVAULT_WSTETH);

            vm.startPrank(user);
            IERC20(WSTETH).approve(DEPOSIT_QUEUE_WSTETH, depositAmount);
            IDepositQueue(DEPOSIT_QUEUE_WSTETH).deposit(uint224(depositAmount), address(0), new bytes32[](0));
            vm.stopPrank();

            vm.warp(block.timestamp + 1);

            IOracle.DetailedReport memory report = IOracle(ORACLE).getReport(WSTETH);
            uint224 priceD18 = report.priceD18 == 0 ? uint224(1 ether) : report.priceD18;
            uint32 ts = uint32(block.timestamp - 1);

            vm.prank(VAULT);
            IDepositQueue(DEPOSIT_QUEUE_WSTETH).handleReport(priceD18, ts);

            uint256 subvaultBalanceAfterDeposit = IERC20(WSTETH).balanceOf(SUBVAULT_WSTETH);
            assertGt(subvaultBalanceAfterDeposit, subvaultBalanceBefore, "assets routed to strategy subvault");

            deal(WSTETH, SUBVAULT_WSTETH, subvaultBalanceAfterDeposit + (depositAmount / 10)); // +10% over user principal

            uint256 vaultBalanceAfterDeposit = IERC20(WSTETH).balanceOf(VAULT);
            if (vaultBalanceAfterDeposit > 0) {
                vm.prank(VAULT);
                IERC20(WSTETH).transfer(SINK, vaultBalanceAfterDeposit);
            }
        }

        // Claim shares on the vault (mints receipt tokens)
        vm.prank(user);
        IShareModule(VAULT).claimShares(user);

        uint256 userShares = IShareManager(SHARE_MANAGER).activeSharesOf(user);
        assertGt(userShares, 0, "shares minted");

        // Queue a redeem request on the live redeem queue
        vm.prank(user);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).redeem(userShares);

        // Advance time to satisfy redeem interval and report timestamp ordering
        vm.warp(block.timestamp + 2 hours + 1);

        uint224 priceD18 = IOracle(ORACLE).getReport(WSTETH).priceD18;
        if (priceD18 == 0) priceD18 = uint224(1 ether);

        // Process redeem pricing via oracle; ensure timestamp satisfies redeemInterval
        vm.prank(VAULT);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).handleReport(priceD18, uint32(block.timestamp - 1));

        // Ensure sufficient liquidity at the strategy leg to satisfy all batches (simulate unstaking from Lido)
        {
            (, , uint256 totalDemandAssets,) = IRedeemQueue(REDEEM_QUEUE_WSTETH).getState();
            uint256 currentSubBalance = IERC20(WSTETH).balanceOf(SUBVAULT_WSTETH);
            if (currentSubBalance < totalDemandAssets) {
                deal(WSTETH, SUBVAULT_WSTETH, totalDemandAssets + depositAmount);
            }
        }

        // Pull liquidity from the strategy leg (subvault) and move batches forward via the live hook
        IRedeemQueue(REDEEM_QUEUE_WSTETH).handleBatches(10);

        // Fetch request timestamp to claim
        IRedeemQueue.Request[] memory reqs = IRedeemQueue(REDEEM_QUEUE_WSTETH).requestsOf(user, 0, 1);
        require(reqs.length > 0, "request missing");
        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(reqs[0].timestamp);

        // Claim redeemed assets
        vm.startPrank(user);
        uint256 balBefore = IERC20(WSTETH).balanceOf(user);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).claim(user, timestamps);
        uint256 balAfter = IERC20(WSTETH).balanceOf(user);
        vm.stopPrank();

        assertGe(balAfter, balBefore + depositAmount * 99 / 100, "redeemed principal");
        assertEq(IShareManager(SHARE_MANAGER).activeSharesOf(user), 0, "shares burned");
    }

    /// @notice Demonstrates routing liquidity via an alternate strategy leg (Aave-like subvault) and redeeming from it.
    function test_stRATEGY_AAVE() external {
        uint256 depositAmount = 0.01 ether;

        // Deposit and process through live queue/oracle
        deal(WSTETH, user, depositAmount);
        vm.startPrank(user);
        IERC20(WSTETH).approve(DEPOSIT_QUEUE_WSTETH, depositAmount);
        IDepositQueue(DEPOSIT_QUEUE_WSTETH).deposit(uint224(depositAmount), address(0), new bytes32[](0));
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        IOracle.DetailedReport memory report = IOracle(ORACLE).getReport(WSTETH);
        uint224 priceD18 = report.priceD18 == 0 ? uint224(1 ether) : report.priceD18;
        uint32 ts = uint32(block.timestamp - 1);

        vm.prank(VAULT);
        IDepositQueue(DEPOSIT_QUEUE_WSTETH).handleReport(priceD18, ts);

        vm.prank(user);
        IShareModule(VAULT).claimShares(user);
        uint256 userShares = IShareManager(SHARE_MANAGER).activeSharesOf(user);
        assertGt(userShares, 0, "shares minted");

        // Request redeem
        vm.prank(user);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).redeem(userShares);
        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(VAULT);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).handleReport(priceD18, uint32(block.timestamp - 1));

        // Simulate liquidity residing in the Aave-like subvault; clear other holders to force pull from it
        (, , uint256 totalDemandAssets,) = IRedeemQueue(REDEEM_QUEUE_WSTETH).getState();
        deal(WSTETH, VAULT, 0);
        deal(WSTETH, SUBVAULT_WSTETH, 0);
        deal(WSTETH, SUBVAULT_AAVE, totalDemandAssets + depositAmount);

        // Handle batches pulls from allowed subvaults (here Aave leg) via the live redeem hook
        IRedeemQueue(REDEEM_QUEUE_WSTETH).handleBatches(10);

        IRedeemQueue.Request[] memory reqs = IRedeemQueue(REDEEM_QUEUE_WSTETH).requestsOf(user, 0, 1);
        require(reqs.length > 0, "request missing");
        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = uint32(reqs[0].timestamp);

        vm.startPrank(user);
        uint256 balBefore = IERC20(WSTETH).balanceOf(user);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).claim(user, timestamps);
        uint256 balAfter = IERC20(WSTETH).balanceOf(user);
        vm.stopPrank();

        assertGe(balAfter, balBefore + depositAmount * 99 / 100, "redeemed principal from Aave leg");
        assertEq(IShareManager(SHARE_MANAGER).activeSharesOf(user), 0, "shares burned");
    }
}
