// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterHive} from "src/HamsterHive.sol";

/// @notice Drives a closed set of holders through successful and rejected calls.
/// @dev Ghost accounting is initialized from the requested supply, never from token getters.
/// Receipts and payments record successful calls; rejected calls cannot update either ledger.
contract HamsterHiveHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 5;
    HamsterHive public immutable token;
    address[5] public actors;
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;
    mapping(address => mapping(address => uint256)) public remainingAllowance;
    uint256 public valueMovingCalls;
    uint256 public rejectedCalls;

    constructor(HamsterHive token_, address[5] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function expectedBalance(address holder) public view returns (uint256) {
        uint256 initial = holder == actors[0] ? SUPPLY : 0;
        return initial + received[holder] - sent[holder];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _bound(amount, 0, expectedBalance(from)));
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), expectedBalance(from));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), infinite ? type(uint256).max : _bound(amount, 0, SUPPLY));
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = _bound(amount, 0, _available(owner, spender));
        _transferFrom(owner, spender, _actor(toSeed), amount);
    }

    /// @dev Complements the valid-input handler: no amount bound, and no silent catch of failures.
    function transferFromUnbounded(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = remainingAllowance[owner][spender];
        uint256 balance = expectedBalance(owner);
        if (amount > allowed) {
            _reject(
                spender,
                abi.encodeCall(token.transferFrom, (owner, to, amount)),
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        } else if (amount > balance) {
            _reject(
                spender,
                abi.encodeCall(token.transferFrom, (owner, to, amount)),
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
        } else {
            _transferFrom(owner, spender, to, amount);
        }
    }

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance(from);
        amount = _bound(amount, balance + 1, type(uint256).max);
        _reject(
            from,
            abi.encodeCall(token.transfer, (_actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
        );
    }

    /// @dev A sufficient approval makes the call reach the balance check. Its allowance debit
    /// must roll back on rejection, including when the spender, owner and recipient alias.
    function transferFromOverBalance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amount,
        bool infinite
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance(owner);
        amount = _bound(amount, balance + 1, type(uint256).max - 1);
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        _reject(
            spender,
            abi.encodeCall(token.transferFrom, (owner, _actor(toSeed), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
    }

    function transferToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = _bound(amount, 0, delegated ? _available(owner, spender) : expectedBalance(owner));
        bytes memory data = delegated
            ? abi.encodeCall(token.transferFrom, (owner, address(0), amount))
            : abi.encodeCall(token.transfer, (address(0), amount));
        _reject(
            delegated ? spender : owner,
            data,
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _available(address owner, address spender) internal view returns (uint256) {
        uint256 balance = expectedBalance(owner);
        uint256 allowed = remainingAllowance[owner][spender];
        return balance < allowed ? balance : allowed;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval returned false");
        remainingAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount, "approval not applied exactly");
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer returned false");
        _recordTransfer(from, to, amount);
    }

    function _transferFrom(address owner, address spender, address to, uint256 amount) internal {
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "valid delegated transfer returned false");
        if (remainingAllowance[owner][spender] != type(uint256).max) {
            remainingAllowance[owner][spender] -= amount;
        }
        assertEq(token.allowance(owner, spender), remainingAllowance[owner][spender], "incorrect allowance debit");
        _recordTransfer(owner, to, amount);
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        sent[from] += amount;
        received[to] += amount;
        if (from != to && amount > 0) ++valueMovingCalls;
        assertEq(token.balanceOf(from), expectedBalance(from), "sender did not pay the exact amount");
        assertEq(token.balanceOf(to), expectedBalance(to), "recipient did not receive the exact amount");
    }

    function _reject(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool ok, bytes memory result) = address(token).call(data);
        assertFalse(ok, "invalid operation succeeded");
        assertEq(result, expectedError, "unexpected failure reason");
        ++rejectedCalls;
    }
}

/// @notice Random call sequences must conserve fixed supply and preserve authorization boundaries.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterHiveInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    HamsterHive internal token;
    HamsterHiveHandler internal handler;
    address[5] internal actors;

    function setUp() public {
        actors = [
            makeAddr("invariant.deployer"),
            makeAddr("invariant.alice"),
            makeAddr("invariant.bob"),
            makeAddr("invariant.carol"),
            makeAddr("invariant.dave")
        ];
        vm.prank(actors[0]);
        token = new HamsterHive();
        handler = new HamsterHiveHandler(token, actors);

        // Only these wrappers may mutate the token, so every reachable holder is accounted for.
        // Successful calls propagate reverts; invalid calls check exact revert data explicitly.
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.revoke.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.transferFromUnbounded.selector;
        selectors[6] = handler.transferOverBalance.selector;
        selectors[7] = handler.transferFromOverBalance.selector;
        selectors[8] = handler.transferToZero.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesMatchLedgerAndConserveFixedSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]), "balance disagrees with transfer history");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "tokens were lost or created");
        assertEq(token.totalSupply(), SUPPLY, "supply changed after construction");
        assertEq(token.balanceOf(address(0)), 0, "zero address received tokens");
        assertEq(token.balanceOf(address(token)), 0, "unexpected token fee");
        assertEq(token.balanceOf(address(handler)), 0, "unexpected handler balance");
        assertEq(token.name(), "Hamster Hive");
        assertEq(token.symbol(), "HAMSTER");
        assertEq(token.decimals(), 18);
    }

    function invariant_allowancesMatchOnlyTheOwnersAuthorizations() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.allowance(actors[i], address(0)), 0);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.remainingAllowance(actors[i], actors[j]),
                    "approval leaked, was not revoked, or was debited incorrectly"
                );
            }
        }
    }

    /// @dev At the end of every sequence, all holders must still be able to move their entire
    /// balance. This checks liveness as well as the accounting safety properties above.
    function afterInvariant() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transferAll(i, 0);
            assertEq(token.balanceOf(actors[i]), 0);
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        invariant_balancesMatchLedgerAndConserveFixedSupply();
        invariant_allowancesMatchOnlyTheOwnersAuthorizations();
    }

    /// @dev Pins nonzero transfers, self-transfer, allowance consumption, revocation and rejection
    /// in one sequence, independently of which actions the randomized campaign happens to choose.
    function test_mixedSequenceExercisesSuccessAndAtomicFailures() public {
        handler.transfer(0, 1, 100);
        handler.approve(1, 2, 60, false);
        handler.transferFrom(1, 2, 3, 40);
        handler.transferFrom(1, 2, 1, 10);
        handler.transferToZero(1, 2, 5, true);
        handler.transferFromUnbounded(1, 2, 4, 11);
        handler.transferFromOverBalance(1, 2, 4, 61, false);
        handler.revoke(1, 2);
        handler.transferFromUnbounded(1, 2, 4, 1);
        handler.transferOverBalance(3, 4, type(uint256).max);
        handler.approve(3, 4, 0, true);
        handler.transferFrom(3, 4, 2, 40);

        assertEq(token.balanceOf(actors[1]), 60);
        assertEq(token.balanceOf(actors[2]), 40);
        assertEq(token.balanceOf(actors[3]), 0);
        assertEq(token.allowance(actors[1], actors[2]), 0);
        assertEq(token.allowance(actors[3], actors[4]), type(uint256).max);
        assertEq(handler.rejectedCalls(), 5);
        assertEq(handler.valueMovingCalls(), 3);
        invariant_balancesMatchLedgerAndConserveFixedSupply();
        invariant_allowancesMatchOnlyTheOwnersAuthorizations();
        afterInvariant();
    }
}
