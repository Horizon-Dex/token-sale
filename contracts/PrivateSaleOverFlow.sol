// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract PrivateSaleOverflow is Ownable, ReentrancyGuard {
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
    error HasRefunded();
    error InvalidParam();
    error EthTransferFailed();
    error NotOverflow();

    IERC20 public immutable salesToken;
    uint256 public immutable tokensToSell;
    uint256 public immutable ethersToRaise;
    uint256 public immutable refundThreshold;
    bytes32 private immutable _merkleRootAllowlist;
    uint256 public startTime;
    uint256 public claimEndTime;
    uint256 public refundEndTime;

    address public immutable burnAddress;

    uint256 public constant MIN_COMMITMENT = 0.02 ether;
    uint256 public constant MAX_COMMITMENT = 10 ether;

    bool public started;
    bool public finished;

    uint256 public totalCommitments;
    mapping(address => uint256) public commitments;
    mapping(address => bool) public userClaimed;
    mapping(address => bool) public userRefunded;

    event Commit(address indexed buyer, uint256 amount);
    event ClaimTokens(address indexed buyer, uint256 token);
    event ClaimETH(address indexed buyer, uint256 token);

    //test
    constructor(
        IERC20 _salesToken,
        uint256 _tokensToSell,
        uint256 _ethersToRaise,
        uint256 _refundThreshold,
        address _burnAddress,
        bytes32 _root
    ) {
        if (_ethersToRaise == 0) revert InvalidParam();
        if (_ethersToRaise < _refundThreshold) revert InvalidParam();
        if (MIN_COMMITMENT >= MAX_COMMITMENT) revert InvalidParam();

        salesToken = _salesToken;
        tokensToSell = _tokensToSell;
        ethersToRaise = _ethersToRaise;
        refundThreshold = _refundThreshold;
        burnAddress = _burnAddress;
        _merkleRootAllowlist = _root;
    }

    function setTime(
        uint256 _startTime,
        uint256 _refundEndTime,
        uint256 _claimEndTime
    ) external onlyOwner {
        if (_startTime < block.timestamp) revert InvalidParam();
        if (_refundEndTime < _startTime) revert InvalidParam();
        if (_claimEndTime < _refundEndTime) revert InvalidParam();

        startTime = _startTime;
        refundEndTime = _refundEndTime;
        claimEndTime = _claimEndTime;
    }

    function start() external onlyOwner {
        if (started) revert AlreadyStarted();
        started = true;

        salesToken.safeTransferFrom(msg.sender, address(this), tokensToSell);
    }


    function commit(
        bytes32[] calldata _merkleProof
    ) external payable nonReentrant {
        bytes32 leaf = keccak256(abi.encodePacked(_msgSender()));
        if (
            !MerkleProof.verifyCalldata(
                _merkleProof,
                _merkleRootAllowlist,
                leaf
            )
        ) revert NotAllowed();
        if (
            !started ||
            block.timestamp <= startTime ||
            block.timestamp > refundEndTime
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
	        // ethersToRefund = (ethersToRefund / 10) * 10; //@audit either add this round down or handle hardcoded withdraw value in finish() in case of precision loss happening here
            uint256 tokensToReceive = (tokensToSell * ethersToSpend) /
                ethersToRaise;

            return (ethersToRefund, tokensToReceive);
        } else {
            uint256 amt = commitments[msg.sender];
            return (amt, 0);
        }
    }

    function simulateClaimExternal(
        address account
    ) external view returns (uint256, uint256) {
        (uint ethersToRefund, uint tokensToReceive) = _simulateClaim(account);
        return (ethersToRefund, tokensToReceive);
    }

    function claim() external nonReentrant returns (uint256) {
        if (block.timestamp < claimEndTime) revert NotStartedOrAlreadyEnded();

        if (commitments[msg.sender] == 0) revert InsufficientCommitment();

        if (userClaimed[msg.sender] == true) revert HasClaimed();
        userClaimed[msg.sender] = true; //@audit-info commitment not zeroed.if zeroed, if zeroed it will block refund after refundTime has reached.

        if (totalCommitments >= refundThreshold) {
            (, uint tokensToReceive) = _simulateClaim(msg.sender);

            salesToken.safeTransfer(msg.sender, tokensToReceive);

            emit ClaimTokens(msg.sender, tokensToReceive);

            return (tokensToReceive);
        } else {
            uint256 amt = commitments[msg.sender];
            commitments[msg.sender] = 0;
            userRefunded[msg.sender] = true;
            (bool success, ) = msg.sender.call{value: amt}("");
            require(success, "Failed to transfer ether");
            emit ClaimETH(msg.sender, amt);
            return (amt);
        }
    }

    function overflowRefund() external nonReentrant returns (uint256) {
        if (block.timestamp < refundEndTime) revert NotStartedOrAlreadyEnded();
        if (userRefunded[msg.sender] == true) revert HasRefunded();
        if (commitments[msg.sender] == 0) revert InsufficientCommitment();
        if (totalCommitments < ethersToRaise) revert NotOverflow();

        userRefunded[msg.sender] = true;

        (uint256 ethToRefund, ) = _simulateClaim(msg.sender);

        if (ethToRefund > 0) {
            (bool success, ) = msg.sender.call{value: ethToRefund}("");
            require(success, "Failed to transfer ether");
            emit ClaimETH(msg.sender, ethToRefund);
            return (ethToRefund);
        }
        return (0);
    }

    function finish() external onlyOwner returns (uint, uint) {
        if (block.timestamp < refundEndTime) revert NotFinished();


        if (finished) revert AlreadyFinished();

        finished = true;

        if (totalCommitments >= refundThreshold) {
            if (ethersToRaise >= totalCommitments) {
                //underflow
                uint256 tokensToBurn = (tokensToSell *
                    (ethersToRaise - totalCommitments)) / ethersToRaise;
                salesToken.safeTransfer(burnAddress, tokensToBurn);
                (bool success, ) = owner().call{value: totalCommitments}(""); //@audit assumption: there is no risk of precision loss for underflow condition and we can use hardcoded values in call
                if (!success) revert EthTransferFailed();
                return (totalCommitments, tokensToBurn);
            } else {
                //overflow
                if (address(this).balance > ethersToRaise) {
                    //@audit-info if no precision loss in overflowRefund(), we can hardcode ethersToRaise in call
                    (bool success2, ) = owner().call{value: ethersToRaise}("");
                    if (!success2) revert EthTransferFailed();
                    return (ethersToRaise, 0);
                } else {
                    //@audit-info if there is  precision loss, withdraw all balance
                    (bool success3, ) = owner().call{
                        value: address(this).balance
                    }("");
                    if (!success3) revert EthTransferFailed();
                    return (address(this).balance, 0);
                }
            }
        } else {
            // if refundThreshold not reached, owner gets no eth. Tokens are sent back.
            salesToken.safeTransfer(owner(), tokensToSell);
            return (0, tokensToSell);
        }
    }

    receive() external payable {}
}
