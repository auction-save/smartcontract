# AuctionSave Smart Contract

Decentralized rotating savings auction protocol built on Lisk EVM with **commit-reveal auction mechanism** for fair winner selection.

## Overview

AuctionSave is a traditional rotating savings concept (ROSCA) brought on-chain with:

- **Highest bidder wins** via commit-reveal auction
- **80/20 withheld payout** - winner receives 80% immediately, 20% after completion
- **Automatic penalty system** for defaulters (security + withheld forfeited)
- **Demo mode** with `speedUpCycle()` for testing

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `GROUP_SIZE` | 5 | Number of members per group |
| `COMMITMENT` | 50 ether | Contribution amount |
| `SECURITY_DEPOSIT` | 50 ether | Security deposit |
| `MAX_BID_BPS` | 3000 | Maximum bid (30%) |
| `DEV_FEE_BPS` | 100 | Developer fee (1%) |

## Architecture

```
src/
├── AuctionSaveFactory.sol      # Factory to deploy pools
├── AuctionSaveGroup.sol        # Core protocol logic per pool
├── MockUSDT.sol                # Test token with faucet
└── libraries/
    └── AuctionSaveTypes.sol    # Shared structs, enums, constants

test/
├── AuctionSaveFactory.t.sol    # Factory tests
├── AuctionSaveGroup.t.sol      # Group tests
└── mocks/
    └── MockERC20.sol           # Test token

script/
└── DeployAuctionSave.s.sol     # Deployment scripts
```

---

## User Flow dengan Nilai Konkret

### Skenario: 5 Member (Alice, Bob, Charlie, Dave, Eve)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        FASE 1: JOIN                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Setiap member deposit: COMMITMENT + SECURITY = 50 + 50 = 100 USDT │
│                                                                     │
│  Alice  → deposit 100 USDT → Contract                               │
│  Bob    → deposit 100 USDT → Contract                               │
│  Charlie→ deposit 100 USDT → Contract                               │
│  Dave   → deposit 100 USDT → Contract                               │
│  Eve    → deposit 100 USDT → Contract                               │
│                                                                     │
│  Total di Contract: 500 USDT                                        │
│  - Pool (5 × 50 USDT)      = 250 USDT (untuk 5 cycle)              │
│  - Security (5 × 50 USDT)  = 250 USDT (dikembalikan di akhir)      │
│                                                                     │
│  Status: ACTIVE, Cycle 1 dimulai                                    │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     FASE 2: CYCLE 1 - BIDDING                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Pool per cycle = 50 USDT (COMMITMENT)                              │
│                                                                     │
│  COMMIT PHASE:                                                      │
│  Alice   → commitBid(hash(1000 BPS, salt))  // 10%                  │
│  Bob     → commitBid(hash(2000 BPS, salt))  // 20%                  │
│  Charlie → commitBid(hash(3000 BPS, salt))  // 30% (MAX)            │
│  Dave    → commitBid(hash(500 BPS, salt))   // 5%                   │
│  Eve     → tidak bid                                                │
│                                                                     │
│  REVEAL PHASE:                                                      │
│  Alice   → revealBid(1000, salt)                                    │
│  Bob     → revealBid(2000, salt)                                    │
│  Charlie → revealBid(3000, salt)  ← HIGHEST!                        │
│  Dave    → revealBid(500, salt)                                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   FASE 3: CYCLE 1 - SETTLEMENT                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  WINNER: Charlie (bid tertinggi 3000 BPS = 30%)                     │
│                                                                     │
│  1. BIDDING PAYMENT (Charlie bayar bid amount):                     │
│     bidAmount = 50 USDT × 30% = 15 USDT                             │
│     Charlie → transfer 15 USDT → Contract                           │
│                                                                     │
│     Dev fee = 15 × 1% = 0.15 USDT                                   │
│     Distributable = 15 - 0.15 = 14.85 USDT                          │
│     Share per member = 14.85 / 4 = 3.7125 USDT                      │
│                                                                     │
│     Alice, Bob, Dave, Eve masing-masing terima 3.7125 USDT          │
│                                                                     │
│  2. POOL PAYMENT (80/20 split):                                     │
│     Pool = 50 USDT                                                  │
│     80% = 40 USDT                                                   │
│     20% = 10 USDT                                                   │
│                                                                     │
│     Dev fee 80% = 40 × 1% = 0.4 USDT                                │
│     Dev fee 20% = 10 × 1% = 0.1 USDT                                │
│                                                                     │
│     Charlie terima langsung: 40 - 0.4 = 39.6 USDT                   │
│     Charlie withheld: 10 - 0.1 = 9.9 USDT (diklaim setelah selesai) │
│                                                                     │
│  HASIL CYCLE 1:                                                     │
│  - Charlie: +39.6 USDT (langsung) + 9.9 USDT (withheld)             │
│  - Charlie: -15 USDT (bid payment)                                  │
│  - Charlie NET: +34.5 USDT langsung, +9.9 USDT nanti                │
│  - Alice, Bob, Dave, Eve: +3.7125 USDT masing-masing                │
│  - Dev: +0.65 USDT                                                  │
│                                                                     │
│  Charlie.hasWon = true (tidak bisa menang lagi)                     │
│  Cycle 2 dimulai                                                    │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   FASE 4: CYCLE 2-5 (REPEAT)                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Cycle 2: Alice, Bob, Dave, Eve bisa bid (Charlie sudah menang)     │
│  Cycle 3: 3 member tersisa bisa bid                                 │
│  Cycle 4: 2 member tersisa bisa bid                                 │
│  Cycle 5: 1 member tersisa otomatis menang                          │
│                                                                     │
│  Setiap cycle:                                                      │
│  - Pool = 50 USDT                                                   │
│  - Winner terima 80% = 39.6 USDT (setelah fee)                      │
│  - Winner withheld 20% = 9.9 USDT                                   │
│  - Winner bayar bid amount (0-30% dari 50 USDT)                     │
│  - Non-winners terima share dari bid amount                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   FASE 5: GROUP COMPLETED                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Setelah 5 cycle selesai:                                           │
│                                                                     │
│  1. withdrawSecurity() - Semua member klaim security deposit        │
│     Alice, Bob, Charlie, Dave, Eve → masing-masing 50 USDT          │
│                                                                     │
│  2. withdrawWithheld() - Winners klaim 20% yang ditahan             │
│     Setiap winner → 9.9 USDT                                        │
│                                                                     │
│  3. withdrawDevFee() - Developer klaim fee                          │
│     Developer → total ~3.25 USDT (5 cycle × 0.65 USDT)              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Ringkasan Ekonomi per Member

Asumsi: Semua member bid 10% (1000 BPS) dan menang di cycle berbeda

| Member | Deposit | Bid Payment | Pool 80% | Withheld 20% | Bid Share | Security | NET |
|--------|---------|-------------|----------|--------------|-----------|----------|-----|
| Alice | -100 | -5 | +39.6 | +9.9 | +14.85 | +50 | +9.35 |
| Bob | -100 | -5 | +39.6 | +9.9 | +14.85 | +50 | +9.35 |
| Charlie | -100 | -5 | +39.6 | +9.9 | +14.85 | +50 | +9.35 |
| Dave | -100 | -5 | +39.6 | +9.9 | +14.85 | +50 | +9.35 |
| Eve | -100 | -5 | +39.6 | +9.9 | +14.85 | +50 | +9.35 |

**Note**: Bid share dihitung dari total bid payments dari semua winners yang didistribusikan ke non-winners.

---

## Installation

```bash
forge install
forge build
forge test -vv
```

## Deployment

```bash
# Setup environment
cp .env.example .env
# Edit .env with your PRIVATE_KEY and DEVELOPER_ADDRESS

# Deploy everything (MockUSDT + Factory + Demo Pool)
source .env
forge script script/DeployAuctionSave.s.sol:DeployAuctionSave \
  --sig "runFullDemo()" \
  --rpc-url lisk_sepolia \
  --broadcast \
  -vvvv
```

## Network Configuration

| Network      | Chain ID | RPC URL                          |
| ------------ | -------- | -------------------------------- |
| Lisk Sepolia | 4202     | https://rpc.sepolia-api.lisk.com |
| Lisk Mainnet | 1135     | https://rpc.api.lisk.com         |

## Security Features

| Feature | Description |
|---------|-------------|
| **Commit-Reveal** | Sealed bids prevent front-running |
| **SafeERC20** | Safe token transfers |
| **ReentrancyGuard** | Prevents reentrancy attacks |
| **Bound Commitment** | Commitment includes bidder, cycle, contract, chainid |

## Testing

```bash
forge test           # Run all tests
forge test -vvv      # With verbosity
forge test --gas-report  # Gas report
```

**Test Coverage**: 28 tests passing

## License

MIT
