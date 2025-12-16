// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDT - Test USDT token for AuctionSave demo
/// @notice Simple ERC20 with public faucet function for testing
/// @dev Anyone can mint up to 10,000 tokens per call (faucet)
contract MockUSDT is ERC20 {
    uint8 private constant DECIMALS = 18;
    uint256 public constant FAUCET_AMOUNT = 10_000 * 10 ** DECIMALS; // 10,000 USDT per faucet call
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    mapping(address => uint256) public lastFaucetTime;

    event FaucetUsed(address indexed user, uint256 amount);

    constructor() ERC20("Mock USDT", "mUSDT") {
        // Mint initial supply to deployer for liquidity
        _mint(msg.sender, 1_000_000 * 10 ** DECIMALS);
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Get free test tokens (faucet)
    /// @dev Anyone can call this to get 10,000 mUSDT, with 1 hour cooldown
    function faucet() external {
        require(block.timestamp >= lastFaucetTime[msg.sender] + FAUCET_COOLDOWN, "Faucet: cooldown not passed");

        lastFaucetTime[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);

        emit FaucetUsed(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Check remaining cooldown time for an address
    function faucetCooldownRemaining(address user) external view returns (uint256) {
        uint256 nextAvailable = lastFaucetTime[user] + FAUCET_COOLDOWN;
        if (block.timestamp >= nextAvailable) {
            return 0;
        }
        return nextAvailable - block.timestamp;
    }

    /// @notice Mint tokens to any address (for admin/testing)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
