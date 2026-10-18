// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterHive} from "src/HamsterHive.sol";

/// @dev Keeps CREATE2 deployment and the first distribution in one transaction.
contract HamsterHiveDeploymentProbe {
    function launch(bytes32 salt, address recipient, uint256 amount) external returns (HamsterHive token) {
        token = new HamsterHive{salt: salt}();
        require(token.balanceOf(address(this)) == 1_000_000_000 ether, "constructor recipient");
        require(token.transfer(recipient, amount), "initial distribution");
    }
}

/// @notice Edge cases and properties supplementing the original token tests.
/// forge-config: default.fuzz.runs = 1000
contract HamsterHivePropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    HamsterHive internal token;
    address internal deployer = makeAddr("properties.deployer");
    address internal alice = makeAddr("properties.alice");
    address internal bob = makeAddr("properties.bob");
    address internal spender = makeAddr("properties.spender");

    function setUp() public {
        vm.prank(deployer);
        token = new HamsterHive();
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(alice);
        HamsterHive deployed = new HamsterHive();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(deployed.balanceOf(alice), SUPPLY);
        assertEq(deployed.balanceOf(address(0)), 0);
    }

    function testFuzz_create2MintsToFactoryAndCanDistributeImmediately(bytes32 salt, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        HamsterHiveDeploymentProbe factory = new HamsterHiveDeploymentProbe();
        // The constructor recipient must be the factory, independently of tx.origin.
        vm.prank(alice, alice);
        HamsterHive deployed = factory.launch(salt, bob, amount);
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(deployed.balanceOf(bob), amount);
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_oneWeiRoundTripIsExact() public {
        _transfer(deployer, alice, 1);
        _transfer(alice, bob, 1);
        _transfer(bob, deployer, 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransfersFromEmptyAccountEmitAndDoNotChangeState() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        _transfer(alice, bob, 0);

        // A zero delegated transfer needs no positive allowance or balance.
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroReceiverRejectedEvenForZeroAmount() public {
        bytes memory error = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        vm.prank(alice);
        vm.expectRevert(error);
        token.transfer(address(0), 0);
        vm.prank(spender);
        vm.expectRevert(error);
        token.transferFrom(alice, address(0), 0);
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_zeroSourceCannotMintThroughTransferFrom() public {
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(0), bob, 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(0), bob, 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_selfTransferStillRequiresSufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(alice, 1);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(deployer, SUPPLY + 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_maximumTransferAmountsRevertWithoutOverflowOrAllowanceLoss() public {
        _approve(deployer, spender, type(uint256).max);
        bytes memory error =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(error);
        token.transfer(alice, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(error);
        token.transferFrom(deployer, alice, type(uint256).max);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_largestFiniteAllowanceIsDecremented() public {
        _approve(deployer, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_finiteAllowanceExhaustionCannotBeReused() public {
        _approve(deployer, spender, 3);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 2));
        assertEq(token.allowance(deployer, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, bob, 1);
        _assertBalances(SUPPLY - 3, 1, 2);
    }

    function test_infiniteApprovalCanBeRevokedAfterSpending() public {
        _approve(deployer, spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        _approve(deployer, spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_allowanceBelongsToOneOwnerAndOneSpender() public {
        _transfer(deployer, alice, 20);
        _approve(deployer, spender, 7);
        _approve(alice, bob, 11);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, spender, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), 7);
        assertEq(token.allowance(alice, bob), 11);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.allowance(deployer, bob), 0);
        _assertBalances(SUPPLY - 20, 20, 0);
    }

    function test_transferFromByOwnerRequiresSelfApproval() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        _approve(deployer, deployer, 1);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, deployer), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_fullSupplyCanMoveByTransferFromAndReturn() public {
        _approve(deployer, spender, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, alice, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(0, SUPPLY, 0);
        _transfer(alice, deployer, SUPPLY);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_approvalOverwritesAndRepeatedApprovalIsIdempotent(uint256 first, uint256 replacement) public {
        _approve(alice, spender, first);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(alice, spender, replacement);
        _approve(alice, spender, replacement);
        assertEq(token.allowance(alice, spender), replacement);
        _approve(alice, spender, replacement);
        assertEq(token.allowance(alice, spender), replacement);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_approveZeroSpenderIsAtomic(uint256 amount) public {
        _approve(alice, spender, amount);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        assertEq(token.allowance(alice, address(0)), 0);
        assertEq(token.allowance(alice, spender), amount);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_insufficientBalanceRestoresFiniteAllowance(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max - 1);
        _transfer(deployer, alice, balance);
        _approve(alice, spender, amount);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), amount);
        _assertBalances(SUPPLY - balance, balance, 0);
    }

    function testFuzz_insufficientAllowanceIsAtomic(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, SUPPLY);
        _approve(deployer, spender, allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(deployer, alice, amount);
        assertEq(token.allowance(deployer, spender), allowed);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_zeroReceiverRestoresAllowance(uint256 amount, bool infinite) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 allowed = infinite ? type(uint256).max : amount;
        _approve(deployer, spender, allowed);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), amount);
        assertEq(token.allowance(deployer, spender), allowed);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_delegatedSelfTransferOnlyConsumesFiniteAllowance(uint256 amount, bool infinite) public {
        amount = bound(amount, 0, SUPPLY);
        _approve(deployer, spender, infinite ? type(uint256).max : amount);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, deployer, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, amount));
        assertEq(token.allowance(deployer, spender), infinite ? type(uint256).max : 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_infiniteApprovalSurvivesRepeatedSpending(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        _approve(deployer, spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, first));
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, second));
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        _assertBalances(SUPPLY - first - second, first, second);
    }

    function testFuzz_transferRoundTripPreservesBalancesAndApprovals(uint256 amount, uint256 allowed) public {
        amount = bound(amount, 0, SUPPLY);
        _approve(deployer, spender, allowed);
        _transfer(deployer, alice, amount);
        _transfer(alice, deployer, amount);
        assertEq(token.allowance(deployer, spender), allowed);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_splitDelegatedTransferEqualsWholeTransfer(uint256 amount, uint256 first) public {
        amount = bound(amount, 0, SUPPLY);
        first = bound(first, 0, amount);
        vm.prank(deployer);
        HamsterHive whole = new HamsterHive();
        vm.prank(deployer);
        assertTrue(whole.approve(spender, amount));
        vm.prank(spender);
        assertTrue(whole.transferFrom(deployer, alice, amount));

        _approve(deployer, spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, first));
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount - first));

        assertEq(token.balanceOf(deployer), whole.balanceOf(deployer));
        assertEq(token.balanceOf(alice), whole.balanceOf(alice));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(whole.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - amount, amount, 0);
    }

    function _approve(address owner, address operator, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(operator, amount));
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function _assertBalances(uint256 deployerBalance, uint256 aliceBalance, uint256 bobBalance) internal view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), deployerBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(deployerBalance + aliceBalance + bobBalance, SUPPLY);
    }
}
