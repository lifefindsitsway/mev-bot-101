# 如何构造一套完整的 MEV Searcher 系统？

> AttackContract 背后的操作者就是一个 Searcher。他们编写了合约（链上执行引擎），构建了链下的机会发现系统（监控预言机价格、扫描可借流动性），并在 wrsETH 预言机出现 1657 倍偏差的瞬间，迅速生成 calldata 并提交攻击交易。

逆向分析让我们看到了冰山水面上的部分——链上执行引擎，但真正让这套系统运转的，是水面下那套庞大的链下基础设施。以下从全局视角拆解这个系统的完整架构。

---

## 前置概念：为什么预言机偏差能赚钱？

在深入系统架构之前，先理解一个核心前提：**借贷协议依赖预言机报价来判断抵押品价值**。

正常情况下，用户向 Moonwell 存入价值 $3,500 的 1 个 wrsETH，协议按 collateral factor（抵押率）允许借出对应比例的其他资产。但当 Chainlink 预言机报出错误价格——wrsETH 单价被高报为真实价格的 1657 倍——协议会认为抵押品价值远超实际，允许借出远超其真实价值的资产。

攻击者的操作很简单：用闪贷借入极少量 wrsETH（约 0.00065 个，真实价值约 $2.3）作为抵押品，协议基于错误报价将其估值放大 1657 倍（约 $3,800），允许借出等值的真实资产（如 cbXRP、USDC、wstETH 等），然后在 DEX 上按真实市场价格卖出这些资产获利。整个过程在一笔交易内原子完成，闪贷在同一笔交易中归还，攻击者无需持有任何本金。

这就是"预言机套利"的本质——**利用借贷协议对资产定价的信任偏差，以低成本抵押品超额借款并套现**。AttackContract 的 15 笔攻击交易（覆盖 Moonwell 和 Morpho Blue 两个协议的 8 个市场）正是反复执行这个逻辑，最终净提取 295.75 ETH（~$1.06M）利润，同时给 Moonwell 协议留下了约 $3.7M 的坏账（据 Halborn Security 事后分析报告）。

需要注意的是，预言机操纵只是 MEV 的一种特定形式。经典的 MEV 类型还包括 DEX 套利（价差搬运）、三明治攻击（夹击用户交易）、清算（抢先清算不健康头寸）等，它们在监控层和策略层的设计差异很大。本文以预言机攻击为案例拆解系统架构，但核心的三层框架（监控 → 策略 → 执行）适用于所有 MEV 类型。

---

## 整体框架：三层系统

在深入细节之前，先建立一个心智模型。一个完整的 MEV Searcher 系统可以分为三个层次，它们之间的关系就像一支军队的情报部、参谋部和前线部队：

**第一层：链下监控系统（情报部）**——持续扫描链上状态，发现套利机会。这是 Searcher 的"眼睛"。

**第二层：策略引擎与 Calldata 生成器（参谋部）**——当机会出现时，计算最优路径、模拟利润、生成精确的交易数据。这是 Searcher 的"大脑"。

**第三层：链上执行引擎（前线部队）**——接收 calldata 并在链上原子化执行闪贷、swap、借贷等操作。这就是我们已经逆向分析的 AttackContract（`moonwell_exploit_reverse_analysis/AttackContract/src/AttackContract.sol`）。

在 Moonwell/Morpho Blue 攻击中，第三层我们已经彻底拆解。现在让我们深入前两层，然后讨论它们如何协同工作。

---

## 第一层：链下监控系统——"眼睛"

### 1.1 核心挑战：在海量数据中发现异常

Base 链大约每 2 秒出一个区块。每个区块包含几十到几百笔交易，每笔交易可能触发数十个事件。Searcher 需要在这洪流中实时捕捉到"wrsETH 预言机价格偏离了 1657 倍"这样的异常。这不是人工能做到的事情，必须依赖自动化系统。

### 1.2 数据源层

监控系统的第一步是建立可靠的数据管道。典型架构如下：

```
                    ┌─────────────────────────────────────┐
                    │         数据源层 (Data Sources)      │
                    ├─────────────────────────────────────┤
                    │                                     │
  ┌──────────┐      │  ┌──────────┐    ┌──────────────┐   │
  │ 全节点    │────▶│  │ WebSocket│    │ Mempool 订阅 │   │
  │ (Geth/   │      │  │ newHeads │    │ pending txs  │   │
  │  Reth)   │      │  └──────────┘    └──────────────┘   │
  └──────────┘      │                                     │
                    │  ┌──────────┐    ┌──────────────┐   │
  ┌──────────┐      │  │ Event    │    │ Trace API    │   │
  │ Archive  │────▶│  │ Logs 订阅 │    │ (debug_trace)│   │
  │ Node     │      │  └──────────┘    └──────────────┘   │
  └──────────┘      │                                     │
                    └─────────────────────────────────────┘
```

对于预言机攻击这个特定场景，Searcher 最关键的数据源是 **Chainlink 预言机的价格更新事件**。每当 Chainlink 聚合器更新价格，会发出 `AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)` 事件。Searcher 需要订阅所有相关预言机的这个事件。

但光监控事件不够。Moonwell 攻击的机会窗口是由 **预言机价格与真实市场价格的偏差** 创造的。所以 Searcher 还需要一个"真实价格"参照系——通常来自 DEX 的链上价格（通过 `getReserves()` 或 `slot0()` 实时计算）或者中心化交易所的 API feed。

### 1.3 监控逻辑的核心：偏差检测

用伪代码表达这个 Searcher 的预言机监控逻辑：

```python
# 预言机偏差监控器 — 核心循环
# 这不是逐行可运行的代码，而是展示架构思路的伪代码

class OracleDeviationMonitor:
    def __init__(self):
        # 需要监控的借贷市场配置
        # 每个市场对应: 抵押品代币、预言机地址、借贷池、DEX 出口
        self.markets = load_market_configs("moonwell_base.json")
        
        # 价格偏差阈值 — 超过此值就触发详细评估
        # 具体阈值取决于 collateral factor、借款量、DEX 滑点和 gas 成本
        # 这里用 1.5 只是示意，实际需要根据每个市场的参数单独计算
        self.deviation_threshold = 1.5
    
    async def on_new_block(self, block):
        """每个新区块触发一次全量检查"""
        for market in self.markets:
            # Step 1: 读取 Chainlink 预言机的当前报价
            oracle_price = await self.read_oracle_price(market.oracle_address)
            
            # Step 2: 从 DEX 池子计算真实市场价格
            # (通过 getReserves 或 slot0 + sqrtPriceX96 计算)
            dex_price = await self.calc_dex_price(market.dex_pool)
            
            # Step 3: 计算偏差倍数
            deviation = oracle_price / dex_price
            
            # Step 4: 偏差超过阈值 → 触发攻击评估
            if deviation > self.deviation_threshold:
                await self.evaluate_opportunity(market, oracle_price, dex_price, deviation)
    
    async def evaluate_opportunity(self, market, oracle_price, dex_price, deviation):
        """评估攻击机会的可行性和利润"""
        # 1. 查询所有可攻击的借贷市场的可借流动性
        borrowable = await self.scan_borrowable_liquidity(market)
        
        # 2. 查询 DEX 出口流动性 (能把借来的资产换成多少 ETH)
        exit_liquidity = await self.estimate_dex_output(borrowable, market.dex_routes)
        
        # 3. 计算闪贷成本 (本金 + 手续费)
        flash_cost = self.calc_flash_loan_cost(market)
        
        # 4. 估算 gas 成本
        gas_cost = self.estimate_gas_cost()
        
        # 5. 计算净利润
        estimated_profit = exit_liquidity - flash_cost - gas_cost
        
        if estimated_profit > self.min_profit_threshold:
            # 🚨 触发攻击！
            await self.trigger_attack(market, borrowable, estimated_profit)
```

注意这里有一个关键的设计决策：**是逐区块轮询还是事件驱动？** 对于 Moonwell 攻击这种预言机偏差场景，两种方式通常结合使用。事件驱动（订阅 `AnswerUpdated`）能在价格更新的瞬间触发检测，而逐区块轮询确保不会遗漏任何状态变化。在本案例中，攻击者 10/11 部署合约，10/17 首次出手（2 笔交易，包括一笔 Morpho Blue 攻击获利 0.141 ETH），11/03 再次小规模出手（tBTC 市场获利 0.181 ETH），11/04 才发起主攻（12 笔交易，净赚 ~295 ETH）。这 24 天的时间跨度 [推断] 说明监控系统一直在后台持续运行，在小偏差时小规模试探，最终在 11/04 wrsETH 出现 1657 倍偏差时全力出击。

### 1.4 扫描可借流动性

发现价格偏差后，Searcher 需要快速回答一个问题：**从哪些市场借多少钱最赚？** 这就是攻击者分 15 笔交易（11/04 主攻 12 笔 + 10/17 的 2 笔 + 11/03 的 1 笔）、覆盖 8 个市场（7 个 Moonwell + 1 个 Morpho Blue）的原因。Searcher 的流动性扫描器需要做以下计算：

对于每个借贷市场，查询可借流动性和对应 DEX 池的流动性深度。以 Moonwell 为例，查询 mToken 的 `getCash()`（合约持有的底层资产余额），再结合 `borrowCap`（借款上限）和 `borrowGuardianPaused`（借款开关）等 Comptroller 参数，才能得到真实的可借量。如果某个市场有 10 万 USDC 可借，但 DEX 上 USDC/WETH 池只能承接 5 万 USDC 的卖出而不造成严重滑点，那么实际可利用的只有 5 万。攻击者需要同时考虑这两个约束。

这解释了为什么 wstETH 被攻击了 4 笔而 cbXRP 只有 1 笔——wstETH 市场的 TVL 更高且 DEX 出口流动性更充裕。

---

## 第二层：策略引擎与 Calldata 生成器——"大脑"

### 2.1 策略引擎：从机会到执行计划

当监控系统检测到机会并完成初步评估后，策略引擎需要生成一份精确的"执行计划"。以 11/04 主攻的 12 笔 Moonwell 交易为例：

```
执行计划 (11/04 Moonwell 主攻, 12 笔交易):
├── TX_01: 闪贷 ~0.00065 wrsETH → 抵押 → 从 mcbXRP 借 12,057 cbXRP
│          → cbXRP/WETH swap (Algebra) → WETH/wrsETH swap (UniV3) → 还贷 → 利润提取
├── TX_02: 闪贷 → 从 mEURC 借 79,460 EURC → EURC/WETH swap → ...
├── ...
└── TX_12: 闪贷 → 从 mAERO 借 101,128 AERO → AERO/WETH swap → ...
```

策略引擎需要解决的核心优化问题是：**在多个市场和多条 DEX 路由之间分配借款金额，使总利润最大化。** 这是一个约束优化问题——每个市场的可借量是上限约束，每个 DEX 池的流动性深度决定了滑点曲线，而闪贷手续费和 gas 是固定成本。

### 2.2 利润模拟：链下 EVM 预执行

策略引擎中最关键的组件是 **利润模拟器**。在将交易提交到链上之前，Searcher 必须在本地精确模拟执行结果，确认交易会盈利。这通常通过以下方式实现：

**方式 A：本地 fork 模拟。** 在本地运行一个 EVM 实例（如 Anvil、Revm），fork 最新区块状态，然后在上面执行构建好的 calldata。如果模拟结果显示利润为正，才提交到链上。Foundry 的 fork 测试本质上就是这个流程的手动版本。

**方式 B：纯数学模拟。** 对于简单的 V2/V3 swap 路径，可以用 AMM 公式直接计算输出量，不需要启动 EVM。这比方式 A 快 10-100 倍，但不能处理复杂的协议交互（如 Moonwell 的 borrow + enterMarkets）。

在 Moonwell 攻击场景中，Searcher 大概率使用了某种形式的 EVM 模拟（方式 A 或其变体，如 Revm 内嵌轻量模拟），因为攻击涉及 Moonwell 的复杂借贷逻辑（mint → enterMarkets → borrow 需要 Comptroller 的 borrowAllowed 检查，包含预言机价格查询和抵押率计算），这些多步骤的协议交互难以用纯数学公式准确建模。但这是基于攻击复杂度的推断，我们没有链上证据能确认链下具体使用了哪种模拟方案。

### 2.3 Calldata 生成器：从执行计划到字节流

这是整个系统中最体现工程能力的环节。我们在逆向分析中已经知道（参见 `moonwell_exploit_reverse_analysis/0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB/reports/calldata_format.md`），11/04 的 12 笔 Moonwell 攻击交易使用同一个 932 字节的 calldata 模板，仅替换 5 个字段（共 73 字节）。Morpho Blue 攻击使用不同的模板（1252 字节），通过 `CALL_WITH_AMOUNT` 的 trail=96 机制适配 Morpho 的 `supplyCollateral` ABI。这意味着 Searcher 有一个 **模板化的 calldata 构建系统**，针对不同协议维护不同模板。

让我用伪代码展示 Moonwell 模板的构建过程（不是可运行代码，仅展示架构思路）：

```python
class CalldataBuilder:
    """
    将高层攻击策略编译为 AttackContract 指令引擎可执行的字节流。
    
    这个类本质上是 AttackContract 指令集的「汇编器」——
    就像 x86 汇编器将 MOV/ADD 指令翻译为机器码一样，
    它将 FLASH/BORROW/SWAP 操作翻译为 0x01/0x09/0x0a 操作码。
    """
    
    def build_moonwell_attack(self, params: AttackParams) -> bytes:
        """
        构建完整的 932 字节 calldata。
        
        params 包含 5 个可变字段:
        - flash_amount:    闪贷 wrsETH 数量 (7 字节)
        - mtoken_address:  目标 mToken 地址 (20 字节)
        - borrow_amount:   借款金额 (6 字节)
        - asset_address:   底层资产地址 (20 字节)
        - dex_pool:        DEX 出口池地址 (20 字节)
        """
        
        # ═══ 指令集 1: 闪贷 + 借贷 + swap 还贷 (600 字节) ═══
        instructions_1 = bytearray()
        
        # 指令 #1: V3_SWAP flag=1 (闪贷模式)
        # 从 CLPool 闪贷极小量的 wrsETH
        instructions_1 += self.encode_v3_flash(
            pool=CLPOOL_ADDRESS,                    # 固定: Aerodrome CLPool
            amount=params.flash_amount,             # ★可变★
            direction=1                             # dir=1: 借 token1 (wrsETH)
        )
        
        # 以下指令在闪贷回调中执行:
        
        # 指令 #2: BALANCE_OF — 获取闪贷到账的 wrsETH 数量
        instructions_1 += self.encode_balance_of(WRSETH_ADDRESS)
        
        # 指令 #3: RAW_CALL — wrsETH.approve(mwrsETH, 0) 清零旧授权
        instructions_1 += self.encode_raw_call(
            target=WRSETH_ADDRESS,
            calldata=encode_approve(params.mtoken_address, 0)
        )
        
        # 指令 #4: CALL_WITH_AMOUNT — wrsETH.approve(mwrsETH, amount)
        instructions_1 += self.encode_call_with_amount(
            target=WRSETH_ADDRESS,
            prefix=encode_approve_prefix(params.mtoken_address)
        )
        
        # 指令 #5: CALL_WITH_AMOUNT — mwrsETH.mint(amount) 存入抵押品
        instructions_1 += self.encode_call_with_amount(
            target=params.mtoken_address,           # ★可变★
            prefix=MINT_SELECTOR                    # 0xa0712d68
        )
        
        # 指令 #6: RAW_CALL — Unitroller.enterMarkets([mwrsETH])
        instructions_1 += self.encode_raw_call(
            target=UNITROLLER_ADDRESS,
            calldata=encode_enter_markets(MWRSETH_ADDRESS)
        )
        
        # 指令 #7: RAW_CALL — mToken.borrow(amount)
        # 这一步利用预言机错误价格，超额借出真实资产
        instructions_1 += self.encode_raw_call(
            target=params.mtoken_address,           # ★可变★
            calldata=encode_borrow(params.borrow_amount)  # ★可变★
        )
        
        # 指令 #8: BALANCE_OF — 获取借到的资产数量
        instructions_1 += self.encode_balance_of(params.asset_address)  # ★可变★
        
        # 指令 #9: V3_SWAP — 借到的资产 → WETH
        instructions_1 += self.encode_v3_swap(
            pool=params.dex_pool,                   # ★可变★
            direction=0                             # 卖资产买 WETH
        )
        
        # 指令 #10: BALANCE_OF — 获取 WETH 数量
        instructions_1 += self.encode_balance_of(WETH_ADDRESS)
        
        # 指令 #11: V3_SWAP — WETH → wrsETH (用于闪贷归还)
        instructions_1 += self.encode_v3_swap(
            pool=WRSETH_WETH_POOL,                  # 固定: UniV3 wrsETH/WETH
            direction=1
        )
        # (闪贷回调结束时自动归还 flashAmount + fee)
        
        # ═══ 指令集 2: 利润提取 (77 字节) ═══
        instructions_2 = bytearray()
        
        # 指令 #12: BALANCE_OF — 获取剩余 wrsETH
        instructions_2 += self.encode_balance_of(WRSETH_ADDRESS)
        
        # 指令 #13: V3_SWAP — 剩余 wrsETH → WETH (利润)
        instructions_2 += self.encode_v3_swap(
            pool=WRSETH_WETH_POOL,
            direction=0
        )
        
        # ═══ 组装最终 calldata ═══
        return self.wrap_as_approve_call(instructions_1, instructions_2)
    
    def encode_v3_flash(self, pool, amount, direction) -> bytes:
        """
        编码 V3_SWAP 操作码的闪贷模式 (flag=1)。
        格式: [0x01][flag=0x01][pool:20B][amount:32B][dir:1B][cb:1B][d:1B]
        总长: 57B (cb=0 时有 d 字段) 或 56B (cb=1 时无 d 字段)

        关键语义:
        - cb=0: 后续指令在闪贷回调中执行（闪贷模式的核心）
        - cb=1: 普通 swap，使用合约自身作为回调接收方
        - d: 仅在 cb=0 时存在，含义待确认（观测值均为 0）
        """
        result = bytearray()
        result.append(0x01)                          # 操作码: V3_SWAP
        result.append(0x01)                          # flag=1: 调用 pool.flash() 而非 pool.swap()
        result += bytes.fromhex(pool[2:])            # 池地址 (20 字节)
        result += amount.to_bytes(32, 'big')         # 闪贷金额 (32 字节)
        result.append(direction)                     # 方向: 0=token1→token0, 1=token0→token1
        result.append(0x00)                          # cb=0: 后续指令在回调中执行
        result.append(0x00)                          # d=0: 保留字段
        return bytes(result)                         # 共 57 字节
    
    def wrap_as_approve_call(self, inst1, inst2) -> bytes:
        """
        将两个指令集包装为以 approve selector (0x095ea7b3) 开头的 calldata。

        注意: 这不是标准的 approve(address,uint256) ABI 编码。
        AttackContract 借用 approve 的 4 字节 selector 作为入口，但后面跟的是
        完全自定义的布局: 5 个 32 字节 word 的 header（包含两段指令数据
        的 offset 和 length），加上两段变长的紧密打包指令字节流。
        从外部看像一笔 approve 调用，实际是向指令引擎传入执行载荷。
        """
        selector = bytes.fromhex("095ea7b3")
        # header: 5 × 32B words (地址槽、数值槽、inst1 offset、inst2 offset、长度等)
        header = build_custom_header(inst1, inst2)
        return selector + header + inst1 + inst2
```

这个构建系统的精妙之处在于它的 **模板化**。以 Moonwell 攻击为例，攻击者只需要修改 5 个参数就能生成针对不同市场的完整 calldata——12 笔交易的 calldata 差异仅 73 字节（占 932 字节总长的 7.8%），其余 859 字节完全相同（参见 `moonwell_exploit_reverse_analysis/0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB/reports/calldata_format.md`）。

### 2.4 交易排序与提交策略

生成 calldata 后，下一个问题是：**如何确保这些交易被链上优先执行？**

AttackContract 在 11/04 的 12 笔交易是"快速连续提交"的。虽然 Base 链（L2）使用中心化排序器（Sequencer），但这并不意味着不存在 MEV 竞争。链上数据证明了这一点：TX_01 的 priority fee 为 ~235 gwei，是同区块内其他交易中位数（0.001 gwei）的 **235,196 倍**，是区块内第二高交易的 6.7 倍。如果 Base 真的是纯 FIFO 排序，攻击者完全没必要支付这种溢价。实际上 Sequencer 会参考 gas price 进行优先级判断，L2 上同样存在交易排序竞争。

**Nonce 管理。** 多笔交易必须使用连续递增的 nonce。从链上数据看，TX_01 的 nonce 是 59（攻击者 EOA 此前已有其他交易活动），12 笔主攻交易使用 nonce 59-70。如果中间某笔 revert，后续交易会全部卡住。不过 AttackContract 的利润保证机制（`require(postBalance > preBalance)`）确保了失败的交易只是不执行，不会造成资金损失。

**Gas 价格策略。** 即使在 L2 上，Searcher 也需要设置远超正常水平的 gas price 来确保排序器优先处理（AttackContract 的 175-253 gwei 对比正常水平的 ~0.04 gwei）。在 L1 上竞争更加激烈——AttackContract 在 Ethereum 主网的攻击中向 Titan Builder 支付了 43.82 ETH 的 builder tip（~$196,651），通过 `block.coinbase` 直接转账而非 gas price 竞价。

**竞争时间窗口。** 预言机偏差本身可能持续数小时（本案例中 wrsETH 偏差在 11/04 05:44 UTC 达到约 1657 倍，偏差起始时间和演变过程无链上直接证据），但 Searcher 面临的真正时间压力来自**与其他 Searcher 的竞争**——一旦异常被多方发现，可借流动性会被迅速消耗。因此，从检测到偏差到完成交易提交的管道——检测偏差 → 计算最优策略 → 生成多份 calldata → 提交交易——仍需要尽可能快地完成（秒级）。这就是为什么大部分计算需要提前准备（如模板预编译、路由预计算），只在最后关头填入动态参数。

---

## 第三层回顾：链上执行引擎

这一层我们已经深度分析过了。但从系统架构的角度，值得强调几个设计决策为什么对 Searcher 至关重要：

**为什么用自定义指令集而不是直接写 Solidity？** 因为通用性。如果攻击者为每个目标协议写一份合约，他需要为 Moonwell 写一份、为 Aave 写一份、为 Compound 写一份……每份都需要审计、测试、部署。而自定义指令集只需要一次部署，之后所有逻辑都在 calldata 中编码。新协议出现时，只需要在链下构建器中添加新模板，链上合约完全不变。

**为什么支持多种闪贷回调？** 因为流动性碎片化。在不同链上，最便宜或流动性最好的闪贷来源不同。在 Base 上可能是 Aerodrome CLPool，在 Ethereum 上可能是 Aave V3 或 Balancer。该合约拥有 45 个 dispatch selector，覆盖了 UniV3、Algebra、PancakeV3、Solidly 等主流 DEX 协议的闪贷和 swap 回调签名，同时支持 V2 Flash Swap（通过 opcode 0x00 的 flag&1 触发）和多种闪电贷协议（Aave V3、Balancer、Morpho Blue、Euler V2），确保在任何链上都能找到最优的闪贷入口（参见 `moonwell_exploit_reverse_analysis/moonwell_exploit_reverse_report.md` 5.2-5.3 节）。

**为什么合约部署后 6 天才首次出手？** 这表明 AttackContract 是一个「常备基础设施」而非一次性攻击工具。攻击者 10/11 部署合约，10/17 首次出手——一笔失败的 VIRTUAL 市场攻击（TX_FAIL）和一笔成功的 Morpho Blue weETH 攻击（TX_SUCCESS，获利 0.141 ETH）。之后又等了 18 天，直到 11/04 wrsETH 出现 1657 倍偏差时才全力发起 12 笔主攻。这种节奏 [推断] 说明链下监控系统持续运行，攻击者会根据偏差幅度和利润空间判断是否值得出手。

---

## 完整系统协同：攻击时间线重建

现在让我们把三层系统串起来，基于链上证据重建攻击的完整时间线。以下时间线中，带 `[链上]` 标记的事件有链上数据支撑，带 `[推断]` 标记的事件是根据链上行为推断的链下系统行为。

以下所有时间均为 UTC（通过 `cast block <number> --field timestamp` 链上验证）。

```
2025-10-11 07:55 UTC [链上]:
  AttackContract 合约部署到 Base 链 (block 36,689,996)

2025-10-17 [链上]:
  06:58 UTC — TX_FAIL (block 36,947,486): VIRTUAL 市场攻击 — 失败，gas 消耗 1,063,299
  08:04 UTC — TX_SUCCESS (block 36,949,468): Morpho Blue weETH 攻击 — 成功，获利 0.141 ETH
  [推断] 监控系统检测到 weETH 预言机 ~9% 偏差，触发攻击
  [推断] 同时尝试了 VIRTUAL 市场但因未知原因失败（可能是预言机偏差不足或池子流动性不够）

2025-11-03 18:03 UTC [链上]:
  TX_NEW (block 37,701,831): Moonwell tBTC 攻击 — 成功，获利 0.181 ETH
  [推断] 攻击者检测到 tBTC 市场存在可利用的预言机偏差（偏差幅度未验证，从 0.181 ETH 的微小利润推断偏差不大），小规模出手

2025-11-04 05:44 UTC [链上] — 主攻:

  [推断] 此前某个区块，Chainlink wrsETH 预言机返回错误价格
        → 偏差约 1657 倍（wrsETH 报价约 $5,800,000 vs 实际 ~$3,500）

  [推断] 监控系统检测到偏差 → 触发全量攻击评估
        1. 扫描 7 个 Moonwell 市场的可借流动性
        2. 查询对应 DEX 池的出口流动性
        3. 计算最优分配: wstETH×4, cbETH×2, EURC×2, USDC×1, AERO×2, cbXRP×1
        4. EVM 模拟验证利润 → 估算 ~300 ETH

  [推断] Calldata 生成器从模板生成 12 份 calldata (每份仅替换 73 字节)
        设置 nonce 59-70, gas price 175-253 gwei, msg.value (反重放)

  [链上] TX_01 (block 37,722,875, nonce=59, 05:44:57 UTC):
        approve(0x0, 0) + 932B payload
          → 指令集 1 (calldata offset 0x64): 闪贷 ~0.00065 wrsETH
            → 回调内: approve → mint → enterMarkets → borrow 12,057 cbXRP
            → swap cbXRP→WETH (Algebra) → swap WETH→wrsETH (UniV3) → 还贷
          → 指令集 2 (calldata offset 0x84): swap 剩余 wrsETH→WETH (利润提取)
          → WETH.withdraw → require(profit > 0) ✓
          → sendETH(0x6997..., 30.79 ETH)
        Gas: 1,638,462, priority fee ~235 gwei (同区块中位数的 235,196 倍)

  [链上] TX_02-TX_12: 同上，不同市场和参数，12 笔主攻交易全部成功

[链上] 最终统计:
  毛利润: 300.49 ETH (~$1.08M)
  Gas 成本: 4.74 ETH
  净提取: 295.75 ETH (~$1.06M, 11/04 @$3,600.72)
  攻击者 EOA 0x6997...58ff 将 295.7528 ETH 转出至 0x733EDE...06Ce
```

---

## 从零构建这套系统需要什么？

如果一个开发者想从零构建类似的 Searcher 系统，需要以下能力和组件：

**Solidity 和 EVM 深度理解。** 不是"会写合约"的水平，而是理解 calldata 编码、内存布局、gas 计费模型、跨合约调用机制等底层细节。AttackContract 的紧密打包编码和 assembly 操作都需要这种深度。

**链下基础设施开发能力。** 通常用 Rust（性能）或 Python（快速原型）构建。需要：WebSocket 连接管理、事件解析、状态缓存、并发交易提交。开源项目如 Paradigm 的 [Artemis](https://github.com/paradigmxyz/artemis) 框架提供了很好的起点——它封装了 collector（数据收集）、strategy（策略逻辑）、executor（交易提交）的三层架构。

**DeFi 协议的深度知识。** 不仅要理解 Uniswap/Aave 等协议的接口，更要理解它们的内部状态机。比如 Moonwell 的 `borrowAllowed()` 会查询 Comptroller 中的预言机价格、抵押率、借款上限等——这些细节决定了攻击参数的计算方式。

**实时模拟能力。** 需要在本地运行 EVM 实例（Anvil/Revm），能在毫秒级完成交易模拟。这是区分"发现机会"和"成功执行"的关键——如果模拟太慢，机会会被更快的 Searcher 抢走。

**运维与监控。** 生产级的 Searcher 系统需要 24/7 运行，带报警、自动重启、利润追踪、gas 费监控等。AttackContract 合约中的 `tryAggregate()`（批量查询）和 `ops()`（批量 gas 分发，选择器 `0x725f071c`）就是为运维场景设计的。

---

## 建议学习路径

如果你是第一次接触 MEV，面对上述系统架构可能感到无从下手。以下是一个从具体到抽象的渐进路径：

**第一步：观察链上活动。** 用 ethers.js 监听 mempool 中的 pending 交易（本教程第 2 篇的动手环节），直观感受交易流的速度和 gas 竞争的激烈程度。

**第二步：重放一笔真实攻击。** 用 Foundry 的 fork 测试重放 AttackContract 的 TX_01（参见 `moonwell_exploit_reverse_analysis/AttackContract/test/ReplayMevBot.t.sol`），亲手验证一笔攻击交易如何从闪贷到获利。

**第三步：解码一笔攻击交易的 calldata。** 用 `cast` 获取 TX_01 的 calldata，对照 `moonwell_exploit_reverse_analysis/0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB/reports/calldata_format.md` 中的操作码表手动解码，理解指令引擎如何将字节流翻译为链上操作。

**第四步：阅读开源参照。** 研读 Lotus Router 源码（`reference/lotus-router/`），理解一个"正向设计"的 Calldata 驱动 VM 是如何组织的，再与 AttackContract 的"逆向重建"做对比。

**第五步：构建最小链下系统。** 从一个预言机价格轮询脚本开始（参考本文 1.3 节的伪代码），逐步添加偏差检测、利润估算、交易提交等模块。开源框架 Artemis（Paradigm）提供了 collector → strategy → executor 的三层脚手架。

每一步都有本教程系列对应章节的真实数据和代码可供验证，不需要凭空想象。
