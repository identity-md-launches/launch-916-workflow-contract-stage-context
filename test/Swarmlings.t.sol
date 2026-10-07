// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Swarmlings} from "../src/Swarmlings.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {DN404} from "dn404/src/DN404.sol";
import {ReentrancyGuard} from "../src/ReentrancyGuard.sol";

contract RendererMock {
    function tokenURI(uint256) external pure returns (string memory) {
        return 'data:application/json,{"name":"Exact mock renderer response"}';
    }
}

contract RevertingRendererMock {
    function tokenURI(uint256) external pure returns (string memory) {
        revert("no art");
    }
}

contract WritingRendererMock {
    uint256 public writes;

    function tokenURI(uint256) external returns (string memory) {
        ++writes;
        return "must never be returned through STATICCALL";
    }
}

contract ClaimReceiver {
    Swarmlings public token;
    bool public reject;
    bool public attack;
    bytes4 public reentryError;

    constructor(Swarmlings token_) {
        token = token_;
    }

    function enable() external {
        token.setSkipNFT(false);
    }

    function configure(bool reject_, bool attack_) external {
        reject = reject_;
        attack = attack_;
    }

    function claim(uint256[] memory ids) external {
        token.claim(ids);
    }

    receive() external payable {
        require(!reject, "reject ETH");
        if (attack) {
            (bool ok, bytes memory reason) = address(token).call(abi.encodeCall(token.claim, (new uint256[](0))));
            require(!ok, "reentered");
            reentryError = bytes4(reason);
        }
    }
}

contract NFTReceiver {
    Swarmlings public token;
    uint256 public pendingDuringCallback;

    constructor(Swarmlings token_) {
        token = token_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        pendingDuringCallback = token.pending(address(this), ids);
        token.claim(ids);
        return this.onERC721Received.selector;
    }
    receive() external payable {}
}

contract SwarmlingsTest is Test {
    Swarmlings token;
    DN404Mirror mirror;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    uint256 constant UNIT = 300_000e18;

    function setUp() public {
        token = new Swarmlings();
        mirror = DN404Mirror(payable(token.mirrorERC721()));
        vm.deal(address(this), 100 ether);
    }

    function ids(address who) internal view returns (uint256[] memory) {
        return token.ownedIds(who, 0, 3333);
    }

    function claimAll(address who) internal {
        uint256[] memory all = ids(who);
        vm.prank(who);
        token.claim(all);
    }

    function test_supplyPairAndStandardTransfers() public {
        assertEq(token.name(), "Swarmlings");
        assertEq(token.symbol(), "LING");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(mirror.baseERC20(), address(token));
        assertEq(mirror.owner(), address(0));
        mirror.pullOwner();
        assertEq(mirror.owner(), address(0));
        assertEq(token.activeNFTs(), 0);
        assertTrue(token.getSkipNFT(address(this)));
        token.transfer(alice, UNIT + 100);
        assertEq(token.balanceOf(alice), UNIT + 100);
        assertEq(token.balanceOf(address(this)), 1e27 - UNIT - 100);
        assertEq(mirror.balanceOf(alice), 1);
        assertEq(mirror.totalSupply(), 1);
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        token.transferFrom(alice, bob, 100);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), 100);
        vm.prank(bob);
        vm.expectRevert(DN404.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, 0x000000000022D473030F116dDEE9F6B43aC78BA3), 0);
    }

    function test_noAdminMintOrSeizeEvenForDeployer() public {
        string[9] memory methods = [
            "mint(address,uint256)",
            "burnFrom(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "freeze(address)",
            "seize(address,uint256)"
        ];
        for (uint256 i; i < methods.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(methods[i], alice, 1));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_contractWalletOptInAndOptOut() public {
        ClaimReceiver receiver = new ClaimReceiver(token);
        token.transfer(address(receiver), 2 * UNIT);
        assertEq(mirror.balanceOf(address(receiver)), 0);
        receiver.enable();
        assertEq(mirror.balanceOf(address(receiver)), 2);
        vm.prank(address(receiver));
        token.setSkipNFT(true);
        token.transfer(address(receiver), UNIT);
        assertEq(mirror.balanceOf(address(receiver)), 2);
        receiver.enable();
        assertEq(mirror.balanceOf(address(receiver)), 3);
    }

    function test_maxCollectionAndFinalFraction() public {
        token.transfer(alice, 1e27);
        assertEq(token.activeNFTs(), 3333);
        assertEq(mirror.balanceOf(alice), 3333);
        vm.prank(alice);
        token.transfer(bob, 100_000e18);
        assertEq(mirror.balanceOf(bob), 0);
        assertEq(token.activeNFTs(), 3333);
        uint256[] memory all = ids(alice);
        assertEq(all.length, 3333);
        for (uint256 i; i < all.length; ++i) {
            assertEq(all[i], i + 1);
        }
    }

    function test_rewardsSurviveNFTTransferAndLaterBuyerStartsAtCurrentAcc() public {
        token.transfer(alice, UNIT);
        token.notifyReward{value: 1 ether}();
        uint256 id = ids(alice)[0];
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);
        assertEq(token.owed(alice), 1 ether);
        assertEq(token.pending(bob, ids(bob)), 0);
        assertEq(token.rewardDebt(id), token.accRewardPerNFT());
        token.notifyReward{value: 2 ether}();
        assertEq(token.pending(bob, ids(bob)), 2 ether);
        vm.prank(alice);
        token.claim(new uint256[](0));
        claimAll(bob);
        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 2 ether);
        assertEq(address(token).balance, 0);
    }

    function test_erc20DirectNFTTransferSettlesOldOwner() public {
        token.transfer(alice, UNIT);
        uint256 id = ids(alice)[0];
        token.notifyReward{value: 1 ether}();
        vm.prank(alice);
        token.transfer(bob, UNIT);
        assertEq(mirror.ownerOf(id), bob);
        assertEq(token.owed(alice), 1 ether);
        assertEq(token.pending(bob, ids(bob)), 0);
        assertEq(token.activeNFTs(), 1);
    }

    function test_sellBelowUnitBurnsButKeepsEarnedRewards() public {
        token.transfer(alice, UNIT);
        token.notifyReward{value: 1 ether}();
        vm.prank(alice);
        token.transfer(address(this), 1);
        assertEq(token.activeNFTs(), 0);
        assertEq(token.owed(alice), 1 ether);
        token.notifyReward{value: 2 ether}();
        assertEq(token.owed(token.TREASURY()), 2 ether);
        assertEq(token.TREASURY().balance, 0);
        token.transfer(alice, 1);
        assertEq(token.pending(alice, ids(alice)), 1 ether);
        claimAll(alice);
        vm.prank(token.TREASURY());
        token.claim(new uint256[](0));
        assertEq(alice.balance, 1 ether);
        assertEq(token.TREASURY().balance, 2 ether);
    }

    function test_mintAfterRewardAndDuplicateClaimIds() public {
        token.transfer(alice, UNIT);
        token.notifyReward{value: 1 ether}();
        token.transfer(bob, UNIT);
        assertEq(token.pending(bob, ids(bob)), 0);
        token.notifyReward{value: 2 ether}();
        uint256[] memory duplicated = new uint256[](3);
        duplicated[0] = duplicated[1] = duplicated[2] = ids(alice)[0];
        assertEq(token.pending(alice, duplicated), 2 ether);
        vm.prank(alice);
        token.claim(duplicated);
        assertEq(alice.balance, 2 ether);
        assertEq(token.pending(alice, duplicated), 0);
        vm.prank(alice);
        token.claim(duplicated);
        assertEq(alice.balance, 2 ether);
    }

    function test_invalidIdsAndPagination() public {
        token.transfer(alice, 3 * UNIT);
        uint256[] memory page = token.ownedIds(alice, 1, type(uint256).max);
        assertEq(page.length, 2);
        assertEq(page[0], 2);
        assertEq(token.ownedIds(alice, 10, 20).length, 0);
        assertEq(token.ownedIds(alice, 3, 1).length, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Swarmlings.NotNFTOwner.selector, 2));
        token.claim(page);
        vm.expectRevert(abi.encodeWithSelector(Swarmlings.NotNFTOwner.selector, 2));
        token.pending(bob, page);
        page[0] = type(uint256).max;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Swarmlings.NotNFTOwner.selector, type(uint256).max));
        token.claim(page);
    }

    function test_claimRejectingETHRollsBackAndReentrancyFails() public {
        ClaimReceiver receiver = new ClaimReceiver(token);
        receiver.enable();
        token.transfer(address(receiver), UNIT);
        token.notifyReward{value: 1 ether}();
        receiver.configure(true, false);
        uint256[] memory all = ids(address(receiver));
        vm.expectRevert(Swarmlings.ETHTransferFailed.selector);
        receiver.claim(all);
        assertEq(token.pending(address(receiver), ids(address(receiver))), 1 ether);
        receiver.configure(false, true);
        receiver.claim(ids(address(receiver)));
        assertEq(receiver.reentryError(), ReentrancyGuard.ReentrantCall.selector);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(address(token).balance, 0);
    }

    function test_safeTransferReceiverCannotClaimPriorRewards() public {
        token.transfer(alice, UNIT);
        token.notifyReward{value: 1 ether}();
        NFTReceiver receiver = new NFTReceiver(token);
        vm.prank(alice);
        mirror.safeTransferFrom(alice, address(receiver), 1);
        assertEq(receiver.pendingDuringCallback(), 0);
        assertEq(token.owed(alice), 1 ether);
    }

    function test_fractionalRewardsStayWithTheirWallet() public {
        token.transfer(alice, UNIT);
        token.transfer(bob, UNIT);
        token.notifyReward{value: 1}();
        claimAll(alice);
        assertEq(token.rewardRemainder(alice), 5e35);
        vm.prank(alice);
        token.transfer(address(this), 1);
        token.transfer(alice, 1);
        token.notifyReward{value: 1}();
        claimAll(alice);
        assertEq(alice.balance, 1);
        claimAll(bob);
        assertEq(bob.balance, 1);
        assertEq(address(token).balance, 0);
    }

    function test_reusedBurnedIdCannotTakeHistoricalRewards() public {
        token.transfer(alice, 1e27);
        token.notifyReward{value: 3333}();
        uint256 id = ids(alice)[3332];
        vm.prank(alice);
        token.transfer(address(this), UNIT);
        assertEq(token.owed(alice), 1);
        token.notifyReward{value: 3332}();
        token.transfer(bob, UNIT);
        assertEq(ids(bob)[0], id);
        assertEq(token.rewardDebt(id), token.accRewardPerNFT());
        assertEq(token.pending(bob, ids(bob)), 0);
        assertEq(token.pending(alice, ids(alice)), 6665);
    }

    function test_rendererDelegationAndFallback() public {
        token.transfer(alice, UNIT);
        string memory fallbackURI = mirror.tokenURI(1);
        assertEq(fallbackURI, 'data:application/json,{"name":"Swarmling","description":"Renderer unavailable"}');
        RendererMock renderer = new RendererMock();
        vm.etch(token.RENDERER(), address(renderer).code);
        assertEq(mirror.tokenURI(1), renderer.tokenURI(1));
        RevertingRendererMock bad = new RevertingRendererMock();
        vm.etch(token.RENDERER(), address(bad).code);
        assertEq(mirror.tokenURI(1), fallbackURI);
        WritingRendererMock writing = new WritingRendererMock();
        vm.etch(token.RENDERER(), address(writing).code);
        assertEq(mirror.tokenURI{gas: 1_000_000}(1), fallbackURI);
        assertEq(WritingRendererMock(token.RENDERER()).writes(), 0);
        token.notifyReward{value: 1 ether}();
        vm.prank(alice);
        token.transfer(bob, UNIT);
        assertEq(token.owed(alice), 1 ether);
        vm.expectRevert(DN404.TokenDoesNotExist.selector);
        mirror.tokenURI(0);
    }

    function testFuzz_rewardConservationAcrossTransfer(uint96 reward, uint8 count) public {
        uint256 n = bound(count, 1, 20);
        uint256 amount = bound(reward, 1, 10 ether);
        token.transfer(alice, n * UNIT);
        token.notifyReward{value: amount}();
        uint256 expected = (amount * 1e36 / n) * n / 1e36;
        vm.prank(alice);
        token.transfer(bob, n * UNIT);
        assertEq(token.owed(alice), expected);
        assertEq(token.pending(bob, ids(bob)), 0);
        vm.prank(alice);
        token.claim(new uint256[](0));
        assertEq(alice.balance + address(token).balance, amount);
        assertLe(address(token).balance, 1);
        assertEq(token.totalSupply(), 1e27);
    }

    receive() external payable {}
}
