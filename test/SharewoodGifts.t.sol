// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SharewoodGifts} from "../src/SharewoodGifts.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Stock", "mSTK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) { super._update(from, address(0xdead), v / 100); v -= v / 100; }
        super._update(from, to, v);
    }
}

contract SharewoodGiftsTest is Test {
    SharewoodGifts gifts;
    MockToken token;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");
    uint256 claimPk = 0xC1A1;
    address claimKey;

    function setUp() public {
        gifts = new SharewoodGifts(owner, treasury, 200); // 2%
        token = new MockToken();
        vm.prank(owner);
        gifts.setTokenAllowed(address(token), true);
        claimKey = vm.addr(claimPk);
        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(gifts), type(uint256).max);
    }

    function _create(uint128 amt) internal returns (uint256) {
        vm.prank(alice);
        return gifts.createGift(address(token), amt, claimKey, 30 days);
    }

    function _sign(uint256 pk, uint256 id, address to) internal view returns (bytes memory) {
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(gifts.claimDigest(id, to));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        return abi.encodePacked(r, s, v);
    }

    function test_CreateChargesFeeOnTop() public {
        _create(100e18);
        assertEq(token.balanceOf(address(gifts)), 100e18);
        assertEq(token.balanceOf(treasury), 2e18);
        assertEq(token.balanceOf(alice), 898e18);
        (uint256 fee, uint256 total) = gifts.quote(100e18);
        assertEq(fee, 2e18);
        assertEq(total, 102e18);
    }

    function test_ClaimFullAmount() public {
        uint256 id = _create(100e18);
        gifts.claim(id, bob, _sign(claimPk, id, bob));
        assertEq(token.balanceOf(bob), 100e18);
        assertTrue(gifts.getGift(id).settled);
    }

    function test_RelayerCanSubmitClaim() public {
        uint256 id = _create(100e18);
        bytes memory sig = _sign(claimPk, id, bob);
        vm.prank(mallory); // third party pays gas, funds still go to bob
        gifts.claim(id, bob, sig);
        assertEq(token.balanceOf(bob), 100e18);
    }

    function test_FrontRunCannotRedirect() public {
        uint256 id = _create(100e18);
        bytes memory sigForBob = _sign(claimPk, id, bob);
        vm.expectRevert(SharewoodGifts.BadSignature.selector);
        gifts.claim(id, mallory, sigForBob);
    }

    function test_WrongKeyRejected() public {
        uint256 id = _create(100e18);
        bytes memory sig = _sign(0xBAD, id, bob);
        vm.expectRevert(SharewoodGifts.BadSignature.selector);
        gifts.claim(id, bob, sig);
    }

    function test_SignatureNotReusableAcrossGifts() public {
        uint256 id0 = _create(10e18);
        uint256 id1 = _create(10e18);
        bytes memory sig0 = _sign(claimPk, id0, bob);
        vm.expectRevert(SharewoodGifts.BadSignature.selector);
        gifts.claim(id1, bob, sig0);
    }

    function test_NoDoubleClaim() public {
        uint256 id = _create(100e18);
        bytes memory sig = _sign(claimPk, id, bob);
        gifts.claim(id, bob, sig);
        vm.expectRevert(SharewoodGifts.AlreadySettled.selector);
        gifts.claim(id, bob, sig);
    }

    function test_CannotClaimAfterExpiry() public {
        uint256 id = _create(100e18);
        bytes memory sig = _sign(claimPk, id, bob);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(SharewoodGifts.Expired.selector);
        gifts.claim(id, bob, sig);
    }

    function test_RefundAfterExpiry() public {
        uint256 id = _create(100e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        gifts.refund(id);
        assertEq(token.balanceOf(alice), 998e18); // fee kept
    }

    function test_NoEarlyRefund() public {
        uint256 id = _create(100e18);
        vm.prank(alice);
        vm.expectRevert(SharewoodGifts.NotExpired.selector);
        gifts.refund(id);
    }

    function test_OnlySenderRefunds() public {
        uint256 id = _create(100e18);
        vm.warp(block.timestamp + 30 days);
        vm.prank(mallory);
        vm.expectRevert(SharewoodGifts.NotSender.selector);
        gifts.refund(id);
    }

    function test_NoRefundAfterClaim() public {
        uint256 id = _create(100e18);
        gifts.claim(id, bob, _sign(claimPk, id, bob));
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        vm.expectRevert(SharewoodGifts.AlreadySettled.selector);
        gifts.refund(id);
    }

    function test_AllowlistBlocksUnknownToken() public {
        MockToken other = new MockToken();
        other.mint(alice, 10e18);
        vm.startPrank(alice);
        other.approve(address(gifts), type(uint256).max);
        vm.expectRevert(SharewoodGifts.TokenNotAllowed.selector);
        gifts.createGift(address(other), 1e18, claimKey, 30 days);
        vm.stopPrank();
    }

    function test_RejectsFeeOnTransferToken() public {
        FeeOnTransferToken tax = new FeeOnTransferToken();
        vm.prank(owner);
        gifts.setTokenAllowed(address(tax), true);
        tax.mint(alice, 100e18);
        vm.startPrank(alice);
        tax.approve(address(gifts), type(uint256).max);
        vm.expectRevert(SharewoodGifts.UnsupportedToken.selector);
        gifts.createGift(address(tax), 10e18, claimKey, 30 days);
        vm.stopPrank();
    }

    function test_PauseBlocksCreateButNotClaimOrRefund() public {
        uint256 id = _create(100e18);
        uint256 id2 = _create(50e18);
        vm.prank(owner);
        gifts.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gifts.createGift(address(token), 1e18, claimKey, 30 days);
        gifts.claim(id, bob, _sign(claimPk, id, bob));
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        gifts.refund(id2);
    }

    function test_FeeCapEnforced() public {
        vm.prank(owner);
        vm.expectRevert(SharewoodGifts.FeeTooHigh.selector);
        gifts.setFee(501);
    }

    function test_OnlyOwnerAdmin() public {
        vm.prank(mallory);
        vm.expectRevert();
        gifts.setFee(100);
        vm.prank(mallory);
        vm.expectRevert();
        gifts.setTreasury(mallory);
    }

    function test_DurationBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(SharewoodGifts.BadDuration.selector);
        gifts.createGift(address(token), 1e18, claimKey, 1 hours);
        vm.expectRevert(SharewoodGifts.BadDuration.selector);
        gifts.createGift(address(token), 1e18, claimKey, 400 days);
        vm.stopPrank();
    }

    function testFuzz_FeeMath(uint128 amt) public {
        amt = uint128(bound(amt, 1, 500e18));
        uint256 id = _create(amt);
        assertEq(token.balanceOf(treasury), (uint256(amt) * 200) / 10_000);
        gifts.claim(id, bob, _sign(claimPk, id, bob));
        assertEq(token.balanceOf(bob), amt);
        assertEq(token.balanceOf(address(gifts)), 0);
    }
}
