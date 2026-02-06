// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

/// @title SparkLibrary
/// @notice Thin wrapper around AaveLibrary for SparkLend (Aave V3 fork).
///         SparkLend uses the identical IAavePoolV3 interface, so AaveLibrary
///         can be reused directly. This library exists for naming clarity
///         when configuring Spark-specific subvault strategies.
///
/// Usage:
///   AaveLibrary.Info memory sparkInfo = AaveLibrary.Info({
///       subvault: subvault,
///       subvaultName: "SparkSubvault",
///       curator: curator,
///       aaveInstance: SPARK_POOL,       // 0xC13e21B648A5Ee794902342038FF3aDAB66BE987
///       aaveInstanceName: "SparkLend",
///       collaterals: collaterals,
///       loans: loans,
///       categoryId: 0
///   });
///   AaveLibrary.getAaveProofs(bitmaskVerifier, sparkInfo);
///   AaveLibrary.getAaveCalls(sparkInfo);

import "./AaveLibrary.sol";

library SparkLibrary {
    using ParameterLibrary for ParameterLibrary.Parameter[];

    /// @dev Alias: generates proofs for Spark using AaveLibrary (identical interface).
    function getSparkProofs(BitmaskVerifier bitmaskVerifier, AaveLibrary.Info memory $)
        internal
        pure
        returns (IVerifier.VerificationPayload[] memory)
    {
        return AaveLibrary.getAaveProofs(bitmaskVerifier, $);
    }

    /// @dev Alias: generates descriptions for Spark using AaveLibrary.
    function getSparkDescriptions(AaveLibrary.Info memory $) internal view returns (string[] memory) {
        return AaveLibrary.getAaveDescriptions($);
    }

    /// @dev Alias: generates test call vectors for Spark using AaveLibrary.
    function getSparkCalls(AaveLibrary.Info memory $) internal pure returns (Call[][] memory) {
        return AaveLibrary.getAaveCalls($);
    }
}
