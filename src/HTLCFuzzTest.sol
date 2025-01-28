// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../src/HTLC.sol";
import "@crytic/properties/contracts/util/Hevm.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MockERC20 is ERC20 {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract TestHTLC {
    using ECDSA for bytes32;

    HTLC public htlc;
    MockERC20 public immutable token;

    /** @dev used to avoid duplicate orders by the contract */
    uint256 public randomizer = 0;

    constructor() {
        token = new MockERC20("Token", "TKN");
        htlc = new HTLC(address(token), "HTLC", "1");

        token.mint(address(this), 1000 * 10e18);
    }

    /**
     * @dev Internal function to initiate an order for testing called in other test functions
     * @notice Modified `HTLC.sol` contract to store the last orderID in a public variable for testing
     * @return  orderID  bytes32 orderID of the initiated order
     */
    // function initiate() internal returns (bytes32) {
    //     address redeemer = address(0x123);
    //     uint256 timelock = 100;
    //     uint256 amount = 100;
    //     bytes32 secretHash = sha256(abi.encodePacked("secret", randomizer));
    //     randomizer += 1;

    //     token.approve(address(htlc), amount);
    //     htlc.initiate(redeemer, timelock, amount, secretHash);
    //     return htlc.currentOrderID();
    // }

    /**
     * @dev Tests the `HTLC.sol::initiate()` and `HTLC.sol::_initiate()` function
     * @param   redeemer  public address of the redeemer
     * @param   timelock  timelock in period for the htlc order
     * @param   amount  amount of tokens to trade
     * @param   secretHash  sha256 hash of the secret used for redemption
     * @notice `HTLC.sol::initiate()` reverts if:
     * - initiator and secretHash match another order
     * - redeemer is the zero address
     * - redeemer is the contract address
     * - timelock is less than or equal to 0
     * - amount is less than or equal to 0
     * - amount is greater than the balance of the contract
     * @notice Modified `HTLC.sol` contract to store the last orderID in a public variable for testing `currentOrderID`
     */
    function test_initiate(address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public returns(bytes32) {
        bytes32 secretHashUnique = sha256(abi.encodePacked(secretHash, randomizer));
        randomizer += 1;

        require(redeemer != address(0), "Invalid redeemer address");
        require(redeemer != address(this), "Invalid redeemer address");
        require(redeemer != address(token), "Invalid redeemer address");
        require(redeemer != address(htlc), "Invalid redeemer address");
        require(timelock > 0, "Invalid timelock");
        require(amount > 0, "Invalid amount");
        require(amount <= token.balanceOf(address(this)), "Insufficient balance");

        uint256 initBalance = token.balanceOf(address(htlc));

        token.approve(address(htlc), amount);
        try htlc.initiate(redeemer, timelock, amount, secretHashUnique) {
            assert(token.balanceOf(address(htlc)) == initBalance+amount);
            assert(htlc.currentOrderID() != 0);
            return htlc.currentOrderID();
        } catch(bytes memory err) {
            assert(false);
        }
    }

    /**
     * @dev Tests the `HTLC.sol::initiateOnBehalf()` and `HTLC.sol::_initiate()` function
     * @param   initiator  public address of the initiator
     * @param   redeemer  public address of the redeemer
     * @param   timelock  timelock in period for the htlc order
     * @param   amount  amount of tokens to trade
     * @param   secretHash  sha256 hash of the secret used for redemption
     * @notice This test proves that the funder and the redeemer can be the same address
     */
    function test_initiateOnBehalf(address initiator, address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public {
        bytes32 secretHashUnique = sha256(abi.encodePacked(secretHash, randomizer));
        randomizer += 1;

        //Pre-conditions
        require(redeemer != address(0), "Invalid redeemer address");
        require(redeemer != initiator, "Invalid redeemer address");
        require(redeemer != address(token), "Invalid redeemer address");
        require(redeemer != address(htlc), "Invalid redeemer address");
        require(timelock > 0, "Invalid timelock");
        require(amount > 0, "Invalid amount");
        require(amount <= token.balanceOf(address(this)), "Insufficient balance");

        uint256 initBalance = token.balanceOf(address(htlc));

        token.approve(address(htlc), amount);
        try htlc.initiateOnBehalf(initiator, redeemer, timelock, amount, secretHashUnique) {
            // Post-conditions
            assert(token.balanceOf(address(htlc)) == initBalance+amount);
            assert(htlc.currentOrderID() != 0);
        } catch(bytes memory err) {
            assert(false);
        }
    }

    /**
     * @dev Tests the `HTLC.sol::redeem()` function
     * @notice all same params required for `test_initiate()`
     */
    function test_redeem(address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public {
        bytes32 orderID = test_initiate(redeemer, timelock, amount, secretHash);

        (bool isFulfilled,,,,,) = htlc.orders(orderID);
        uint256 initBalanceRedeemer = token.balanceOf(redeemer);

        /// @notice Assuming that the redeemer address would call the `redeem()` function themselves. 
        /// @notice There isn't a check to verify who is calling the function tho
        hevm.prank(redeemer);
        try htlc.redeem(orderID, abi.encodePacked(secretHash, randomizer-1)) {
            // Post-conditions
            (isFulfilled,,,,,) = htlc.orders(orderID);
            assert(isFulfilled == true);
            assert(token.balanceOf(redeemer) == amount + initBalanceRedeemer);
        } catch(bytes memory err) {
            assert(false);
        }
    }
    
    /**
     * @dev Tests the `HTLC.sol::redeem()` function after timelock period
     * @notice all same params required for `test_initiate()`
     * @notice Runs successfully even after the timelock period has expired
     */
    function test_redeem_after_timelock(address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public {
        bytes32 orderID = test_initiate(redeemer, timelock, amount, secretHash);

        (bool isFulfilled,,,uint256 initiatedAt,,) = htlc.orders(orderID);
        uint256 initBalanceRedeemer = token.balanceOf(redeemer);

        hevm.prank(redeemer);
        hevm.roll(initiatedAt+timelock+1);
        try htlc.redeem(orderID, abi.encodePacked(secretHash, randomizer-1)) {
            // Post-conditions
            (isFulfilled,,,,,) = htlc.orders(orderID);
            assert(isFulfilled == true);
            assert(token.balanceOf(redeemer) == amount + initBalanceRedeemer);
        } catch(bytes memory err) {
            assert(false);
        }
    }

    /**
     * @dev Tests the `HTLC.sol::refund()` function after timelock period (normal case)
     * @notice all same params required for `test_initiate()`
     */
    function test_refund(address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public {
        bytes32 orderID = test_initiate(redeemer, timelock, amount, secretHash);

        (bool isFulfilled, address initiator,, uint256 initiatedAt,,) = htlc.orders(orderID);
        uint256 initBalanceInitiator = token.balanceOf(initiator);
        
        hevm.prank(initiator);
        hevm.roll(initiatedAt+timelock+1);
        try htlc.refund(orderID) {
            assert(token.balanceOf(initiator) == initBalanceInitiator+amount);
            (isFulfilled,,,,,) = htlc.orders(orderID);
            assert(isFulfilled == true);
        } catch (bytes memory err) {
            assert(false);
        }
    }

    /**
     * @dev Tests the `HTLC.sol::refund()` function after order is fulfilled
     * @notice all same params required for `test_initiate()`
     */
    function test_refund_fail_isFulfilled(address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public {
        bytes32 orderID = test_initiate(redeemer, timelock, amount, secretHash);

        (, address initiator,, uint256 initiatedAt,,) = htlc.orders(orderID);
        
        hevm.prank(redeemer);
        htlc.redeem(orderID, abi.encodePacked(secretHash, randomizer-1));
        
        hevm.prank(initiator);
        hevm.roll(initiatedAt+timelock+1);
        try htlc.refund(orderID) {
            assert(false);
        } catch (bytes memory err) {
            assert(true);
        }
    }
    
    /**
     * @dev Tests the `HTLC.sol::refund()` function before timelock period
     * @notice all same params required for `test_initiate()`
     */
    function test_refund_fail_not_expired(address redeemer, uint256 timelock, uint256 amount, bytes32 secretHash) public {
        bytes32 orderID = test_initiate(redeemer, timelock, amount, secretHash);
        (, address initiator,, uint256 initiatedAt,,) = htlc.orders(orderID);
        
        hevm.prank(initiator);
        hevm.roll(initiatedAt+timelock);
        try htlc.refund(orderID) {
            assert(false);
        } catch (bytes memory err) {
            assert(true);
        }
    }
}