// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "../Imports.sol";
import "./BaseIntegrationTest.sol";

import "../../scripts/common/protocols/AaveLibrary.sol";
import "../../scripts/common/protocols/ERC4626Library.sol";

/// @title CuratorUSDCBase
/// @notice Shared base for integration tests that exercise curator deposit/withdraw
///         into real DeFi protocols via Mellow Subvault + ICallModule.
/// @dev Forks Ethereum mainnet. Deploys fresh Mellow infrastructure. Creates vault
///      with USDC, queues, oracle, and a subvault configured for the target protocol.
abstract contract CuratorUSDCBase is BaseIntegrationTest {
    // ── Mainnet constants ──
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant USDC_AMOUNT = 10_000e6; // 10,000 USDC

    // ── State ──
    Deployment internal $;
    Vault internal vault;
    Oracle internal oracle;
    Subvault internal subvault;

    /// @dev Fork mainnet, deploy full Mellow infrastructure, create vault + subvault.
    ///      Subclass must call `_initSubvault(proofs)` to finish setup.
    function _baseSetUp() internal {
        string memory rpc = vm.envOr("RPC_URL", string("https://mainnet.infura.io/v3/f52bd8e7578c435c978ab9cf68cd3a18"));
        vm.createSelectFork(rpc);

        $ = deployBase();

        IOracle.SecurityParams memory securityParams = IOracle.SecurityParams({
            maxAbsoluteDeviation: 0.01 ether,
            suspiciousAbsoluteDeviation: 0.005 ether,
            maxRelativeDeviationD18: 0.01 ether,
            suspiciousRelativeDeviationD18: 0.005 ether,
            timeout: 20 hours,
            depositInterval: 1 hours,
            redeemInterval: 14 days
        });

        address[] memory assets = new address[](1);
        assets[0] = USDC;

        Vault vaultImpl = Vault(payable($.vaultFactory.implementationAt(0)));
        Oracle oracleImpl = Oracle($.oracleFactory.implementationAt(0));
        RiskManager riskImpl = RiskManager($.riskManagerFactory.implementationAt(0));

        Vault.RoleHolder[] memory roleHolders = new Vault.RoleHolder[](10);
        uint256 idx = 0;
        roleHolders[idx++] = Vault.RoleHolder(vaultImpl.CREATE_QUEUE_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(oracleImpl.SUBMIT_REPORTS_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(oracleImpl.ACCEPT_REPORT_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(vaultImpl.CREATE_SUBVAULT_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(Verifier($.verifierFactory.implementationAt(0)).CALLER_ROLE(), $.curator);
        roleHolders[idx++] = Vault.RoleHolder(riskImpl.SET_SUBVAULT_LIMIT_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(riskImpl.ALLOW_SUBVAULT_ASSETS_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(vaultImpl.PUSH_LIQUIDITY_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(vaultImpl.PULL_LIQUIDITY_ROLE(), $.vaultAdmin);
        roleHolders[idx++] = Vault.RoleHolder(riskImpl.SET_VAULT_LIMIT_ROLE(), $.vaultAdmin);
        assembly { mstore(roleHolders, idx) }

        address oracleAddr;
        address vaultAddr;
        (,,, oracleAddr, vaultAddr) = $.vaultConfigurator.create(
            VaultConfigurator.InitParams({
                version: 0,
                proxyAdmin: $.vaultProxyAdmin,
                vaultAdmin: $.vaultAdmin,
                shareManagerVersion: 0,
                shareManagerParams: abi.encode(bytes32(0), string("TestVault"), string("TV")),
                feeManagerVersion: 0,
                feeManagerParams: abi.encode($.vaultAdmin, $.protocolTreasury, uint24(0), uint24(0), uint24(0), uint24(0)),
                riskManagerVersion: 0,
                riskManagerParams: abi.encode(int256(1_000_000e18)), // large vault limit
                oracleVersion: 0,
                oracleParams: abi.encode(securityParams, assets),
                defaultDepositHook: address(new RedirectingDepositHook()),
                defaultRedeemHook: address(new BasicRedeemHook()),
                queueLimit: 16,
                roleHolders: roleHolders
            })
        );
        vault = Vault(payable(vaultAddr));
        oracle = Oracle(oracleAddr);

        // Create deposit + redeem queues, submit initial oracle report
        vm.startPrank($.vaultAdmin);
        vault.createQueue(0, true, $.vaultProxyAdmin, USDC, new bytes(0));
        vault.createQueue(0, false, $.vaultProxyAdmin, USDC, new bytes(0));
        {
            IOracle.Report[] memory reports = new IOracle.Report[](1);
            // USDC price = 1e18 (1 USD)
            reports[0] = IOracle.Report({asset: USDC, priceD18: 1e18});
            oracle.submitReports(reports);
            oracle.acceptReport(USDC, 1e18, uint32(block.timestamp));
        }
        vm.stopPrank();
    }

    /// @dev Creates a subvault with the given verification payloads, configures risk limits.
    ///      Returns the verification payloads with merkle proofs populated.
    function _initSubvault(IVerifier.VerificationPayload[] memory leaves)
        internal
        returns (IVerifier.VerificationPayload[] memory proofs)
    {
        bytes32 merkleRoot;
        (merkleRoot, proofs) = generateMerkleProofs(leaves);

        vm.startPrank($.vaultAdmin);

        Verifier verifier = Verifier(
            $.verifierFactory.create(0, $.vaultProxyAdmin, abi.encode(address(vault), merkleRoot))
        );
        address subvaultAddr = vault.createSubvault(0, $.vaultProxyAdmin, address(verifier));
        subvault = Subvault(payable(subvaultAddr));

        address[] memory allowedAssets = new address[](1);
        allowedAssets[0] = USDC;
        vault.riskManager().setSubvaultLimit(subvaultAddr, int256(1_000_000e18));
        vault.riskManager().allowSubvaultAssets(subvaultAddr, allowedAssets);

        vm.stopPrank();

        // Deal USDC directly to the subvault (simulates assets pushed from vault)
        deal(USDC, subvaultAddr, USDC_AMOUNT);
    }
}
