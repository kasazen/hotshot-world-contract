// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { INonfungiblePositionManager, IUniswapV3Factory } from
    "../../src/interfaces/IUniswapV3.sol";

/// @notice Mock UniswapV3Factory pairing with MockNPM. Stores per-(token0,
///         token1, fee) pool addresses so tests can simulate the Virtuals
///         attack: pre-set a pool address before graduation runs.
contract MockV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) internal _pools;

    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool)
    {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pools[keccak256(abi.encode(t0, t1, fee))];
    }

    /// @notice Test-only: pre-create a pool entry to simulate the Virtuals
    ///         attack class.
    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }
}

/// @notice Test double for Uniswap V3 NonfungiblePositionManager. Pulls the
///         seeded liquidity (so curve accounting is validated) and hands back
///         sequential tokenIds. Does NOT model AMM math — the real pool/price
///         correctness is out of scope for these orchestration tests (see
///         BondingCurve NatSpec: needs a fork test before mainnet).
contract MockNPM is INonfungiblePositionManager {
    uint256 public nextId = 1;
    mapping(uint256 => address) public ownerOf;
    address public lastPool = address(0x1111111111111111111111111111111111111111);
    uint160 public lastSqrtPrice;
    MockV3Factory public immutable v3Factory;

    constructor() {
        v3Factory = new MockV3Factory();
    }

    function factory() external view returns (address) {
        return address(v3Factory);
    }

    function createAndInitializePoolIfNecessary(address, address, uint24, uint160 sp)
        external
        payable
        returns (address)
    {
        lastSqrtPrice = sp;
        return lastPool;
    }

    function mint(MintParams calldata p)
        external
        payable
        returns (uint256 id, uint128 liq, uint256 a0, uint256 a1)
    {
        IERC20(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired);
        IERC20(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired);
        id = nextId++;
        ownerOf[id] = p.recipient;
        return (id, 1e18, p.amount0Desired, p.amount1Desired);
    }

    function collect(CollectParams calldata) external payable returns (uint256, uint256) {
        return (0, 0);
    }

    function safeTransferFrom(address, address to, uint256 id) external {
        ownerOf[id] = to;
    }
}
