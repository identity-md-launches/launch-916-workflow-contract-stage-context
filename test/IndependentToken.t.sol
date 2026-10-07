// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Swarmlings} from "src/Swarmlings.sol";
import {ReentrancyGuard} from "src/ReentrancyGuard.sol";
import {DN404} from "dn404/src/DN404.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {SwarmMerkleFixture} from "./helpers/SwarmMerkleFixture.sol";

contract CrossFunctionClaimReceiver {
    Swarmlings immutable token;
    address immutable nextOwner;
    bytes4 public blockedError;
    bool public reject;

    constructor(Swarmlings t, address next) {
        token = t;
        nextOwner = next;
        t.setSkipNFT(false);
    }

    function setReject(bool value) external {
        reject = value;
    }

    function claim() external {
        token.claim(token.ownedIds(address(this), 0, 3333));
    }

    receive() external payable {
        require(!reject, "reject");
        // Change ownership and notify while the outer claim is paying out.
        token.transfer(nextOwner, token.balanceOf(address(this)));
        token.notifyReward{value: msg.value / 2}();
        (bool ok, bytes memory reason) = address(token).call(abi.encodeCall(token.claim, (new uint256[](0))));
        require(!ok, "claim reentered");
        blockedError = bytes4(reason);
    }
}

contract IndependentTokenTest is Test {
    uint256 constant UNIT = 300_000e18;
    Swarmlings token;
    DN404Mirror mirror;
    address alice = makeAddr("boundary holder");
    address bob = makeAddr("next holder");

    function setUp() public {
        token = new Swarmlings();
        mirror = DN404Mirror(payable(token.mirrorERC721()));
        vm.deal(address(this), 100 ether);
    }

    function test_exactDecimalBoundaryMintsAndBurnsOneNFT() public {
        token.transfer(alice, 299_999.99 ether);
        assertEq(mirror.balanceOf(alice), 0);
        token.transfer(alice, 0.01 ether);
        assertEq(token.balanceOf(alice), UNIT);
        assertEq(mirror.balanceOf(alice), 1);
        uint256 id = token.ownedIds(alice, 0, 1)[0];
        token.notifyReward{value: 1 ether}();
        vm.prank(alice);
        token.transfer(address(this), 0.01 ether);
        assertEq(token.balanceOf(alice), 299_999.99 ether);
        assertEq(mirror.balanceOf(alice), 0);
        assertEq(token.activeNFTs(), 0);
        vm.expectRevert(DN404.TokenDoesNotExist.selector);
        mirror.ownerOf(id);
        assertEq(token.owed(alice), 1 ether);
        vm.prank(alice);
        token.claim(new uint256[](0));
        assertEq(alice.balance, 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_oneWeiAcrossAnyUnitBoundary(uint16 unitSeed, uint96 shortfallSeed) public {
        uint256 units = bound(unitSeed, 1, 40);
        uint256 shortfall = bound(shortfallSeed, 1, UNIT - 1);
        token.transfer(alice, units * UNIT - shortfall);
        assertEq(mirror.balanceOf(alice), units - 1);
        token.transfer(alice, shortfall - 1);
        assertEq(mirror.balanceOf(alice), units - 1);
        token.transfer(alice, 1);
        assertEq(mirror.balanceOf(alice), units);
        vm.prank(alice);
        token.transfer(address(this), 1);
        assertEq(mirror.balanceOf(alice), units - 1);
        assertEq(token.balanceOf(alice), units * UNIT - 1);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_tenPercentSwarmMerkleAllocationAndTopUp() public {
        uint256 allocation = token.totalSupply() / 10;
        uint256 amount = 120_000 ether;
        bytes32 leaf = keccak256(abi.encode(uint256(0), alice, amount));
        bytes32 sibling = keccak256(abi.encode(uint256(1), bob, allocation - amount));
        bytes32 root =
            leaf < sibling ? keccak256(abi.encodePacked(leaf, sibling)) : keccak256(abi.encodePacked(sibling, leaf));
        SwarmMerkleFixture distributor = new SwarmMerkleFixture(token, root);
        token.transfer(address(distributor), allocation);
        assertEq(mirror.balanceOf(address(distributor)), 0);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        vm.expectRevert(SwarmMerkleFixture.InvalidProof.selector);
        distributor.claim(0, bob, amount, proof);
        vm.expectRevert(SwarmMerkleFixture.InvalidProof.selector);
        distributor.claim(0, alice, amount + 1, proof);
        assertFalse(distributor.claimed(0));
        distributor.claim(0, alice, amount, proof);
        assertEq(token.balanceOf(alice), amount);
        assertEq(mirror.balanceOf(alice), 0);
        vm.expectRevert(SwarmMerkleFixture.AlreadyClaimed.selector);
        distributor.claim(0, alice, amount, proof);
        token.transfer(alice, 179_999.99 ether);
        assertEq(mirror.balanceOf(alice), 0);
        token.transfer(alice, 0.01 ether);
        assertEq(token.balanceOf(alice), UNIT);
        assertEq(mirror.balanceOf(alice), 1);
        token.notifyReward{value: 1 ether}();
        assertEq(token.pending(alice, token.ownedIds(alice, 0, 1)), 1 ether);
        assertEq(token.pending(address(distributor), new uint256[](0)), 0);
        assertEq(address(distributor).balance, 0);
    }

    function test_codeBearingAnd7702StyleWalletsSkipUntilOptIn() public {
        address contractWallet = address(new SwarmMerkleFixture(token, bytes32(0)));
        address delegatedWallet = makeAddr("7702 authority");
        // Real EIP-7702 designator shape. We exercise DN404's code detection;
        // no Prague authorization opcode or delegated execution is assumed.
        vm.etch(delegatedWallet, abi.encodePacked(hex"ef0100", contractWallet));
        assertEq(delegatedWallet.code.length, 23);
        token.transfer(contractWallet, 2 * UNIT);
        token.transfer(delegatedWallet, 2 * UNIT);
        assertTrue(token.getSkipNFT(contractWallet));
        assertTrue(token.getSkipNFT(delegatedWallet));
        assertEq(mirror.balanceOf(contractWallet), 0);
        assertEq(mirror.balanceOf(delegatedWallet), 0);
        token.transfer(alice, UNIT);
        token.notifyReward{value: 1 ether}();
        assertEq(token.pending(contractWallet, new uint256[](0)), 0);
        assertEq(token.pending(delegatedWallet, new uint256[](0)), 0);
        vm.prank(delegatedWallet);
        token.setSkipNFT(false);
        assertEq(mirror.balanceOf(delegatedWallet), 2);
        assertEq(token.pending(delegatedWallet, token.ownedIds(delegatedWallet, 0, 2)), 0);
        vm.prank(contractWallet);
        token.setSkipNFT(false);
        assertEq(mirror.balanceOf(contractWallet), 2);
        token.notifyReward{value: 5 ether}();
        assertEq(token.pending(alice, token.ownedIds(alice, 0, 1)), 2 ether);
        assertEq(token.pending(delegatedWallet, token.ownedIds(delegatedWallet, 0, 2)), 2 ether);
    }

    function test_failedMixedOwnerClaimIsAtomic() public {
        token.transfer(alice, UNIT);
        token.transfer(bob, UNIT);
        token.notifyReward{value: 2 ether}();
        uint256[] memory ids = new uint256[](2);
        ids[0] = token.ownedIds(alice, 0, 1)[0];
        ids[1] = token.ownedIds(bob, 0, 1)[0];
        uint256 debt = token.rewardDebt(ids[0]);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Swarmlings.NotNFTOwner.selector, ids[1]));
        token.claim(ids);
        assertEq(token.rewardDebt(ids[0]), debt);
        assertEq(token.owed(alice), 0);
        assertEq(alice.balance, 0);
        assertEq(address(token).balance, 2 ether);
        assertEq(token.pending(alice, token.ownedIds(alice, 0, 1)), 1 ether);
    }

    function test_zeroActiveNotificationsCannotBeCapturedByLaterMint() public {
        token.notifyReward();
        token.notifyReward{value: 2 ether}();
        token.transfer(alice, UNIT);
        token.notifyReward{value: 1 ether}();
        assertEq(token.pending(alice, token.ownedIds(alice, 0, 1)), 1 ether);
        uint256[] memory ids = token.ownedIds(alice, 0, 1);
        vm.prank(alice);
        token.claim(ids);
        assertEq(alice.balance, 1 ether);
        assertEq(token.owed(token.TREASURY()), 2 ether);
        address treasury = token.TREASURY();
        vm.prank(treasury);
        token.claim(new uint256[](0));
        assertEq(treasury.balance, 2 ether);
        assertEq(address(token).balance, 0);
    }

    function test_claimCallbackTransferAndNewNotificationConserveRewards() public {
        CrossFunctionClaimReceiver receiver = new CrossFunctionClaimReceiver(token, bob);
        token.transfer(address(receiver), UNIT);
        token.notifyReward{value: 2 ether}();
        receiver.claim();
        assertEq(receiver.blockedError(), ReentrancyGuard.ReentrantCall.selector);
        assertEq(mirror.balanceOf(address(receiver)), 0);
        assertEq(mirror.balanceOf(bob), 1);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(token.pending(bob, token.ownedIds(bob, 0, 1)), 1 ether);
        uint256[] memory ids = token.ownedIds(bob, 0, 1);
        vm.prank(bob);
        token.claim(ids);
        assertEq(bob.balance, 1 ether);
        assertEq(address(token).balance, 0);
    }

    function test_oneRejectingHolderCannotBlockAnotherClaim() public {
        CrossFunctionClaimReceiver receiver = new CrossFunctionClaimReceiver(token, bob);
        token.transfer(address(receiver), UNIT);
        token.transfer(alice, UNIT);
        token.notifyReward{value: 2 ether}();
        receiver.setReject(true);
        vm.expectRevert(Swarmlings.ETHTransferFailed.selector);
        receiver.claim();
        uint256[] memory ids = token.ownedIds(alice, 0, 1);
        vm.prank(alice);
        token.claim(ids);
        assertEq(alice.balance, 1 ether);
        assertEq(token.pending(address(receiver), token.ownedIds(address(receiver), 0, 1)), 1 ether);
    }
}
