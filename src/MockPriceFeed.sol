// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockPriceFeed
/// @notice Lightweight mutable price source used by local tests and demo scripts.
/// @dev Prices are represented in basis points where 10_000 == $1.00.
contract MockPriceFeed {
    error InvalidChain(uint8 chainId);
    error InvalidPrice(uint256 priceBps);

    uint8 public constant CHAIN_ETHEREUM = 1;
    uint8 public constant CHAIN_BASE = 2;
    uint8 public constant CHAIN_ARBITRUM = 3;
    uint256 public constant PRICE_SCALE_BPS = 10_000;
    uint256 public constant MAX_PRICE_BPS = 20_000;

    mapping(uint8 => uint256) private _prices;

    event PriceUpdated(uint8 indexed chainId, uint256 oldPriceBps, uint256 newPriceBps);

    constructor() {
        _prices[CHAIN_ETHEREUM] = PRICE_SCALE_BPS;
        _prices[CHAIN_BASE] = PRICE_SCALE_BPS;
        _prices[CHAIN_ARBITRUM] = PRICE_SCALE_BPS;
    }

    function setPrice(uint8 chainId, uint256 priceBps) external {
        _requireSupportedChain(chainId);
        if (priceBps == 0 || priceBps > MAX_PRICE_BPS) revert InvalidPrice(priceBps);

        uint256 oldPrice = _prices[chainId];
        _prices[chainId] = priceBps;
        emit PriceUpdated(chainId, oldPrice, priceBps);
    }

    function getPrice(uint8 chainId) external view returns (uint256) {
        _requireSupportedChain(chainId);
        return _prices[chainId];
    }

    function getAllPrices() external view returns (uint256 ethereumPrice, uint256 basePrice, uint256 arbitrumPrice) {
        return (
            _prices[CHAIN_ETHEREUM],
            _prices[CHAIN_BASE],
            _prices[CHAIN_ARBITRUM]
        );
    }

    function _requireSupportedChain(uint8 chainId) internal pure {
        if (
            chainId != CHAIN_ETHEREUM
                && chainId != CHAIN_BASE
                && chainId != CHAIN_ARBITRUM
        ) revert InvalidChain(chainId);
    }
}
