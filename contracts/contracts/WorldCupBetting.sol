// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}

/**
 * @title WorldCupBetting
 * @notice Prediction market for World Cup match outcomes.
 *
 * Key design decisions:
 * - AMM share pricing: earlier bettors get more shares per ETH (rewards liquidity)
 * - 2% platform fee applied only on the winning payout, tracked per token type
 * - Position ownership transfers atomically in buyPosition, so the new owner can claim
 * - Losing bettors can still call claimWinnings to record reputation (no funds sent)
 * - ReentrancyGuard on all state-changing functions that move funds
 */
contract WorldCupBetting is ReentrancyGuard, Ownable {
    enum MarketStatus {
        Open,
        Closed,
        Resolved,
        Cancelled
    }

    struct Market {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address creator;
        MarketStatus status;
        uint256 winningOutcome;
        address tokenAddress;
        uint256 totalVolume;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
        bool claimed;
    }

    IReputationSystem public reputationSystem;
    uint256 public marketCount;
    uint256 public betCount;

    uint256 public constant PLATFORM_FEE = 2;
    uint256 public constant FEE_DENOMINATOR = 100;

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomePools;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomeShares;
    mapping(uint256 => Bet) public bets;
    mapping(address => uint256[]) public userBets;
    mapping(uint256 => uint256[]) public marketBets;

    // Secondary market: list a position for sale before resolution
    mapping(uint256 => bool) public positionsForSale;
    mapping(uint256 => uint256) public positionPrices;

    // Fee accumulator — address(0) = ETH, token address = ERC20
    mapping(address => uint256) public collectedFees;

    event MarketCreated(uint256 indexed marketId, address indexed creator, string question);
    event BetPlaced(uint256 indexed betId, uint256 indexed marketId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint256 winningOutcome);
    event WinningsClaimed(uint256 indexed betId, address indexed claimer, uint256 amount);
    event PositionListed(uint256 indexed betId, uint256 price);
    event PositionSold(uint256 indexed betId, address seller, address buyer, uint256 price);
    event FeesWithdrawn(address indexed token, uint256 amount, address indexed to);

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Market lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    function createMarket(
        string memory _question,
        string memory _description,
        string[] memory _outcomes,
        uint256 _resolutionTime,
        address _arbitrator,
        address _tokenAddress
    ) external returns (uint256) {
        require(_outcomes.length >= 2, "Need at least 2 outcomes");
        require(_resolutionTime > block.timestamp, "Resolution must be in future");
        require(_arbitrator != address(0), "Invalid arbitrator");

        marketCount++;

        Market storage m = markets[marketCount];
        m.id = marketCount;
        m.question = _question;
        m.description = _description;
        m.outcomes = _outcomes;
        m.resolutionTime = _resolutionTime;
        m.arbitrator = _arbitrator;
        m.creator = msg.sender;
        m.status = MarketStatus.Open;
        m.tokenAddress = _tokenAddress;

        emit MarketCreated(marketCount, msg.sender, _question);
        return marketCount;
    }

    function placeBet(
        uint256 _marketId,
        uint256 _outcomeIndex,
        uint256 _amount,
        uint256 _minShares
    ) external payable nonReentrant returns (uint256) {
        Market storage market = markets[_marketId];

        require(market.status == MarketStatus.Open, "Market not open");
        require(block.timestamp < market.resolutionTime, "Market closed");
        require(_outcomeIndex < market.outcomes.length, "Invalid outcome");
        require(_amount > 0, "Amount must be > 0");

        if (market.tokenAddress == address(0)) {
            require(msg.value == _amount, "Incorrect ETH amount");
        } else {
            IERC20(market.tokenAddress).transferFrom(msg.sender, address(this), _amount);
        }

        uint256 shares = calculateShares(_marketId, _outcomeIndex, _amount);
        require(shares >= _minShares, "Slippage exceeded");

        betCount++;
        Bet storage bet = bets[betCount];
        bet.id = betCount;
        bet.bettor = msg.sender;
        bet.marketId = _marketId;
        bet.outcomeIndex = _outcomeIndex;
        bet.amount = _amount;
        bet.shares = shares;
        bet.timestamp = block.timestamp;

        outcomePools[_marketId][_outcomeIndex] += _amount;
        outcomeShares[_marketId][_outcomeIndex] += shares;
        market.totalVolume += _amount;

        userBets[msg.sender].push(betCount);
        marketBets[_marketId].push(betCount);

        emit BetPlaced(betCount, _marketId, msg.sender, _amount);
        return betCount;
    }

    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external {
        Market storage market = markets[_marketId];

        require(msg.sender == market.arbitrator, "Only arbitrator");
        require(market.status == MarketStatus.Open, "Market not open");
        require(block.timestamp >= market.resolutionTime, "Too early");
        require(_winningOutcome < market.outcomes.length, "Invalid outcome");

        market.status = MarketStatus.Resolved;
        market.winningOutcome = _winningOutcome;

        emit MarketResolved(_marketId, _winningOutcome);
    }

    function claimWinnings(uint256 _betId) external nonReentrant {
        Bet storage bet = bets[_betId];
        Market storage market = markets[bet.marketId];

        require(msg.sender == bet.bettor, "Not your bet");
        require(!bet.claimed, "Already claimed");
        require(market.status == MarketStatus.Resolved, "Market not resolved");

        // Mark claimed first (checks-effects-interactions pattern)
        bet.claimed = true;

        if (bet.outcomeIndex == market.winningOutcome) {
            uint256 totalWinningShares = outcomeShares[bet.marketId][market.winningOutcome];
            uint256 totalPool = getTotalPool(bet.marketId);

            uint256 payout = (bet.shares * totalPool) / totalWinningShares;
            uint256 fee = (payout * PLATFORM_FEE) / FEE_DENOMINATOR;
            uint256 netPayout = payout - fee;

            collectedFees[market.tokenAddress] += fee;
            reputationSystem.updateReputation(msg.sender, true);

            if (market.tokenAddress == address(0)) {
                (bool success, ) = payable(msg.sender).call{value: netPayout}("");
                require(success, "ETH transfer failed");
            } else {
                IERC20(market.tokenAddress).transfer(msg.sender, netPayout);
            }

            emit WinningsClaimed(_betId, msg.sender, netPayout);
        } else {
            // Loser settles: no funds, but reputation is recorded
            reputationSystem.updateReputation(msg.sender, false);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Secondary market
    // ─────────────────────────────────────────────────────────────────────────

    function listPosition(uint256 _betId, uint256 _price) external {
        Bet storage bet = bets[_betId];
        require(msg.sender == bet.bettor, "Not your bet");
        require(!bet.claimed, "Bet already claimed");
        require(markets[bet.marketId].status == MarketStatus.Open, "Market not open");

        positionsForSale[_betId] = true;
        positionPrices[_betId] = _price;

        emit PositionListed(_betId, _price);
    }

    function cancelListing(uint256 _betId) external {
        Bet storage bet = bets[_betId];
        require(msg.sender == bet.bettor, "Not your bet");
        require(positionsForSale[_betId], "Not listed");

        positionsForSale[_betId] = false;
        positionPrices[_betId] = 0;

        emit PositionListed(_betId, 0);
    }

    function buyPosition(uint256 _betId) external payable nonReentrant {
        require(positionsForSale[_betId], "Position not for sale");

        Bet storage bet = bets[_betId];
        Market storage market = markets[bet.marketId];
        address seller = bet.bettor;
        uint256 price = positionPrices[_betId];

        // Transfer ownership before sending funds (checks-effects-interactions)
        bet.bettor = msg.sender;
        positionsForSale[_betId] = false;
        userBets[msg.sender].push(_betId);

        if (market.tokenAddress == address(0)) {
            require(msg.value >= price, "Insufficient ETH");
            (bool success, ) = payable(seller).call{value: price}("");
            require(success, "ETH transfer failed");
            if (msg.value > price) {
                (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - price}("");
                require(refundSuccess, "Refund failed");
            }
        } else {
            require(msg.value == 0, "Do not send ETH for ERC20 market");
            IERC20(market.tokenAddress).transferFrom(msg.sender, seller, price);
        }

        emit PositionSold(_betId, seller, msg.sender, price);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fee management (owner only)
    // ─────────────────────────────────────────────────────────────────────────

    function withdrawFees(address _tokenAddress) external onlyOwner nonReentrant {
        uint256 fees = collectedFees[_tokenAddress];
        require(fees > 0, "No fees to withdraw");

        collectedFees[_tokenAddress] = 0;

        if (_tokenAddress == address(0)) {
            (bool success, ) = payable(owner()).call{value: fees}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(_tokenAddress).transfer(owner(), fees);
        }

        emit FeesWithdrawn(_tokenAddress, fees, owner());
    }

    function getAvailableFees(address _tokenAddress) external view returns (uint256) {
        return collectedFees[_tokenAddress];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AMM pricing
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculate shares received for a bet amount.
     * First bet into an empty pool: 100 shares per unit (flat rate).
     * Subsequent bets: shares decrease as the pool grows (penalises late entry).
     */
    function calculateShares(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount)
        public view returns (uint256)
    {
        uint256 currentPool = outcomePools[_marketId][_outcomeIndex];
        if (currentPool == 0) return _amount * 100;

        uint256 totalPool = getTotalPool(_marketId);
        uint256 newPool = currentPool + _amount;

        return (_amount * 100 * totalPool) / (newPool * currentPool);
    }

    function getPrice(uint256 _marketId, uint256 _outcomeIndex)
        public view returns (uint256)
    {
        uint256 pool = outcomePools[_marketId][_outcomeIndex];
        uint256 total = getTotalPool(_marketId);
        if (total == 0) return 50;
        return (pool * 100) / total;
    }

    function getTotalPool(uint256 _marketId) public view returns (uint256) {
        Market storage market = markets[_marketId];
        uint256 total = 0;
        for (uint256 i = 0; i < market.outcomes.length; i++) {
            total += outcomePools[_marketId][i];
        }
        return total;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View helpers
    // ─────────────────────────────────────────────────────────────────────────

    function getUserBets(address _user) external view returns (uint256[] memory) {
        return userBets[_user];
    }

    function getMarketBets(uint256 _marketId) external view returns (uint256[] memory) {
        return marketBets[_marketId];
    }

    function getMarket(uint256 _marketId)
        external
        view
        returns (
            uint256 id,
            string memory question,
            string memory description,
            string[] memory outcomes,
            uint256 resolutionTime,
            address arbitrator,
            address creator,
            MarketStatus status,
            uint256 totalVolume,
            address tokenAddress
        )
    {
        Market storage m = markets[_marketId];
        return (
            m.id,
            m.question,
            m.description,
            m.outcomes,
            m.resolutionTime,
            m.arbitrator,
            m.creator,
            m.status,
            m.totalVolume,
            m.tokenAddress
        );
    }
}
