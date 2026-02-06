// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "./CuratorUSDCBase.sol";

/// @title FluidUSDCDepositTest
/// @notice Integration test: curator deposits and withdraws USDC into Fluid fUSDC
///         (ERC-4626 fToken) via Mellow Subvault.call() on an Ethereum mainnet fork.
contract FluidUSDCDepositTest is CuratorUSDCBase {
    address constant FLUID_FUSDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;

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

    /// @dev ERC4626 proofs for 1 asset (5 proofs):
    ///   [0] approve underlying → vault
    ///   [1] deposit
    ///   [2] mint
    ///   [3] redeem
    ///   [4] withdraw
    function _setupFluidProofs() internal returns (IVerifier.VerificationPayload[] memory proofs) {
        address[] memory erc4626Assets = new address[](1);
        erc4626Assets[0] = FLUID_FUSDC;

        ERC4626Library.Info memory info = ERC4626Library.Info({
            subvault: address(subvault),
            subvaultName: "FluidSubvault",
            curator: $.curator,
            assets: erc4626Assets
        });

        IVerifier.VerificationPayload[] memory leaves = ERC4626Library.getERC4626Proofs(bitmaskVerifier, info);
        bytes32 merkleRoot;
        (merkleRoot, proofs) = generateMerkleProofs(leaves);

        bytes32 setMerkleRootRole = Verifier(address(subvault.verifier())).SET_MERKLE_ROOT_ROLE();
        IVerifier verifier = subvault.verifier();
        vm.startPrank($.vaultAdmin);
        vault.grantRole(setMerkleRootRole, $.vaultAdmin);
        Verifier(address(verifier)).setMerkleRoot(merkleRoot);
        vm.stopPrank();
    }

    function testFluidDeposit_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupFluidProofs();
        uint256 depositAmount = 5_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (FLUID_FUSDC, depositAmount)), proofs[0]);
        subvault.call(
            FLUID_FUSDC, 0, abi.encodeCall(IERC4626.deposit, (depositAmount, address(subvault))), proofs[1]
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(subvault)), USDC_AMOUNT - depositAmount);
        assertGt(IERC20(FLUID_FUSDC).balanceOf(address(subvault)), 0, "should hold fUSDC");
    }

    function testFluidWithdraw_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupFluidProofs();
        uint256 depositAmount = 5_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (FLUID_FUSDC, depositAmount)), proofs[0]);
        subvault.call(
            FLUID_FUSDC, 0, abi.encodeCall(IERC4626.deposit, (depositAmount, address(subvault))), proofs[1]
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(subvault));
        uint256 shares = IERC20(FLUID_FUSDC).balanceOf(address(subvault));

        subvault.call(
            FLUID_FUSDC,
            0,
            abi.encodeCall(IERC4626.redeem, (shares, address(subvault), address(subvault))),
            proofs[3]
        );
        vm.stopPrank();

        assertGe(IERC20(USDC).balanceOf(address(subvault)), usdcBefore + depositAmount - 1);
        assertEq(IERC20(FLUID_FUSDC).balanceOf(address(subvault)), 0);
    }
}
