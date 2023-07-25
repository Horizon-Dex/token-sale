// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PublicSaleOverflowAudited is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotAllowed();
    error NotStartedOrAlreadyEnded();
    error AlreadyStarted();
    error NotFinished();
    error AlreadyFinished();
    error CommitOutOfRange();
    error InsufficientCommitment();
    error MaxReached();
    error HasClaimed();
    error InvalidParam();
    error EthTransferFailed();

    IERC20 public immutable salesToken;
    uint256 public immutable tokensToSell;
    uint256 public immutable ethersToRaise;
    uint256 public immutable refundThreshold;
    uint256 public startTime;
    uint256 public claimStartTime;
    address public immutable burnAddress;

    uint256 public constant MIN_COMMITMENT = 0.02 ether;
    uint256 public constant MAX_COMMITMENT = 1000 ether;

    bool public started;
    bool public finished;

    uint256 public totalCommitments;
    mapping(address => uint256) public commitments;
    mapping(address => bool) public userClaimed;

    event Commit(address indexed buyer, uint256 amount);
    event ClaimTokens(address indexed buyer, uint256 token);
    event ClaimETH(address indexed buyer, uint256 token);

    constructor(
        IERC20 _salesToken,
        uint256 _tokensToSell,
        uint256 _ethersToRaise,
        uint256 _refundThreshold,
        address _burnAddress
    ) {
        if (_ethersToRaise == 0) revert InvalidParam();
        if (_ethersToRaise < _refundThreshold) revert InvalidParam();
        if (MIN_COMMITMENT >= MAX_COMMITMENT) revert InvalidParam();

        salesToken = _salesToken;
        tokensToSell = _tokensToSell;
        ethersToRaise = _ethersToRaise;
        refundThreshold = _refundThreshold;
        burnAddress = _burnAddress;
    }

    function setTime(
        uint256 _startTime,
        uint256 _claimStartTime
    ) external onlyOwner {
        if (_startTime <= block.timestamp) revert InvalidParam();
        if (_claimStartTime <= _startTime) revert InvalidParam();
        if (started == true) revert AlreadyStarted();

        startTime = _startTime;
        claimStartTime = _claimStartTime;
    }

    function start() external onlyOwner {
        if (started) revert AlreadyStarted();
        started = true;

        salesToken.safeTransferFrom(msg.sender, address(this), tokensToSell);
    }

    function commit() external payable nonReentrant {
        if (
            !started ||
            block.timestamp <= startTime ||
            block.timestamp > claimStartTime
        ) revert NotStartedOrAlreadyEnded();

        if (
            MIN_COMMITMENT > commitments[msg.sender] + msg.value ||
            commitments[msg.sender] + msg.value > MAX_COMMITMENT
        ) revert CommitOutOfRange();

        commitments[msg.sender] += msg.value;
        totalCommitments += msg.value;
        emit Commit(msg.sender, msg.value);
    }

    function _simulateClaim(
        address account
    ) internal view returns (uint256, uint256) {
        if (commitments[account] == 0) return (0, 0);
        if (totalCommitments >= refundThreshold) {
            uint256 ethersToSpend = Math.min(
                commitments[account],
                (commitments[account] * ethersToRaise) / totalCommitments
            );
            uint256 ethersToRefund = commitments[account] - ethersToSpend;
            ethersToRefund = (ethersToRefund / 10) * 10;
            uint256 tokensToReceive = (tokensToSell * ethersToSpend) /
                ethersToRaise;
            return (ethersToRefund, tokensToReceive);
        } else {
            return (commitments[msg.sender], 0);
        }
    }

    function simulateClaimExternal(
        address account
    ) external view returns (uint256, uint256) {
        (uint ethersToRefund, uint tokensToReceive) = _simulateClaim(account);
        return (ethersToRefund, tokensToReceive);
    }

    function claim() external nonReentrant returns (uint256, uint256) {
        if (block.timestamp < claimStartTime) revert NotStartedOrAlreadyEnded();

        if (commitments[msg.sender] == 0) revert InsufficientCommitment();

        if (userClaimed[msg.sender] == true) revert HasClaimed();

        userClaimed[msg.sender] = true;
        (uint256 ethersToRefund, uint256 tokensToReceive) = _simulateClaim(
            msg.sender
        );
        if (totalCommitments >= refundThreshold) {
            salesToken.safeTransfer(msg.sender, tokensToReceive);

            emit ClaimTokens(msg.sender, tokensToReceive);

            if (ethersToRefund > 0) {
                (bool success, ) = msg.sender.call{value: ethersToRefund}("");
                require(success, "Failed to transfer ether");
            }

            emit ClaimETH(msg.sender, ethersToRefund);
            return (ethersToRefund, tokensToReceive);
        } else {
            uint256 amt = commitments[msg.sender];
            commitments[msg.sender] = 0;
            (bool success, ) = msg.sender.call{value: amt}("");
            require(success, "Failed to transfer ether");
            emit ClaimETH(msg.sender, amt);
            return (amt, 0);
        }
    }

    function finish() external onlyOwner returns (uint, uint) {
        if (block.timestamp < claimStartTime) revert NotFinished();

        if (finished) revert AlreadyFinished();

        finished = true;

        if (totalCommitments >= refundThreshold) {
            (bool success, ) = payable(owner()).call{
                value: Math.min(ethersToRaise, totalCommitments)
            }("");
            require(success, "Failed to transfer ether");
            if (ethersToRaise > totalCommitments) {
                uint256 tokensToBurn = (tokensToSell *
                    (ethersToRaise - totalCommitments)) / ethersToRaise;
                salesToken.safeTransfer(burnAddress, tokensToBurn);
                return (
                    Math.min(ethersToRaise, totalCommitments),
                    tokensToBurn
                );
            }
        } else {
            salesToken.safeTransfer(owner(), tokensToSell);
            return (0, tokensToSell);
        }
    }
}
