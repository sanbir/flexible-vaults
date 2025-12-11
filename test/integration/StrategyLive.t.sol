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

        // Approve and deposit into the live wstETH deposit queue
        vm.startPrank(user);
        IERC20(WSTETH).approve(DEPOSIT_QUEUE_WSTETH, depositAmount);
        IDepositQueue(DEPOSIT_QUEUE_WSTETH).deposit(uint224(depositAmount), address(0), new bytes32[](0));
        vm.stopPrank();

        // Move time forward so the report timestamp can trail the current block but cover the request
        vm.warp(block.timestamp + 1);

        // Latest oracle price for wstETH
        IOracle.DetailedReport memory report = IOracle(ORACLE).getReport(WSTETH);
        uint224 priceD18 = report.priceD18 == 0 ? uint224(1 ether) : report.priceD18;
        uint32 ts = uint32(block.timestamp - 1);

        // Propagate a fresh report directly via the vault (avoids reporter role frictions on fork)
        vm.prank(VAULT);
        IDepositQueue(DEPOSIT_QUEUE_WSTETH).handleReport(priceD18, ts);

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

        // Process redeem pricing via oracle; ensure timestamp satisfies redeemInterval
        vm.prank(VAULT);
        IRedeemQueue(REDEEM_QUEUE_WSTETH).handleReport(priceD18, uint32(block.timestamp - 1));

        // Inject liquidity to cover all outstanding batches so the live queue can settle immediately
        (, , uint256 totalDemandAssets,) = IRedeemQueue(REDEEM_QUEUE_WSTETH).getState();
        deal(WSTETH, VAULT, totalDemandAssets + depositAmount + 1 ether);

        // Pull liquidity and move batches forward
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
}
