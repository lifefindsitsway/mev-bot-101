# 第 9 篇：策略参数化与跨链泛化 —— 从 1 条链到全网部署

2025-11-04 UTC，AttackContract 的 Base 链部署在 30 秒内对 Moonwell 协议的 6 个市场发动了 12 笔攻击（加上 2025-11-03 UTC 的 TX_NEW 共 13 笔 Moonwell 攻击）。12 笔主攻击的 calldata 都是 932 字节——完全相同的长度。将这 12 份 calldata 逐字节对齐后，一个惊人的事实浮现：**932 字节中只有 73 字节不同**，分布在 5 个精确的位置。其余 859 字节（92.2%）完全一致。

这意味着攻击者不是在为每个市场手写 calldata。他有一套**模板**——一个预编码的攻击框架，只需要填入 5 个参数就能对任意 Moonwell 市场发起攻击。这种模板化思维同样体现在 AttackContract 的跨链部署中——它部署在几乎所有主要 EVM 链上。我们选取了其中 13 条主要公链进行逆向分析，发现这些链上的合约字节码仅差 132 字节——5 处 WETH 地址（100 字节）加上一个 IPFS metadata hash（32 字节）。99.5% 的代码完全相同。

本篇从这两个具体的数据点出发，分析 MEV 策略如何从单笔交易扩展为模板化、跨链、多 EOA 协作的系统化运营。

## Calldata 模板化：5 个可变字段

### 模板结构

回顾第 7 篇中解析过的 TX_01 指令流。整个攻击分为 13 条指令：

```
指令集 1（600B, 11 条）:
  #1  V3_SWAP(flag=1) → 闪贷 wrsETH        [固定: CLPool 地址, 方向]
  #2  BALANCE_OF(wrsETH)                    [固定]
  #3  RAW_CALL → wrsETH.approve(mwrsETH, 0) [固定: 清零授权]
  #4  CALL_WITH_AMOUNT → approve(amount)     [固定]
  #5  CALL_WITH_AMOUNT → mwrsETH.mint()     [固定]
  #6  RAW_CALL → enterMarkets([mwrsETH])    [固定]
  #7  RAW_CALL → mcbXRP.borrow(amount)      [★可变: mToken 地址 + 借出金额]
  #8  BALANCE_OF(cbXRP)                     [★可变: 底层资产地址]
  #9  V3_SWAP → cbXRP → WETH               [★可变: DEX 池地址]
  #10 BALANCE_OF(WETH)                      [固定]
  #11 V3_SWAP → WETH → wrsETH（还贷）      [固定: 还贷池地址]

指令集 2（77B, 2 条）:
  #12 BALANCE_OF(wrsETH)                    [固定]
  #13 V3_SWAP → wrsETH → WETH（利润）      [固定]
```

13 条指令中，只有 #1（闪贷金额）、#7（borrow 目标）、#8（资产地址）、#9（swap 池）需要根据目标市场变化。模板的固定部分覆盖了整个攻击框架：闪贷来源、抵押品存入、市场激活、WETH 回购、利润提取。

### 5 个可变字段

在 `reference/archive_0x42Ecd332/reports/calldata_format.md` 中，我们精确定位了 5 个可变字段的字节偏移：

| 偏移 | 字节数 | 字段 | TX_01（cbXRP 市场） | 说明 |
|------|--------|------|-------------------|------|
| `[243-249]` | 7 | 闪贷 wrsETH 数量 | `0x024f3af120a155` (~0.00065 wrsETH) | 决定抵押品规模 |
| `[583-602]` | 20 | mToken 借贷地址 | mcbXRP `0xb4fb...` | 目标借贷市场 |
| `[636-641]` | 6 | 借出金额 | `0x0118bf20a1d4` | 可借数量 |
| `[643-662]` | 20 | 底层资产 token | cbXRP `0xcb58...` | 借出的资产 |
| `[665-684]` | 20 | DEX swap 池 | AlgebraPool `0xee58...` | 资产→WETH 出口 |

**总可变字节**：7 + 20 + 6 + 20 + 20 = **73 字节**（占 932 字节的 7.8%）。

这 5 个字段之间存在逻辑依赖关系：

```
mToken 地址 → 决定了底层资产 token
底层资产 token → 决定了 DEX swap 池（需要该 token/WETH 的流动性池）
DEX swap 池的流动性 → 约束了最大借出金额
借出金额 × 抵押率 → 决定了闪贷 wrsETH 数量
```

链下系统只需要做一个决策：**攻击哪个 mToken 市场？** 其余 4 个字段都可以从这个决策自动推导。

### 为什么闪贷金额只有 7 字节可变？

注意闪贷金额是 V3_SWAP 指令中 32 字节 `amt` 字段的一部分。虽然字段宽度固定为 32 字节，但由于闪贷金额极小（~0.00065 wrsETH），高位全是零，只有最低 7 字节在不同交易间变化。这就是为什么可变字段表中闪贷金额标注为 7 字节——它不是编码宽度，而是**实际变化的字节数**。

但更有趣的是，TX_01 的闪贷金额只有 ~0.00065 wrsETH（约 $3 的 ETH 价值）。如此小的初始金额如何撬动 30.79 ETH 的利润？答案在于 Moonwell 的预言机定价偏差——wrsETH 的预言机价格被错误地报告为实际价格的 1657 倍。0.00065 wrsETH 的实际价值约 $3，但 Moonwell 预言机认为它价值约 $5,000，因此允许借出远超实际抵押价值的资产。这就是预言机套利的杠杆效应——闪贷金额不需要大，只需要足够触发预言机的错误定价。

## 多市场扫描：从参数到策略

模板化使攻击可以快速切换目标市场。但决定"攻击哪个市场"需要一个扫描系统。从 13 笔 Moonwell 攻击的分布来看：

| 目标资产 | 攻击次数 | 累计利润（ETH） | 包含交易 |
|---------|---------|--------------|---------|
| wstETH | 4 | ~98.97 | TX_06 (24.92) + TX_07 (24.80) + TX_08 (24.68) + TX_11 (24.57) |
| AERO | 2 | ~49.63 | TX_05 (24.93) + TX_12 (24.70) |
| cbETH | 2 | ~49.34 | TX_09 (24.84) + TX_10 (24.51) |
| EURC | 2 | ~49.03 | TX_02 (25.49) + TX_03 (23.55) |
| cbXRP | 1 | ~30.79 | TX_01 |
| USDC | 1 | ~22.40 | TX_04 |
| tBTC | 1 | ~0.18 | TX_NEW |

wstETH 市场被攻击了 4 次（累计 ~98.97 ETH），是利润最高的单一资产。攻击者对同一资产（wstETH、AERO、cbETH、EURC）发起了多轮攻击——每次攻击都消耗部分 DEX 流动性（价格滑点增大），使后续攻击利润递减。以 wstETH 为例，四轮利润从 24.92 → 24.80 → 24.68 → 24.57 ETH 逐步下降。这种"多轮榨取"策略需要链下系统在每轮攻击后重新计算剩余流动性和预期利润。

### 机会发现系统的推测架构

虽然我们无法直接观察链下系统，但从攻击模式可以推断其基本架构：

```
┌─────────────────────────────────────────────────────┐
│                  链下 Searcher 系统                    │
│                                                     │
│  ① 预言机监控                                        │
│     监听 Chainlink 价格更新 → 检测偏差               │
│     wrsETH 偏差 > 阈值 → 触发攻击流程                │
│                                                     │
│  ② 多市场扫描                                        │
│     遍历 Moonwell 各 mToken 市场:                    │
│       可借余额 = mToken.getCash()                    │
│       DEX 流动性 = pool.getReserves() / pool.liquidity()│
│       预期利润 = f(借出金额, DEX 滑点, 闪贷费用)      │
│                                                     │
│  ③ 利润排序                                          │
│     按预期利润降序排列 → 选择 Top-N 市场              │
│                                                     │
│  ④ Calldata 生成                                     │
│     读取 932B 模板 → 填充 5 个可变字段 → 生成 N 笔 TX │
│                                                     │
│  ⑤ 批量提交                                          │
│     通过 Flashbots/私有通道 → 同一区块打包            │
└─────────────────────────────────────────────────────┘
```

12 笔主攻击在同一个 30 秒时间窗口内执行（TX_NEW 在前一天 11/03 单独执行），gas price 高达 175-253 gwei（Base 正常水平的 200 倍以上），证实了攻击者通过高 gas 溢价确保所有交易在预言机偏差修正前被打包。

## 跨链泛化：132 字节的差异

### 跨链部署的字节码分析

AttackContract 部署在几乎所有主要 EVM 链上。我们选取了其中 13 条进行逆向分析——包括 Ethereum、Base、BNB、Sei、Sonic、Optimism、Arbitrum、Berachain、Avalanche、Mantle、Polygon、Fraxtal 和 Moonbeam。仅这 13 条链的部署就在 2025 年 9 月 30 日一天之内完成（从 Ethereum 首部署 08:48 UTC 到 Sei 最后部署 16:28 UTC，历时 7 小时 40 分钟）。

所有部署使用 `CREATE` 操作码，且 nonce 均为 0——即每条链上的第一笔交易就是部署合约。这使得合约地址可以通过 `cast compute-address <deployer> --nonce 0` 在部署前预计算。

跨链字节码差异分析：

```
总字节码: 24,543 字节

差异来源:
├── WETH 地址 × 5 处引用 = 100 字节
│   Ethereum: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
│   Base:     0x4200000000000000000000000000000000000006
│   BNB:      0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
│   ...（每链不同）
│
└── IPFS metadata hash = 32 字节
    （Solidity 编译器自动附加的 CBOR 编码元数据）

固定部分: 24,543 - 132 = 24,411 字节 (99.5%)
```

WETH 是各 EVM 链之间最核心的差异——每条链的原生代币包装合约地址不同。AttackContract 将 WETH 声明为 `immutable`（第 71 行），通过 constructor 参数传入：

```solidity
IWETH immutable WETH;

constructor(address _weth) {
    WETH = IWETH(_weth);
}
```

`immutable` 变量在部署时写入字节码（而非存储槽），因此 WETH 地址出现在 runtime bytecode 的 5 个位置（对应 5 处引用：WETH.deposit、WETH.withdraw、WETH.balanceOf 等）。每个位置 20 字节 × 5 处 = 100 字节。加上 32 字节的 IPFS metadata hash，总差异恰好 132 字节。

### "逆向 Base = 逆向全部"

这 132 字节的差异意味着一个极其重要的逆向工程原则：**只需深度逆向 Base 链的字节码，就等于逆向了所有链上的合约**。指令引擎逻辑、回调路由、安全包装器——24,411 字节的核心代码在所有链上完全相同。

我们在第 6 篇中详细描述的逆向过程——从 WhatsABI 到 Heimdall，从 cast run --trace 到字节级对照——全部在 Base 链上完成。结论直接适用于 Ethereum、BNB、Sonic 等所有其他链。唯一需要额外验证的是各链的 WETH 地址是否正确替换。

这也解释了 AttackContract 的设计决策：将 WETH 声明为 `immutable` 而非 `constant`。如果用 `constant`，每条链需要修改源码中的硬编码地址并重新编译。用 `immutable`，同一份源码只需在部署时传入不同的构造函数参数——**部署脚本的差异取代了源码的差异**。

### 跨链部署策略

AttackContract 使用 `immutable` WETH + CREATE nonce=0 的跨链部署策略：

- **WETH 处理**：`immutable`（constructor 参数），每链传入不同的 wrapped native token 地址
- **部署方式**：多链 CREATE，`0xA98E339f` 部署全部使用 nonce=0
- **地址预测**：可通过 `cast compute-address <deployer> --nonce 0` 部署前预计算
- **字节码版本**：12 种（Base+Optimism 共享；Polygon 额外 +1,149B 的 Atlas 集成）
- **源码修改**：零修改——仅 constructor 参数不同

Polygon 是一个特例——它多出 1,149 字节的 Atlas Protocol 集成逻辑（包括 `atlasSolverCall` 选择器），但 4 笔交易全部失败，这个功能从未成功执行。

## 跨协议泛化：RAW_CALL + CALL_WITH_AMOUNT

跨链解决的是"同一策略部署到不同链"的问题。跨协议解决的是"同一指令引擎适配不同 DeFi 协议"的问题。

我们在第 7 篇中分析了 CALL_WITH_AMOUNT 的 trail 机制。现在从跨协议泛化的角度重新审视它。

AttackContract 实际对接了两个借贷协议：Moonwell（Compound fork）和 Morpho Blue。两者的 ABI 差异巨大：

```solidity
// Moonwell: 简单的单参数函数
mToken.mint(uint256 amount)              // 4B selector + 32B amount

// Morpho Blue: 多参数复杂函数
morpho.supplyCollateral(
    MarketParams memory marketParams,     // 160B 结构体
    uint256 amount,                       // 32B
    address onBehalf,                     // 32B
    bytes memory data                     // 64B (offset + length)
)
```

CALL_WITH_AMOUNT 通过 prefix + amount + trail 的三段结构统一了这两种调用：

```
Moonwell: prefix=[mint selector (4B)]  + amount(32B) + trail=0
          calldata = [0xa0712d68][amount]

Morpho:   prefix=[selector (4B) + MarketParams (160B)] + amount(32B) + trail=96B
          calldata = [selector][MarketParams][amount][shares][onBehalf][receiver]
```

这种设计的核心洞察是：**大多数 DeFi 协议的函数签名都包含一个"金额"参数**。CALL_WITH_AMOUNT 把金额固定为 amount 寄存器的值（运行时动态），其余参数通过 prefix（前置静态数据）和 trail（后置静态数据）灵活拼接。

配合 RAW_CALL（无需 amount 的通用调用），两个操作码覆盖了所有 DeFi 协议交互——这就是为什么 12 个操作码就够用，不需要为每个新协议添加专用操作码。

## BNB 链三地址轮转

在第 8 篇中我们介绍了 AttackContract 的 `ops` 函数和子 EOA 管理。BNB 链是这个运营模式最完整的案例。

BNB 链共 83 笔交易（58 笔攻击 + 24 笔 ops 运维 + 1 笔部署），三个地址分工明确：

| 地址 | 角色 | 攻击次数 | 占比 | 其他活动 |
|------|------|---------|------|---------|
| 0x6997 | 主 EOA | 14 | 24.1% | 部署合约 + 24 笔 ops 运维 |
| 0xa1d2 | 子 EOA-B | 26 | 44.8% | 同时活跃于 Ethereum（2 笔） |
| 0x8ca6 | 子 EOA-A | 18 | 31.0% | BNB 专用 |

运营流程：

```
1. 主 EOA 部署合约（nonce=0）
2. 主 EOA 调用 ops() → 批量向子 EOA 补充 gas
3. 子 EOA 调用 approve() → 执行攻击
4. 利润自动流向 PROFIT_RECEIVER（= 主 EOA）
5. 重复 2-4
```

三地址轮转的可能动机：

- **吞吐量**：BNB 链攻击密度最高（58 笔），单一 EOA 的 nonce 序列可能成为瓶颈
- **反检测**：分散发起地址降低被链上监控系统标记为"同一攻击者"的概率
- **故障隔离**：如果某个 EOA 的交易卡住（nonce 间隙），其他 EOA 不受影响

注意 0xa1d2（子 EOA-B）同时在 Ethereum 链上执行了 2 笔攻击——这说明子 EOA 不是链专用的，而是根据需要跨链调度。

## 部署与攻击时间线

将 AttackContract 在各链上的完整时间线放在一起：

```
2025-09-30 08:48 UTC    0xA98E339f 首部署 (Ethereum, nonce=0)
         ↓ 7h40m
2025-09-30 16:28 UTC    0xA98E339f 末部署 (Sei) — 分析的 13 链就位
         ↓
2025-10-01 ~ 10-11      跨链主要攻击期 (分析的 13 链上 249 笔攻击)
         ↓
2025-10-11 07:55 UTC    0x42Ecd332 部署到 Base (nonce=53)
         ↓
2025-10-17 UTC          Base 链首次攻击:
                         - TX_FAIL: VIRTUAL 市场 (失败)
                         - TX_SUCCESS: Morpho Blue weETH (0.14 ETH)
         ↓ 18 天
2025-11-03 18:03 UTC    TX_NEW: tBTC 市场 (0.18 ETH)
2025-11-04 05:44 UTC    Base 链大规模攻击 (12 笔, ~300 ETH)
         ↓
2025-11-05 UTC          跨链最后 1 笔 (Optimism)
```

几个值得注意的观察：

**跨链部署先于 Base 链部署**。`0xA98E339f`（nonce=0）在 2025-09-30 一天内完成 13 链部署。Base 链的 `0x42Ecd332`（nonce=53）在 10 月 11 日才部署。两者经字节码同一性验证确认为同一份源码——链间差异仅 132 字节（WETH immutable + IPFS metadata）。攻击者先在多链铺开基础设施，后在 Base 链追加部署。

**18 天静默期**。2025-10-17 UTC 首次 Base 链攻击后沉寂了 18 天。这说明攻击者在**等待机会**——预言机套利不是随时可用的，它依赖于外部事件（价格异常）的触发。链下 Searcher 系统在这 18 天中持续监控预言机价格（推断，无链上直接证据），直到 2025-11-04 UTC wrsETH 出现 1657 倍偏差。

**多链并行运营**。跨链最后一笔交易（2025-11-05 UTC Optimism）晚于 Base 链大规模攻击（2025-11-04 UTC），同一份合约源码在不同链上并行运营。

## 动手环节

### 任务 1：读取 Moonwell 市场数据

编写 Python 脚本，查询 Moonwell 各市场的可借余额和预言机价格：

```python
# moonwell_markets.py
# 读取 Moonwell 各 mToken 市场的关键参数
# 需要安装: pip install web3

from web3 import Web3

# Base 链 RPC
w3 = Web3(Web3.HTTPProvider("https://mainnet.base.org"))

# Moonwell Unitroller (Compound Comptroller fork)
UNITROLLER = "0xfBb21d0380beE3312B33c4353c8936a0F13EF26C"

# 部分 mToken 市场 (被攻击的市场)
MARKETS = {
    "mwrsETH": "0x02D50cC30D840e73e1B3F26B1F0C7e3d00A46A26",  # 抵押品
    "mcbXRP":  "0xb4fB1FEBb6faab24f4F5033Ba3b6dD4eFf2fc846",
    "mUSDC":   "0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22",
    "mVIRTUAL":"0xeB3dEed41b0422Bf25CcDa3eE46aa6B73A62F0CE",
}

# ERC20 ABI (简化)
ERC20_ABI = [{"inputs":[{"name":"account","type":"address"}],
              "name":"balanceOf","outputs":[{"type":"uint256"}],
              "stateMutability":"view","type":"function"}]

# mToken ABI (Compound fork)
MTOKEN_ABI = [
    {"inputs":[],"name":"getCash","outputs":[{"type":"uint256"}],
     "stateMutability":"view","type":"function"},
    {"inputs":[],"name":"underlying","outputs":[{"type":"address"}],
     "stateMutability":"view","type":"function"},
    {"inputs":[],"name":"exchangeRateStored","outputs":[{"type":"uint256"}],
     "stateMutability":"view","type":"function"},
]

def scan_markets():
    """扫描各 mToken 市场的可借余额"""
    print(f"当前区块: {w3.eth.block_number}\n")
    print(f"{'市场':<12} {'可借余额 (原始)':<30} {'底层资产'}")
    print("-" * 70)

    for name, addr in MARKETS.items():
        contract = w3.eth.contract(address=addr, abi=MTOKEN_ABI)
        try:
            cash = contract.functions.getCash().call()
            underlying = contract.functions.underlying().call()
            print(f"{name:<12} {cash:<30} {underlying}")
        except Exception as e:
            print(f"{name:<12} 查询失败: {e}")

if __name__ == "__main__":
    scan_markets()
```

运行后会看到各市场当前的可借余额——攻击者的链下系统持续监控这些数据，当预言机偏差出现时，选择可借余额最大的市场作为首要目标。

### 任务 2：Calldata 模板填充器

基于 5 个可变字段的偏移信息，编写一个 calldata 模板填充器：

```python
# calldata_template.py
# AttackContract Moonwell 攻击 calldata 模板填充器
# 注意：这是教学用途的分析工具，不是攻击工具

# TX_01 完整 calldata (932 字节) 作为模板
# 实际使用时从链上获取:
# cast tx 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
#   input --rpc-url https://mainnet.base.org

# 5 个可变字段的偏移和大小（不含 0x 前缀的字节偏移）
VARIABLE_FIELDS = {
    "flash_amount":     {"offset": 243, "size": 7,  "desc": "闪贷 wrsETH 数量"},
    "mtoken_address":   {"offset": 583, "size": 20, "desc": "mToken 借贷地址"},
    "borrow_amount":    {"offset": 636, "size": 6,  "desc": "借出金额"},
    "underlying_token": {"offset": 643, "size": 20, "desc": "底层资产 token"},
    "dex_pool":         {"offset": 665, "size": 20, "desc": "DEX swap 池"},
}

def fill_template(template_hex: str, params: dict) -> str:
    """
    填充 calldata 模板的可变字段

    Args:
        template_hex: 完整模板 calldata (hex string, 不含 0x)
        params: 字典，key 为字段名，value 为 hex string (不含 0x)

    Returns:
        填充后的 calldata (hex string)
    """
    template = bytearray.fromhex(template_hex)

    for field_name, value_hex in params.items():
        if field_name not in VARIABLE_FIELDS:
            raise ValueError(f"未知字段: {field_name}")

        field = VARIABLE_FIELDS[field_name]
        value_bytes = bytes.fromhex(value_hex)

        if len(value_bytes) != field["size"]:
            raise ValueError(
                f"字段 {field_name} 期望 {field['size']} 字节, "
                f"实际 {len(value_bytes)} 字节"
            )

        # 替换模板中对应偏移的字节
        offset = field["offset"]
        template[offset : offset + field["size"]] = value_bytes

    return template.hex()

def analyze_diff(calldata_list: list[str]):
    """分析多份 calldata 之间的差异"""
    if len(calldata_list) < 2:
        return

    base = bytes.fromhex(calldata_list[0])
    diff_positions = set()

    for cd_hex in calldata_list[1:]:
        cd = bytes.fromhex(cd_hex)
        for i in range(min(len(base), len(cd))):
            if base[i] != cd[i]:
                diff_positions.add(i)

    print(f"总字节数: {len(base)}")
    print(f"差异字节数: {len(diff_positions)}")
    print(f"差异占比: {len(diff_positions)/len(base)*100:.1f}%")
    print(f"\n差异位置分布:")
    for field_name, field in VARIABLE_FIELDS.items():
        start = field["offset"]
        end = start + field["size"]
        overlap = len([p for p in diff_positions if start <= p < end])
        print(f"  {field['desc']:<20} [{start}-{end}]: {overlap}/{field['size']} 字节")

# 使用示例
if __name__ == "__main__":
    # 示例：替换 mToken 地址（从 mcbXRP 到 mUSDC）
    print("Calldata 模板可变字段:")
    print("-" * 60)
    for name, field in VARIABLE_FIELDS.items():
        end = field["offset"] + field["size"]
        print(f"  {name:<20} offset=[{field['offset']}-{end}] "
              f"size={field['size']}B  {field['desc']}")

    total_var = sum(f["size"] for f in VARIABLE_FIELDS.values())
    print(f"\n固定: {932 - total_var}B ({(932 - total_var)/932*100:.1f}%)")
    print(f"可变: {total_var}B ({total_var/932*100:.1f}%)")
```

### 任务 3：Foundry Fork 测试验证

使用 Foundry 的 fork 测试框架验证 calldata 的正确性：

```bash
# 获取 TX_01 的 calldata
cast tx 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  input --rpc-url https://mainnet.base.org

# 在攻击前一个区块的 fork 上重放
cast call 0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB \
  --data <上面获取的calldata> \
  --from 0x6997a8c804642AE2de16D7B8Ff09565a5D5658ff \
  --rpc-url https://mainnet.base.org \
  --block 37722874

# 如果返回无错误，说明 calldata 在该区块状态下可以成功执行
```

**注意**：这个 fork 测试使用的是 `cast call`（模拟调用，不提交交易），不会产生任何链上效果。目的是验证 calldata 解码和指令执行的正确性。

## 小结

MEV 策略的扩展遵循三个层次的参数化：

**Calldata 模板化**——AttackContract Base 链部署的 12 笔主攻击共享同一个 932 字节的模板，只有 73 字节（7.8%）根据目标市场变化。5 个可变字段对应 5 个决策变量：闪贷金额、mToken 地址、借出金额、底层资产、DEX 出口池。链下系统只需做一个核心决策——攻击哪个市场——其余参数自动推导。

**跨链泛化**——AttackContract 通过将 WETH 声明为 `immutable`（而非 `constant`），实现了同一份编译产物部署到几乎所有主要 EVM 链，我们分析的 13 条链上仅 132 字节差异（5×WETH 地址 + metadata hash）。"逆向 Base = 逆向全部"这个原则让安全分析工作量降为 1 倍。

**运营组织化**——BNB 链的三地址轮转（主 EOA + 2 子 EOA）、`ops` 函数的批量 gas 分发、以及 09/30 多链部署 → 10/11 Base 链追加部署 → 并行运营的时间线，展示了 MEV 不仅是"写代码"，更是"系统化运营"。

**下一篇**：第 10 篇《构建你自己的 MEV Router》，我们将基于 Lotus Router 进行实战改造——添加 amount 寄存器和 BALANCE_OF 操作码，让纯无状态的路由器获得运行时状态感知能力，最终构建一个可用于预言机套利的完整 MEV 路由合约。
