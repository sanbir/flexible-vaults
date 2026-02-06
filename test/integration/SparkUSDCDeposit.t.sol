// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "./CuratorUSDCBase.sol";
import "../../scripts/common/protocols/SparkLibrary.sol";

/// @title SparkUSDCDepositTest
/// @notice Integration test: curator deposits and withdraws USDC into SparkLend Pool
///         via Mellow Subvault.call() on an Ethereum mainnet fork.
contract SparkUSDCDepositTest is CuratorUSDCBase {
    address constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address constant SP_USDC = 0x377C3bd93f2a2984E1E7bE6A5C22c525eD4A4815;

    BitmaskVerifier internal bitmaskVerifier;

    function setUp() external {
        _baseSetUp();
        bitmaskVerifier = new BitmaskVerifier();

        IVerifier.VerificationPayload[] memory dummyLeaves = new IVerifier.VerificationPayload[](1);
        dummyLeaves[0] = IVerifier.VerificationPayload({
            verificationType: IVerifier.VerificationType.MERKLE_COMPACT,
            verificationData: abi.encodePacked(bytes32(uint256(1))),
            proof: new bytes32[](0)
        });
        _initSubvault(dummyLeaves);
    }

    function _setupSparkProofs() internal returns (IVerifier.VerificationPayload[] memory proofs) {
        address[] memory collaterals = new address[](1);
        collaterals[0] = USDC;
        address[] memory loans = new address[](0);

        AaveLibrary.Info memory info = AaveLibrary.Info({
            subvault: address(subvault),
            subvaultName: "SparkSubvault",
            curator: $.curator,
            aaveInstance: SPARK_POOL,
            aaveInstanceName: "SparkLend",
            collaterals: collaterals,
            loans: loans,
            categoryId: 0
        });

        IVerifier.VerificationPayload[] memory leaves = SparkLibrary.getSparkProofs(bitmaskVerifier, info);
        bytes32 merkleRoot;
        (merkleRoot, proofs) = generateMerkleProofs(leaves);

        bytes32 setMerkleRootRole = Verifier(address(subvault.verifier())).SET_MERKLE_ROOT_ROLE();
        IVerifier verifier = subvault.verifier();
        vm.startPrank($.vaultAdmin);
        vault.grantRole(setMerkleRootRole, $.vaultAdmin);
        Verifier(address(verifier)).setMerkleRoot(merkleRoot);
        vm.stopPrank();
    }

    function testSparkDeposit_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupSparkProofs();
        uint256 depositAmount = 5_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (SPARK_POOL, depositAmount)), proofs[1]);
        subvault.call(
            SPARK_POOL, 0, abi.encodeCall(IAavePoolV3.supply, (USDC, depositAmount, address(subvault), 0)), proofs[2]
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(subvault)), USDC_AMOUNT - depositAmount);
        assertGt(IERC20(SP_USDC).balanceOf(address(subvault)), 0, "should hold spUSDC");
    }

    function testSparkWithdraw_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupSparkProofs();
        uint256 depositAmount = 5_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (SPARK_POOL, depositAmount)), proofs[1]);
        subvault.call(
            SPARK_POOL, 0, abi.encodeCall(IAavePoolV3.supply, (USDC, depositAmount, address(subvault), 0)), proofs[2]
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(subvault));
        subvault.call(
            SPARK_POOL,
            0,
            abi.encodeCall(IAavePoolV3.withdraw, (USDC, type(uint256).max, address(subvault))),
            proofs[3]
        );
        vm.stopPrank();

        assertGe(IERC20(USDC).balanceOf(address(subvault)), usdcBefore + depositAmount - 1);
    }
}
