// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Sharewood Forest — claim-link gifts for ERC20 tokens (e.g. stock tokens)
/// @notice A sender locks tokens behind a one-time "claim key". The claim link carries
///         the private half of that key; the contract stores only its address.
///         To claim, the recipient's app signs (gift, recipient) with the claim key,
///         so a copied transaction can't be redirected to someone else's wallet.
///         Unclaimed gifts can be refunded to the sender after expiry.
contract SharewoodGifts is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Gift {
        address sender;
        address token;
        uint96 expiresAt;
        address claimKey; // address of the one-time key embedded in the link
        uint128 amount; // amount the recipient receives
        bool settled; // claimed or refunded
    }

    uint16 public constant MAX_FEE_BPS = 500; // hard cap: 5%
    uint32 public constant MIN_DURATION = 1 days;
    uint32 public constant MAX_DURATION = 365 days;

    uint16 public feeBps; // fee charged on top of the gift amount
    address public treasury;
    bool public allowlistEnabled = true;
    mapping(address => bool) public allowedToken;

    Gift[] internal _gifts;

    event GiftCreated(uint256 indexed id, address indexed sender, address indexed token, uint256 amount, uint256 fee, uint256 expiresAt);
    event GiftClaimed(uint256 indexed id, address indexed recipient);
    event GiftRefunded(uint256 indexed id, address indexed sender);
    event FeeUpdated(uint16 feeBps);
    event TreasuryUpdated(address treasury);
    event TokenAllowed(address indexed token, bool allowed);
    event AllowlistToggled(bool enabled);

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh();
    error TokenNotAllowed();
    error BadDuration();
    error UnsupportedToken();
    error AlreadySettled();
    error Expired();
    error NotExpired();
    error NotSender();
    error BadSignature();
    error UnknownGift();

    constructor(address owner_, address treasury_, uint16 feeBps_) Ownable(owner_) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // ---------------------------------------------------------------- gifting

    /// @notice Lock `amount` of `token` for whoever holds the claim key.
    ///         Caller must approve amount + fee first (see quote()).
    function createGift(address token, uint128 amount, address claimKey, uint32 duration)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 id)
    {
        if (amount == 0) revert ZeroAmount();
        if (claimKey == address(0) || token == address(0)) revert ZeroAddress();
        if (allowlistEnabled && !allowedToken[token]) revert TokenNotAllowed();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();

        uint256 fee = (uint256(amount) * feeBps) / 10_000;

        // Pull the gift and verify the exact amount arrived (rejects fee-on-transfer tokens).
        IERC20 t = IERC20(token);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        if (t.balanceOf(address(this)) - before != amount) revert UnsupportedToken();
        if (fee > 0) t.safeTransferFrom(msg.sender, treasury, fee);

        id = _gifts.length;
        uint96 expiresAt = uint96(block.timestamp + duration);
        _gifts.push(Gift(msg.sender, token, expiresAt, claimKey, amount, false));
        emit GiftCreated(id, msg.sender, token, amount, fee, expiresAt);
    }

    /// @notice Claim a gift to `recipient`. `sig` is the claim key's signature over claimDigest().
    ///         Anyone may submit it (e.g. a relayer paying gas for a new user).
    function claim(uint256 id, address recipient, bytes calldata sig) external nonReentrant {
        Gift storage g = _gift(id);
        if (g.settled) revert AlreadySettled();
        if (block.timestamp >= g.expiresAt) revert Expired();
        if (recipient == address(0)) revert ZeroAddress();

        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(claimDigest(id, recipient)), sig);
        if (signer != g.claimKey) revert BadSignature();

        g.settled = true;
        IERC20(g.token).safeTransfer(recipient, g.amount);
        emit GiftClaimed(id, recipient);
    }

    /// @notice Sender takes back an unclaimed gift after it expires. The fee is not refunded.
    function refund(uint256 id) external nonReentrant {
        Gift storage g = _gift(id);
        if (msg.sender != g.sender) revert NotSender();
        if (g.settled) revert AlreadySettled();
        if (block.timestamp < g.expiresAt) revert NotExpired();

        g.settled = true;
        IERC20(g.token).safeTransfer(g.sender, g.amount);
        emit GiftRefunded(id, g.sender);
    }

    // ------------------------------------------------------------------ views

    function claimDigest(uint256 id, address recipient) public view returns (bytes32) {
        return keccak256(abi.encode("SharewoodGift", block.chainid, address(this), id, recipient));
    }

    function quote(uint128 amount) external view returns (uint256 fee, uint256 total) {
        fee = (uint256(amount) * feeBps) / 10_000;
        total = amount + fee;
    }

    function getGift(uint256 id) external view returns (Gift memory) {
        return _gift(id);
    }

    function giftCount() external view returns (uint256) {
        return _gifts.length;
    }

    // ------------------------------------------------------------------ admin

    function setFee(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        allowedToken[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setAllowlistEnabled(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
        emit AllowlistToggled(enabled);
    }

    /// @notice Pausing blocks new gifts only. Claims and refunds always work,
    ///         so the owner can never trap users' funds.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _gift(uint256 id) internal view returns (Gift storage) {
        if (id >= _gifts.length) revert UnknownGift();
        return _gifts[id];
    }
}
