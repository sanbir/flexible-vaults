// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../../../scripts/common/ProofLibrary.sol";
import "../../../scripts/common/ArraysLibrary.sol";
import "../../../scripts/common/interfaces/Imports.sol";

import "../../../scripts/common/protocols/ERC4626Library.sol";
import "../../../scripts/common/protocols/AaveLibrary.sol";
import "../../../scripts/common/protocols/FluidLibrary.sol";
import "../../../scripts/common/protocols/ResolvLibrary.sol";

import "../../../src/permissions/BitmaskVerifier.sol";
import "../../../src/permissions/Verifier.sol";

// ──────────────────── Mocks ────────────────────

contract MockToken {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

/// @dev Minimal ERC4626-like mock that returns a fixed asset()
contract MockERC4626Token is MockToken {
    address internal _asset;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address asset_)
        MockToken(name_, symbol_, decimals_)
    {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }
}

/// @dev Minimal mock for IFluidVault
contract MockFluidVault {
    address public supplyToken;
    address public borrowToken;

    constructor(address supplyToken_, address borrowToken_) {
        supplyToken = supplyToken_;
        borrowToken = borrowToken_;
    }

    function constantsView() external view returns (IFluidVault.ConstantViews memory) {
        return IFluidVault.ConstantViews({
            liquidity: address(0),
            factory: address(0),
            adminImplementation: address(0),
            secondaryImplementation: address(0),
            supplyToken: supplyToken,
            borrowToken: borrowToken,
            supplyDecimals: 18,
            borrowDecimals: 18,
            vaultId: 1,
            liquiditySupplyExchangePriceSlot: bytes32(0),
            liquidityBorrowExchangePriceSlot: bytes32(0),
            liquidityUserSupplySlot: bytes32(0),
            liquidityUserBorrowSlot: bytes32(0)
        });
    }

    function operate(uint256, int256, int256, address) external payable returns (uint256, int256, int256) {
        return (0, 0, 0);
    }
}

/// @dev Mock that satisfies IAccessControl for the Verifier
contract MockVaultACL {
    mapping(bytes32 => mapping(address => bool)) private _roles;

    function grantRole(bytes32 role, address account) external {
        _roles[role][account] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function getRoleAdmin(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function revokeRole(bytes32, address) external {}

    function renounceRole(bytes32, address) external {}
}

// ──────────────────── Test Contract ────────────────────

/// @title ProtocolLibrariesTest
/// @notice Verifies that ERC4626Library, AaveLibrary, FluidLibrary, and ResolvLibrary
///         produce correct Call[][] arrays and that BitmaskVerifier-based proofs
///         pass/fail exactly as expected when verified through a real Verifier.
contract ProtocolLibrariesTest is Test {
    BitmaskVerifier internal bitmaskVerifier;
    Verifier internal verifierImpl;
    MockVaultACL internal mockVault;
    address internal proxyAdmin;

    address internal curator = makeAddr("curator");
    address internal subvault = makeAddr("subvault");

    // Mock tokens
    MockToken internal wstETH;
    MockToken internal usdc;
    MockERC4626Token internal erc4626Vault;

    bytes32 internal constant CALLER_ROLE = keccak256("permissions.Verifier.CALLER_ROLE");

    function setUp() public {
        bitmaskVerifier = new BitmaskVerifier();
        verifierImpl = new Verifier("Mellow", 1);

        mockVault = new MockVaultACL();
        mockVault.grantRole(CALLER_ROLE, curator);
        proxyAdmin = makeAddr("proxyAdmin");

        wstETH = new MockToken("Wrapped stETH", "wstETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        erc4626Vault = new MockERC4626Token("ERC4626 Vault", "v4626", 18, address(wstETH));
    }

    // ──────────────────── Helpers ────────────────────

    /// @dev Verifies a single call against the verifier, returning the result.
    function _checkCall(Verifier verifier, Call memory call_, IVerifier.VerificationPayload memory proof)
        internal
        view
        returns (bool)
    {
        return verifier.getVerificationResult(call_.who, call_.where, call_.value, call_.data, proof);
    }

    /// @dev Deploys a fresh Verifier proxy initialized with the given Merkle root,
    ///      then asserts that every call in every group matches its expected verification result.
    function _verifyCallGroups(IVerifier.VerificationPayload[] memory proofs, Call[][] memory callGroups) internal {
        // Build Merkle tree and proofs
        bytes32 merkleRoot;
        (merkleRoot, proofs) = ProofLibrary.generateMerkleProofs(proofs);

        // Deploy a fresh Verifier proxy
        Verifier verifier = Verifier(
            address(new TransparentUpgradeableProxy(address(verifierImpl), proxyAdmin, new bytes(0)))
        );
        verifier.initialize(abi.encode(address(mockVault), merkleRoot));

        // Verify dimensions match
        assertEq(proofs.length, callGroups.length, "proofs.length != callGroups.length");

        uint256 totalTrue;
        uint256 totalFalse;

        for (uint256 g = 0; g < callGroups.length; g++) {
            assertGt(callGroups[g].length, 0, string(abi.encodePacked("group ", vm.toString(g), " is empty")));

            for (uint256 c = 0; c < callGroups[g].length; c++) {
                bool result = _checkCall(verifier, callGroups[g][c], proofs[g]);

                if (callGroups[g][c].verificationResult) {
                    assertTrue(result, string(abi.encodePacked("PASS g=", vm.toString(g), " c=", vm.toString(c))));
                    totalTrue++;
                } else {
                    assertFalse(result, string(abi.encodePacked("FAIL g=", vm.toString(g), " c=", vm.toString(c))));
                    totalFalse++;
                }
            }
        }

        // Sanity: we must have both positive and negative test vectors
        assertGt(totalTrue, 0, "No passing calls found across all groups");
        assertGt(totalFalse, 0, "No failing calls found across all groups");
    }

    /// @dev Asserts that every group has at least one true and one false call.
    function _assertMixedResults(Call[][] memory callGroups, string memory prefix) internal pure {
        for (uint256 i = 0; i < callGroups.length; i++) {
            uint256 trueCount;
            uint256 falseCount;
            for (uint256 j = 0; j < callGroups[i].length; j++) {
                if (callGroups[i][j].verificationResult) trueCount++;
                else falseCount++;
            }
            require(trueCount > 0, string(abi.encodePacked(prefix, " group ", Strings.toString(i), ": no true calls")));
            require(
                falseCount > 0, string(abi.encodePacked(prefix, " group ", Strings.toString(i), ": no false calls"))
            );
        }
    }

    // ──────────────────── ERC4626Library ────────────────────

    function testERC4626Library_SingleAsset() external {
        address[] memory assets = new address[](1);
        assets[0] = address(erc4626Vault);

        ERC4626Library.Info memory info = ERC4626Library.Info({
            subvault: subvault,
            subvaultName: "TestSubvault",
            curator: curator,
            assets: assets
        });

        IVerifier.VerificationPayload[] memory proofs = ERC4626Library.getERC4626Proofs(bitmaskVerifier, info);
        Call[][] memory calls = ERC4626Library.getERC4626Calls(info);

        // 5 operations per asset: approve, deposit, mint, redeem, withdraw
        assertEq(proofs.length, 5, "ERC4626: expected 5 proofs");
        assertEq(calls.length, 5, "ERC4626: expected 5 call groups");

        _assertMixedResults(calls, "ERC4626");
        _verifyCallGroups(proofs, calls);
    }

    function testERC4626Library_MultipleAssets() external {
        MockERC4626Token vault2 = new MockERC4626Token("Second Vault", "v2", 18, address(usdc));

        address[] memory assets = new address[](2);
        assets[0] = address(erc4626Vault);
        assets[1] = address(vault2);

        ERC4626Library.Info memory info = ERC4626Library.Info({
            subvault: subvault,
            subvaultName: "TestSubvault",
            curator: curator,
            assets: assets
        });

        IVerifier.VerificationPayload[] memory proofs = ERC4626Library.getERC4626Proofs(bitmaskVerifier, info);
        Call[][] memory calls = ERC4626Library.getERC4626Calls(info);

        // 5 operations * 2 assets = 10
        assertEq(proofs.length, 10, "ERC4626 multi: expected 10 proofs");
        assertEq(calls.length, 10, "ERC4626 multi: expected 10 call groups");

        _assertMixedResults(calls, "ERC4626-multi");
        _verifyCallGroups(proofs, calls);
    }

    // ──────────────────── AaveLibrary ────────────────────

    function testAaveLibrary_SingleCollateralSingleLoan() external {
        address aavePool = makeAddr("aavePool");

        address[] memory collaterals = new address[](1);
        collaterals[0] = address(wstETH);

        address[] memory loans = new address[](1);
        loans[0] = address(usdc);

        AaveLibrary.Info memory info = AaveLibrary.Info({
            subvault: subvault,
            subvaultName: "TestSubvault",
            curator: curator,
            aaveInstance: aavePool,
            aaveInstanceName: "AaveV3",
            collaterals: collaterals,
            loans: loans,
            categoryId: 1
        });

        IVerifier.VerificationPayload[] memory proofs = AaveLibrary.getAaveProofs(bitmaskVerifier, info);
        Call[][] memory calls = AaveLibrary.getAaveCalls(info);

        // (1 + 1) * 3 + 1 = 7
        assertEq(proofs.length, 7, "Aave: expected 7 proofs");
        assertEq(calls.length, 7, "Aave: expected 7 call groups");

        _assertMixedResults(calls, "Aave");
        _verifyCallGroups(proofs, calls);
    }

    function testAaveLibrary_MultipleCollateralsAndLoans() external {
        address aavePool = makeAddr("aavePool");

        address[] memory collaterals = new address[](2);
        collaterals[0] = address(wstETH);
        collaterals[1] = address(new MockToken("cbETH", "cbETH", 18));

        address[] memory loans = new address[](2);
        loans[0] = address(usdc);
        loans[1] = address(new MockToken("USDT", "USDT", 6));

        AaveLibrary.Info memory info = AaveLibrary.Info({
            subvault: subvault,
            subvaultName: "TestSubvault",
            curator: curator,
            aaveInstance: aavePool,
            aaveInstanceName: "AaveV3",
            collaterals: collaterals,
            loans: loans,
            categoryId: 2
        });

        IVerifier.VerificationPayload[] memory proofs = AaveLibrary.getAaveProofs(bitmaskVerifier, info);
        Call[][] memory calls = AaveLibrary.getAaveCalls(info);

        // (2 + 2) * 3 + 1 = 13
        assertEq(proofs.length, 13, "Aave multi: expected 13 proofs");
        assertEq(calls.length, 13, "Aave multi: expected 13 call groups");

        _assertMixedResults(calls, "Aave-multi");
        _verifyCallGroups(proofs, calls);
    }

    function testAaveLibrary_CollateralOnly() external {
        address aavePool = makeAddr("aavePool");

        address[] memory collaterals = new address[](1);
        collaterals[0] = address(wstETH);

        address[] memory loans = new address[](0);

        AaveLibrary.Info memory info = AaveLibrary.Info({
            subvault: subvault,
            subvaultName: "TestSubvault",
            curator: curator,
            aaveInstance: aavePool,
            aaveInstanceName: "AaveV3",
            collaterals: collaterals,
            loans: loans,
            categoryId: 0
        });

        IVerifier.VerificationPayload[] memory proofs = AaveLibrary.getAaveProofs(bitmaskVerifier, info);
        Call[][] memory calls = AaveLibrary.getAaveCalls(info);

        // (1 + 0) * 3 + 1 = 4
        assertEq(proofs.length, 4, "Aave collateral-only: expected 4 proofs");
        assertEq(calls.length, 4, "Aave collateral-only: expected 4 call groups");

        _assertMixedResults(calls, "Aave-collat");
        _verifyCallGroups(proofs, calls);
    }

    // ──────────────────── FluidLibrary ────────────────────

    function testFluidLibrary_CallsVerification() external {
        MockFluidVault fluidVault = new MockFluidVault(address(wstETH), address(usdc));
        uint256 nft = 42;

        FluidLibrary.Info memory info = FluidLibrary.Info({
            curator: curator,
            subvault: subvault,
            subvaultName: "TestSubvault",
            fluidVault: address(fluidVault),
            nft: nft
        });

        IVerifier.VerificationPayload[] memory proofs = FluidLibrary.getFluidProofs(bitmaskVerifier, info);
        Call[][] memory calls = FluidLibrary.getFluidCalls(info);

        // 2 ERC20 approves + 1 operate = 3
        assertEq(proofs.length, 3, "Fluid: expected 3 proofs");
        assertEq(calls.length, 3, "Fluid: expected 3 call groups");

        _assertMixedResults(calls, "Fluid");
        _verifyCallGroups(proofs, calls);
    }

    function testFluidLibrary_LargeNft() external {
        MockFluidVault fluidVault = new MockFluidVault(address(wstETH), address(usdc));

        // Test with a large NFT ID
        FluidLibrary.Info memory info = FluidLibrary.Info({
            curator: curator,
            subvault: subvault,
            subvaultName: "TestSubvault",
            fluidVault: address(fluidVault),
            nft: type(uint128).max
        });

        IVerifier.VerificationPayload[] memory proofs = FluidLibrary.getFluidProofs(bitmaskVerifier, info);
        Call[][] memory calls = FluidLibrary.getFluidCalls(info);

        assertEq(proofs.length, calls.length, "Fluid large-nft: proofs/calls mismatch");
        _assertMixedResults(calls, "Fluid-large");
        _verifyCallGroups(proofs, calls);
    }

    /// @dev NOTE: FluidLibrary.getFluidCalls has a known edge case when nft=0:
    ///      The negative test vector for "wrong nftId" uses hardcoded 0, which equals $.nft,
    ///      so verification passes (correctly per bitmask) but the Call is marked false.
    ///      This is only a test-vector issue in the library, not a security bug.
    function testFluidLibrary_NftZero_KnownEdgeCase() external {
        MockFluidVault fluidVault = new MockFluidVault(address(wstETH), address(usdc));

        FluidLibrary.Info memory info = FluidLibrary.Info({
            curator: curator,
            subvault: subvault,
            subvaultName: "TestSubvault",
            fluidVault: address(fluidVault),
            nft: 0
        });

        Call[][] memory calls = FluidLibrary.getFluidCalls(info);

        // The operate group (index 2) has a "wrong nft" call at sub-index 5
        // that uses nft=0 which matches $.nft=0, so it actually passes verification.
        // This documents the edge case.
        Call memory operateWrongNft = calls[2][5];
        assertEq(operateWrongNft.verificationResult, false, "Library marks it false");
        // But the actual bitmask verification would return true since 0 == 0
    }

    // ──────────────────── ResolvLibrary ────────────────────

    function testResolvLibrary_CallsVerification() external {
        MockToken usr = new MockToken("USR", "USR", 18);
        MockERC4626Token wstUSR = new MockERC4626Token("Wrapped stUSR", "wstUSR", 18, address(usr));
        address usrManager = makeAddr("usrManager");

        ResolvLibrary.Info memory info = ResolvLibrary.Info({
            asset: address(wstETH),
            usrRequestManager: usrManager,
            usr: address(usr),
            wstUSR: address(wstUSR),
            subvault: subvault,
            subvaultName: "TestSubvault",
            curator: curator
        });

        IVerifier.VerificationPayload[] memory proofs = ResolvLibrary.getResolvProofs(bitmaskVerifier, info);
        Call[][] memory calls = ResolvLibrary.getResolvCalls(info);

        assertEq(proofs.length, calls.length, "Resolv: proofs/calls length mismatch");
        assertGt(proofs.length, 0, "Resolv: no proofs generated");

        // Expected: 2 ERC20 approves + 5 USR manager ops + 5 ERC4626 wstUSR ops = 12
        assertEq(proofs.length, 12, "Resolv: expected 12 proofs");

        _assertMixedResults(calls, "Resolv");
        _verifyCallGroups(proofs, calls);
    }
}
