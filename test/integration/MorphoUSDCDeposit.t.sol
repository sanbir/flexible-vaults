// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "./CuratorUSDCBase.sol";

/// @title MorphoUSDCDepositTest
/// @notice Integration test: curator deposits and withdraws USDC into
///         Morpho Gauntlet USDC Prime and Morpho Steakhouse USDC MetaMorpho vaults
///         (both ERC-4626) via Mellow Subvault.call() on an Ethereum mainnet fork.
contract MorphoUSDCDepositTest is CuratorUSDCBase {
    address constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;
    address constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

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

    /// @dev For 2 assets, ERC4626Library generates 10 proofs (5 per asset):
    ///   Asset 0 (Gauntlet): [0]=approve, [1]=deposit, [2]=mint, [3]=redeem, [4]=withdraw
    ///   Asset 1 (Steakhouse): [5]=approve, [6]=deposit, [7]=mint, [8]=redeem, [9]=withdraw
    function _setupMorphoProofs() internal returns (IVerifier.VerificationPayload[] memory proofs) {
        address[] memory erc4626Assets = new address[](2);
        erc4626Assets[0] = GAUNTLET_USDC_PRIME;
        erc4626Assets[1] = STEAKHOUSE_USDC;

        ERC4626Library.Info memory info = ERC4626Library.Info({
            subvault: address(subvault),
            subvaultName: "MorphoSubvault",
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

    // ──────────── Gauntlet USDC Prime ────────────

    function testGauntletDeposit_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupMorphoProofs();
        uint256 depositAmount = 3_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (GAUNTLET_USDC_PRIME, depositAmount)), proofs[0]);
        subvault.call(
            GAUNTLET_USDC_PRIME,
            0,
            abi.encodeCall(IERC4626.deposit, (depositAmount, address(subvault))),
            proofs[1]
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(subvault)), USDC_AMOUNT - depositAmount);
        assertGt(IERC20(GAUNTLET_USDC_PRIME).balanceOf(address(subvault)), 0, "should hold gtUSDC");
    }

    function testGauntletWithdraw_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupMorphoProofs();
        uint256 depositAmount = 3_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (GAUNTLET_USDC_PRIME, depositAmount)), proofs[0]);
        subvault.call(
            GAUNTLET_USDC_PRIME,
            0,
            abi.encodeCall(IERC4626.deposit, (depositAmount, address(subvault))),
            proofs[1]
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(subvault));
        uint256 shares = IERC20(GAUNTLET_USDC_PRIME).balanceOf(address(subvault));

        subvault.call(
            GAUNTLET_USDC_PRIME,
            0,
            abi.encodeCall(IERC4626.redeem, (shares, address(subvault), address(subvault))),
            proofs[3]
        );
        vm.stopPrank();

        assertGe(IERC20(USDC).balanceOf(address(subvault)), usdcBefore + depositAmount - 1);
        assertEq(IERC20(GAUNTLET_USDC_PRIME).balanceOf(address(subvault)), 0);
    }

    // ──────────── Steakhouse USDC ────────────

    function testSteakhouseDeposit_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupMorphoProofs();
        uint256 depositAmount = 3_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (STEAKHOUSE_USDC, depositAmount)), proofs[5]);
        subvault.call(
            STEAKHOUSE_USDC,
            0,
            abi.encodeCall(IERC4626.deposit, (depositAmount, address(subvault))),
            proofs[6]
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(address(subvault)), USDC_AMOUNT - depositAmount);
        assertGt(IERC20(STEAKHOUSE_USDC).balanceOf(address(subvault)), 0, "should hold steakUSDC");
    }

    function testSteakhouseWithdraw_NO_CI() external {
        IVerifier.VerificationPayload[] memory proofs = _setupMorphoProofs();
        uint256 depositAmount = 3_000e6;

        vm.startPrank($.curator);
        subvault.call(USDC, 0, abi.encodeCall(IERC20.approve, (STEAKHOUSE_USDC, depositAmount)), proofs[5]);
        subvault.call(
            STEAKHOUSE_USDC,
            0,
            abi.encodeCall(IERC4626.deposit, (depositAmount, address(subvault))),
            proofs[6]
        );

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(subvault));
        uint256 shares = IERC20(STEAKHOUSE_USDC).balanceOf(address(subvault));

        subvault.call(
            STEAKHOUSE_USDC,
            0,
            abi.encodeCall(IERC4626.redeem, (shares, address(subvault), address(subvault))),
            proofs[8]
        );
        vm.stopPrank();

        assertGe(IERC20(USDC).balanceOf(address(subvault)), usdcBefore + depositAmount - 1);
        assertEq(IERC20(STEAKHOUSE_USDC).balanceOf(address(subvault)), 0);
    }
}
