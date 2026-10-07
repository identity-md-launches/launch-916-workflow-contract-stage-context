// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404} from "dn404/src/DN404.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {IRenderer} from "./interfaces/IRenderer.sol";
import {IRewardReceiver} from "./interfaces/IRewardReceiver.sol";

/// @title Swarmlings (LING)
/// @notice Immutable DN404: 300,000 LING per NFT, with equal ETH rewards per active NFT.
/// Traits are cosmetic, fixed per id and rendered fully onchain by the fixed renderer.
/// Contract wallets skip automatic NFTs by default; setSkipNFT(false) opts in.
/// No administrator can mint LING, freeze balances, seize assets or change this contract.
contract Swarmlings is DN404, ReentrancyGuard, IRewardReceiver {
    uint256 public constant UNIT = 300_000e18;
    uint256 public constant MAX_NFTS = 3333;
    uint256 public constant REWARD_SCALE = 1e36;
    address public constant RENDERER = 0x07C6380C3Aab0208c7cDd76791530c4d2A2d389F;
    /// @notice Requester's wallet; only receives rewards notified while no NFTs exist.
    address public constant TREASURY = 0x92cEf4823119f3332A85A39023eEbA01a06890c4;

    uint256 public accRewardPerNFT;
    mapping(uint256 id => uint256 accumulator) public rewardDebt;
    mapping(address account => uint256 weiAmount) public owed;
    /// @notice Fractions remain with the wallet that earned them, including after a burn.
    mapping(address account => uint256 scaledFraction) public rewardRemainder;

    error NotNFTOwner(uint256 id);
    error ETHTransferFailed();
    error UnexpectedETH();

    event RewardNotified(address indexed sender, uint256 amount, uint256 activeNFTs);
    event RewardClaimed(address indexed account, uint256 amount);

    constructor() {
        _initializeDN404(1e27, msg.sender, address(new DN404Mirror(msg.sender)));
    }

    /// @dev Must run before dn404Fallback, whose served selectors return from assembly.
    modifier noETH() {
        if (msg.value != 0) revert UnexpectedETH();
        _;
    }

    /// @dev Mirror dispatch remains available without value. Donations use notifyReward.
    fallback() external payable override noETH dn404Fallback {
        revert FnSelectorNotRecognized();
    }

    function name() public pure override returns (string memory) {
        return "Swarmlings";
    }

    function symbol() public pure override returns (string memory) {
        return "LING";
    }

    function _unit() internal pure override returns (uint256) {
        return UNIT;
    }

    /// @dev All spenders, including Permit2, require the holder's explicit ERC20 approval.
    function _givePermit2DefaultInfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @notice Opting in materializes NFTs supported by the caller's current balance.
    /// Opting out affects future ERC20 receipts; it does not burn existing NFTs.
    function setSkipNFT(bool skipNFT) public override returns (bool) {
        _setSkipNFT(msg.sender, skipNFT);
        if (!skipNFT) _transfer(msg.sender, msg.sender, 0);
        return true;
    }

    function activeNFTs() public view returns (uint256) {
        return _totalNFTSupply();
    }

    /// @notice Anyone can donate. Ownership at notification time determines entitlement.
    /// No ETH is pushed to holders or to TREASURY here.
    function notifyReward() external payable {
        uint256 active = activeNFTs();
        if (active == 0) {
            owed[TREASURY] += msg.value;
        } else {
            accRewardPerNFT += msg.value * REWARD_SCALE / active;
        }
        emit RewardNotified(msg.sender, msg.value, active);
    }

    /// @notice Settle caller-owned IDs and withdraw all the caller's owed ETH.
    /// Empty ids withdraw previously settled rewards, including rewards from burned NFTs.
    /// Duplicate ids are harmless. Rejected ETH payments revert the entire settlement.
    function claim(uint256[] calldata ids) external nonReentrant {
        uint256 acc = accRewardPerNFT;
        for (uint256 i; i < ids.length; ++i) {
            _checkOwner(msg.sender, ids[i]);
            _settle(msg.sender, ids[i], acc);
        }
        uint256 amount = owed[msg.sender];
        owed[msg.sender] = 0;
        if (amount != 0) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        }
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice Wei claimable from owed plus these currently owned IDs, counted once each.
    /// Reverts for an unowned or nonexistent ID, just as claim does.
    function pending(address account, uint256[] calldata ids) external view returns (uint256) {
        uint256 scaled = rewardRemainder[account];
        uint256[14] memory seen;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            _checkOwner(account, id);
            uint256 word = id >> 8;
            uint256 mask = uint256(1) << (id & 255);
            if ((seen[word] & mask) != 0) continue;
            seen[word] |= mask;
            scaled += accRewardPerNFT - rewardDebt[id];
        }
        return owed[account] + scaled / REWARD_SCALE;
    }

    /// @notice Paginate the owner's current ID array using [begin, end) indices.
    /// End is clamped to the balance; reversed/out-of-range pages are empty.
    function ownedIds(address account, uint256 begin, uint256 end) external view returns (uint256[] memory) {
        return _ownedIds(account, begin, end);
    }

    function _checkOwner(address account, uint256 id) private view {
        if (id == 0 || id > MAX_NFTS || account == address(0) || _ownerAt(id) != account) {
            revert NotNFTOwner(id);
        }
    }

    function _settle(address account, uint256 id, uint256 acc) private {
        uint256 scaled = acc - rewardDebt[id] + rewardRemainder[account];
        owed[account] += scaled / REWARD_SCALE;
        rewardRemainder[account] = scaled % REWARD_SCALE;
        rewardDebt[id] = acc;
    }

    function _useAfterNFTTransfers() internal pure override returns (bool) {
        return true;
    }

    /// @dev DN404 provides the PREVIOUS owners after its internal state change. The immutable
    /// mirror only logs events before this hook; no user callback can intervene. Settle the
    /// old owner's entitlement before control can leave the transfer, including on burns.
    function _afterNFTTransfers(address[] memory from, address[] memory, uint256[] memory ids) internal override {
        uint256 acc = accRewardPerNFT;
        for (uint256 i; i < ids.length; ++i) {
            if (from[i] != address(0)) _settle(from[i], ids[i], acc);
            rewardDebt[ids[i]] = acc;
        }
    }

    /// @dev The view interface compiles to STATICCALL. Rendering is isolated from accounting.
    function _tokenURI(uint256 id) internal view override returns (string memory) {
        if (RENDERER.code.length != 0) {
            try IRenderer(RENDERER).tokenURI(id) returns (string memory uri) {
                return uri;
            } catch {}
        }
        return 'data:application/json,{"name":"Swarmling","description":"Renderer unavailable"}';
    }
}
