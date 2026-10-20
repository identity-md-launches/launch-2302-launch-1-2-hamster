// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of HamsterHour v2 (0xe33ab493249a2df0d8c4a71ac54f46d1f7778367) the vault reads
/// and calls. Source: github.com/identity-md-launches/launch-2260-build-hamster-hour-v2.
interface IHamsterHour {
    /// @notice Net binary principal lost by `account` in window `k`; zero until settled, zero after a timeout.
    function lossOf(uint256 k, address account) external view returns (uint256);
    /// @notice Pool-level eligible loss of window `k`, written at finalization. Sum of lossOf never exceeds it.
    function totalEligibleLoss(uint256 k) external view returns (uint256);
    function cumulativeLossBefore(uint256 k) external view returns (uint256);
    function cumulativeLossAfter(uint256 k) external view returns (uint256);
    /// @notice Every window below this index has been finalized (loss history written).
    function nextFinalizeWindow() external view returns (uint256);
    function cumulativeLoss() external view returns (uint256);
    /// @notice Pull balance of a recipient (the staking recipient, once set).
    function balances(address account) external view returns (uint256);
    function stakingRecipient() external view returns (address);
    function pendingStakingFees() external view returns (uint256);
    /// @notice Pays the caller's pull balance in IMD. Reverts NothingToClaim when zero.
    function withdraw() external;
}
