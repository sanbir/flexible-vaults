// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "./CuratorUSDCBase.sol";

/// @title AaveUSDCDepositTest
/// @notice Integration test: curator deposits and withdraws USDC into Aave V3 Pool
///         via Mellow Subvault.call() on an Ethereum mainnet fork.
contract AaveUSDCDepositTest is CuratorUSDCBase {
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant A_USDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;

    BitmaskVerifier internal bitmaskVerifier;

    function setUp() external {
        _baseSetUp();
        bitmaskVerifier = new BitmaskVerifier();

        // Create subvault with dummy root
        IVerifier.VerificationPayload[] memory dummyLeaves = new IVerifier.VerificationPayload[](1);
        dummyLeaves[0] = IVerifier.VerificationPayload({
            verificationType: IVerifier.VerificationType.MERKLE_COMPACT,
            verificationData: abi.encodePacked(bytes32(uint256(1))),
            proof: new bytes32[](0)
        });
        _initSubvault(dummyLeaves);
    }

    /// @dev Generates Aave proofs for the current subvault and updates the merkle root.
    function _setupAaveProofs() internal returns (IVerifier.VerificationPayload[] memory proofs) {
        address[] memory collaterals = new address[](1);
        collaterals[0] = USDC;
        address[] memory loans = new address[](0);

        AaveLibrary.Info memory info = AaveLibrary.Info({
            subvault: address(subvault),
            subvaultName: "AaveSubvault",
            curator: $.curator,
            aaveInstance: AAVE_POOL,
            aaveInstanceName: "AaveV3",
            collaterals: collaterals,
            loans: loans,
            categoryId: 0
        });

        IVerifier.VerificationPayload[] memory leaves = AaveLibrary.getAaveProofs(bitmaskVerifier, info);
        bytes32 merkleRoot;
        (merkleRoot, proofs) = generateMerkleProofs(leaves);

        bytes32 setMerkleRootRole = Verifier(address(subvault.verifier())).SET_MERKLE_ROOT_ROLE();
        IVerifier verifier = subvault.verifier();
        vm.startPrank($.vaultAdmin);
        vault.grantRole(setMerkleRootRole, $.vaultAdmin);
        Verifier(address(verifier)).setMerkleRoot(merkleRoot);
        vm.stopPrank();
    }

    /// @dev Proof layout for 1 collateral + 0 loans (4 proofs):
    ///   [0] setUserEMode
    ///   [1] approve USDC → AAVE_POOL
    ///   [2] supply
    ///   [3] withdraw
    function testAaveDeposit_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupAaveProofs();
        uint256 depositAmount = 5_000e6;

        assertEq(IERC20(USDC).balanceOf(address(subvault)), USDC_AMOUNT);

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (AAVE_POOL, depositAmount)), proofs[1]);
        subvault.call(
            AAVE_POOL, 0, abi.encodeCall(IAavePoolV3.supply, (USDC, depositAmount, address(subvault), 0)), proofs[2]
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(subvault)), USDC_AMOUNT - depositAmount);
        assertGt(IERC20(A_USDC).balanceOf(address(subvault)), 0, "should hold aUSDC");
    }

    function testAaveWithdraw_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupAaveProofs();
        uint256 depositAmount = 5_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (AAVE_POOL, depositAmount)), proofs[1]);
        subvault.call(
            AAVE_POOL, 0, abi.encodeCall(IAavePoolV3.supply, (USDC, depositAmount, address(subvault), 0)), proofs[2]
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(subvault));
        subvault.call(
            AAVE_POOL,
            0,
            abi.encodeCall(IAavePoolV3.withdraw, (USDC, type(uint256).max, address(subvault))),
            proofs[3]
        );
        vm.stopPrank();

        assertGe(IERC20(USDC).balanceOf(address(subvault)), usdcBefore + depositAmount - 1);
        assertEq(IERC20(A_USDC).balanceOf(address(subvault)), 0);
    }
}
