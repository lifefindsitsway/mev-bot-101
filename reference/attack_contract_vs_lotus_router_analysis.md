# AttackContract 与 Lotus Router 开源项目的关系分析

> **分析对象**：AttackContract（`0x42Ecd332` Base 链 + `0xA98E339f` 几乎所有主要公链，经字节码同一性验证确认为同一份源码的不同部署）与开源项目 Lotus Router (`lotus-router/`)
>
> **结论**：AttackContract 极大概率与 Lotus Router **同源**——共享同一核心架构范式，分别向不同方向演化。

---

## 一、BigBrainChad.eth — 技术谱系的源头

### 1.1 身份与链上足迹

**bigbrainchad.eth** 是一个以太坊 ENS 域名，对应地址 `0xd215ffaf0f85fb6f93f11e49bd6175ad58af0dfd`。它是以太坊上一个知名的**通用型 MEV 搜索者（generalized searcher）**——不局限于简单的 DEX 套利，还能自动发现并利用智能合约漏洞。

| 维度 | 详情 |
|---|---|
| ENS | bigbrainchad.eth |
| EOA 地址 | `0xd215ffaf0f85fb6f93f11e49bd6175ad58af0dfd` |
| Bot 合约 | `0xd129d8c12f0e7aa51157d9e6cc3f7ece2dc84ecd`（Etherscan 标记 "MEV Bot"） |
| Bot 合约 2 | `0xbeefbabeea323f07c59926295205d3b7a17e8638`（地址本身以 0xBEEF 开头） |
| 类型 | 通用型 MEV 搜索者（generalized searcher） |
| 能力 | DEX 套利 + 自动漏洞利用 |

### 1.2 标志性特征：0xBEEF 交易哈希

bigbrainchad.eth 最引人注目的特征是：**所有交易的哈希值都以 `0xbeef` 开头**。

在以太坊中，交易哈希是 keccak256 计算的结果，理论上随机分布。要让哈希以特定 4 字节前缀开头，概率为 1/2^32（约 43 亿分之一），需要不断调整交易参数（nonce、gas price 等）进行暴力搜索——这本身就消耗大量计算资源，纯粹是为了炫技。Flashbots 核心成员 **Bert Miller** 对此评价：

> *"Never seen anything like that before."*

这种刻意的炫耀行为被观察者称为 **"cryptographic performance art"（密码学行为艺术）**。

### 1.3 成名事件：12 秒清空新合约（2024.09.11）

2024 年 9 月 11 日，bigbrainchad.eth 在一起事件中一战成名：

- 一个名为 **INUMI** 的代币合约刚刚部署，包含 5 ETH（约 $12,000）
- 该合约存在**访问控制漏洞**
- bigbrainchad.eth 的 bot 在**下一个区块**（部署后仅 **12 秒**）就自动检测到漏洞并发起攻击，清空全部资金
- 攻击交易哈希：`0xbeef352f716973043236f73dd5104b9d905fd04b7fc58d9958ac5462e7e3dbc1`（一如既往以 0xbeef 开头）

安全工具 Fuzzland 联合创始人 **Chaofan Shou** 评论：

> *"Someone just lost 5ETH because of an access control issue – a backrun bot hacked it in less than 12s after deployment."*

此事被 Protos 报道，标题即为 "'Cryptographic performance art' drains contract one block after launch"。

### 1.4 BBC 编码方案（Big Brain Chad Encoding）

bigbrainchad.eth 对 MEV 社区最重要的技术贡献在于其开创的 **calldata 紧凑编码方案**，后被 Lotus Router 项目正式命名为 **BBC 编码（Big Brain Chad encoding）**。

**问题背景**：标准 Solidity ABI 编码将所有参数填充到 32 字节（256 位），产生大量前导零。虽然 EVM 对零字节仅收 4 gas（非零字节 16 gas），但多余的零填充仍然增加 calldata 体积和总 gas 消耗——尤其在 L2 上，calldata 是交易成本的主要来源。

**BBC 编码规则**：

| 参数类型 | 标准 ABI | BBC 编码 | 节省 |
|---|---|---|---|
| bool / uint8（≤8 位） | 32 字节 | **1 字节原位** | 31 字节 |
| address / uint256（9-256 位） | 32 字节 | **1 字节长度前缀 + 实际字节数** | 视数值大小 |
| bytes（动态长度） | 32+32+data 字节 | **4 字节长度前缀 + data** | ~60 字节 |

编码示例：
```
标准 ABI:  0x000000000000000000000000000000000000000000000000000000000000beef  (32 bytes)
BBC 编码:  0x 02 beef                                                          (3 bytes, 节省 90.6%)

标准 ABI:  0x0000000000000000000000001234567890abcdef1234567890abcdef12345678  (32 bytes)
BBC 编码:  0x 14 1234567890abcdef1234567890abcdef12345678                      (21 bytes, 节省 34.4%)
```

整体压缩率约 **77%**（相比标准 ABI 编码），对 gas 敏感的 MEV 场景意义重大。

### 1.5 与 Lotus Router 的关系

Lotus Router 的 `BBCDecoder.sol` 开头注释明确记载了编码方案的来源：

> *"Inspired by the calldata schema of BigBrainChad.eth"*

Lotus Router 开发者 **jtriley2p**（jtriley.eth）在开源该项目后不久，遭到**前雇主的版权投诉**，指控其盗用公司商业秘密完成路由器合约的开发。GitHub 仓库于约 **2025 年 3 月**被删除。jtriley2p 以 Manifesto 回应，强调技术自由和开源精神，并将代码通过 IPFS 永久保存（`bafkreif2ffb2kghamkdjp5pcgrsxu26hx42w3imujcq6zeqacwzsg5pbla`）。

这段版权争议暗示：BBC 编码方案和嵌入式 VM 架构可能最初诞生于某个 MEV 团队/公司的内部项目，而非公开发表的学术成果。bigbrainchad.eth 可能是该团队的核心成员（或就是同一人），其链上 bot 是这套架构的最早实践者。

### 1.6 信息来源

- [Protos: 'Cryptographic performance art' drains contract one block after launch](https://protos.com/cryptographic-performance-art-drains-contract-one-block-after-launch/)
- [Wong's Blog: 从零开始的聚合器开发: Lotus Router 合约解析](https://blog.wssh.dev/posts/lotus-router)
- [Etherscan: bigbrainchad.eth](https://etherscan.io/address/0xd215ffaf0f85fb6f93f11e49bd6175ad58af0dfd)
- [Etherscan: MEV Bot 0xd12...ecd](https://etherscan.io/address/0xd129d8c12f0e7aa51157d9e6cc3f7ece2dc84ecd)
- [jtriley.eth Substack](https://jtriley.substack.com/)

---

## 二、Lotus Router 项目概览（由 jtriley2p 开源）

**Lotus Router** 是一个开源 DeFi 路由器合约，自称 "Nameless Researchers and Developers of Ethereum" 所作，采用 AGPL-3.0 许可证。

核心特征：
- **Solidity 0.8.28**，使用 `via-IR` 编译
- **无状态**：无 storage 变量，纯执行引擎
- **Fallback 驱动**：所有逻辑在 `fallback() external payable` 中
- **嵌入式虚拟机**：12 个 opcode（0x00-0x0b），while 循环逐条解释执行
- **BBC 编码**（Big Brain Chad encoding）：自定义紧凑 calldata 格式，~77% 压缩率
- **4 个入口点**：`takeAction` (0x19ff8034)、`uniswapV2Call` (0x10d1e85c)、`uniswapV3SwapCallback` (0xfa461e33)、`uniswapV3FlashCallback` (0xe9cbafb0)

### Lotus Router Manifesto（源码注释）

```
I am the Lotus Router.
I exist for the individual. I exist for the collective.
I do not to extract value. I do not to capture rent.
I am a political statement, as all software is.
I am an act of defiance against hoarders of technology and capital.
I bear the license of free, as in cost AND freedom, software.
```

### 源码结构

```
src/
├── LotusRouter.sol          # 主合约 (218 行)
├── types/
│   ├── Action.sol           # 12 个 opcode 枚举
│   ├── BytesCalldata.sol    # calldata 指针类型
│   ├── Error.sol            # 错误定义
│   ├── PayloadPointer.sol   # 入口点路由 + 指针推进
│   └── protocols/
│       ├── UniV2Pair.sol    # UniV2 swap 封装
│       ├── UniV3Pool.sol    # UniV3 swap/flash 封装
│       ├── ERC20.sol        # transfer/transferFrom
│       ├── ERC721.sol       # NFT transferFrom
│       ├── ERC6909.sol      # 多代币 transfer
│       ├── WETH.sol         # deposit/withdraw
│       └── Dyn.sol          # 任意 call
└── util/
    ├── BBCEncoder.sol       # 编码器 (692 行)
    └── BBCDecoder.sol       # 解码器 (725 行)
```

---

## 三、架构层面的深度对比

### 3.1 核心执行模型 — 几乎相同

| 维度 | Lotus Router | AttackContract |
|---|---|---|
| 执行引擎 | `fallback()` 中的 while 循环 | `_execLoop()` 中的 while 循环 |
| 指令读取 | `ptr.nextAction()` → 1 字节 opcode | `uint8(instructions[cur])` → 1 字节 opcode |
| 指针推进 | `Ptr` 类型，逐字段 `add(ptr, len)` | `cur` 变量，逐字段 `cur += len` |
| 终止条件 | opcode == Halt (0x00) → `stop()` | cursor >= data.length（无显式 HALT opcode） |
| 错误处理 | `canFail` 布尔 → 允许静默失败 | 无 canFail（require 或忽略返回值） |
| 状态 | 无状态（无 storage） | 无状态（Storage 全零） |

两者都是**顺序指令解释器**——从紧凑编码的 calldata 中逐条读取 opcode + 参数，分派执行，循环直到终止。这是完全一致的架构范式。

**Lotus Router 执行循环**（`LotusRouter.sol:68-208`）：
```solidity
fallback() external payable {
    Ptr ptr = findPtr();
    Action action;
    bool success = true;
    while (success) {
        (ptr, action) = ptr.nextAction();
        if (action == Action.Halt) { assembly { stop() } }
        else if (action == Action.SwapUniV2) { /* decode + execute */ }
        else if (action == Action.SwapUniV3) { /* decode + execute */ }
        // ... 12 个 opcode 分支
    }
    revert Error.CallFailure();
}
```

**AttackContract 执行循环**（`AttackContract.sol:_execLoop()`）：
```solidity
function _execLoop(bytes calldata instructions) internal {
    uint256 cur = 0;
    uint256 amount;
    while (cur < instructions.length) {
        uint8 op = uint8(instructions[cur]); cur++;
        if (op == 0x00) { /* V2_SWAP / V2_FLASH */ }
        else if (op == 0x01) { /* V3_SWAP / V3_FLASH */ }
        else if (op == 0x09) { /* RAW_CALL */ }
        // ... 12 个 opcode 分支（0x00-0x0b）
    }
}
```

### 3.2 Opcode 映射 — 功能一一对应

| Lotus 名称 | Lotus 编号 | AttackContract 编号 | AttackContract 功能 | 对应关系 |
|---|---|---|---|---|
| Halt | 0x00 | — | 无显式 HALT（循环在数据耗尽时终止） | 设计差异 |
| SwapUniV2 | 0x01 | 0x00 | V2_SWAP / V2_FLASH | **功能相同**（+V2 Flash Swap） |
| SwapUniV3 | 0x02 | 0x01 (flag=0) | V3_SWAP — UniV3 swap | **功能相同** |
| FlashUniV3 | 0x03 | 0x01 (flag=1) | V3_FLASH — UniV3 flash loan | **合并为同一 opcode** |
| TransferERC20 | 0x04 | — | 无独立 transfer opcode（通过 RAW_CALL 实现） | 架构差异 |
| TransferFromERC20 | 0x05 | — | — | 无需（自有资金） |
| TransferFromERC721 | 0x06 | — | — | 无需 |
| TransferERC6909 | 0x07 | — | — | 无需 |
| TransferFromERC6909 | 0x08 | — | — | 无需 |
| DepositWETH | 0x09 | 0x03 | WETH_DEPOSIT | **功能相同**（+SELFBALANCE fallback） |
| WithdrawWETH | 0x0a | 0x04 | WETH_WITHDRAW | **功能相同** |
| DynCall | 0x0b | 0x09 / 0x0a / 0x0b | RAW_CALL / CALL_WITH_AMT / CALL_WITH_CHECK | **分拆为三个变体** |

**12 个 Lotus opcode 中有 6 个在 AttackContract 中有直接功能对应**（SwapUniV2、SwapUniV3、FlashUniV3、DepositWETH、WithdrawWETH、DynCall），其中 SwapUniV3+FlashUniV3 被合并为一个带 flag 的 opcode，DynCall 被分拆为三个变体。

其余 6 个被移除或以不同方式实现：Halt 由循环终止条件替代，TransferERC20 通过通用的 RAW_CALL 实现，TransferFromERC20/TransferFromERC721/TransferERC6909/TransferFromERC6909 对 MEV bot 场景无意义（攻击合约操作自有资金，不需要 transferFrom）。

AttackContract **新增**的 opcode：

| 编号 | 功能 | 用途 |
|---|---|---|
| 0x02 | FLASH_LOAN_INITIATE | 发起闪电贷（Balancer/AaveV3/EulerV2），退出循环后剩余字节作为 callback data |
| 0x05 | REGISTER_COPY | 寄存器拷贝（amount = secondaryRegister） |
| 0x06 | SET_OR_MIN | value(32)+flag(1)，flag=0: 无条件设置; flag=1: min(amount, value) |
| 0x07 | BALANCE_OF | 读取指定 token 余额到 amount 寄存器 |
| 0x08 | SUB_BALANCE | 从 amount 寄存器减去指定 token 余额 |

这些新增 opcode 为支持**借贷协议交互**和**金额动态管理**所需——余额查询、金额计算、闪电贷发起，是 Lotus 纯 DEX 路由器不具备的能力。

### 3.3 回调路由 — 同一思路，大幅扩展

| 维度 | Lotus Router | AttackContract |
|---|---|---|
| 入口数量 | 4 个 selector | 42 个函数（对应 45 个 dispatch 入口） |
| 支持协议 | UniV2, UniV3 | UniV2/V3, Balancer, iZiSwap, PancakeV3, Algebra, Moonwell, Morpho, AAVE, Euler 等 18+ 协议 |
| 路由机制 | `findPtr()` 按 selector 分派，定位 payload 偏移 | 按参数类型分派：`_handleUintCb`（flash）/ `_handleIntCb`（swap） |
| 核心模式 | **回调中重新进入执行引擎** | **回调中重新进入执行引擎** |

**Lotus `findPtr()` 实现**（`PayloadPointer.sol:34-48`）：
```solidity
function findPtr() pure returns (Ptr) {
    uint256 selector = uint256(uint32(msg.sig));
    if (selector == takeAction)              return Ptr.wrap(0x04);
    else if (selector == uniswapV2Call)      return Ptr.wrap(0xa4);
    else if (selector == uniswapV3SwapCallback) return Ptr.wrap(0x84);
    else if (selector == uniswapV3FlashCallback) return Ptr.wrap(0x84);
    else revert Error.UnexpectedEntryPoint();
}
```

AttackContract 的回调路由遵循完全相同的逻辑——回调函数不做业务逻辑，只负责从回调参数中提取嵌套的指令流，然后**重新进入执行引擎**。差异在于扩展到了 42 个函数覆盖 18+ DEX/借贷协议的回调，并按参数类型（`uint256` vs `int256`）而非协议名称分派。

### 3.4 编码方案 — 核心理念相同，实现有差异

**Lotus BBC 编码**（Big Brain Chad encoding）：
```
[1B action] [1B canFail] [1B byteLen₁] [N₁ bytes value₁] [1B byteLen₂] [N₂ bytes value₂] ...
```
- 每个 >8bit 参数前有 1 字节长度前缀
- 数值按实际字节长度紧凑存储（如 address 20B → byteLen=0x14 即 20 字节）
- ~77% 压缩率（vs 标准 ABI 编码）
- 灵感来自 `"BigBrainChad.eth"` 的 calldata schema（BBCDecoder.sol 注释自述）

**AttackContract 编码**：
```
[1B opcode] [固定长度参数: addr(20B) + uint256(32B) + flags(1B) ...]
```
- 固定宽度字段，无长度前缀
- 解码更简单——每个 opcode 的参数布局编译时确定
- gas 消耗更低（无需运行时读取/计算长度）
- 压缩率略低于 BBC，但对 MEV 场景而言 gas 节省更重要

**共同核心理念**：两者都**绕过 Solidity ABI 编码**，使用自定义紧凑格式直接从 calldata 读取参数，通过指针逐字段推进。

---

## 四、关键差异（AttackContract 的"进化"方向）

### 4.1 伪装入口

- **Lotus**：使用显式的 `takeAction(bytes)` 函数签名（selector 0x19ff8034），意图明确
- **AttackContract**：劫持 `approve(address,uint256)` selector (0x095ea7b3)，将攻击指令藏在看似标准 ERC20 授权调用的 calldata 中。链上浏览器显示为 "Approve" 操作

### 4.2 利润提取机制

- **Lotus**：完全没有利润分配逻辑，纯路由器
- **AttackContract** `approve()` 函数中实现了完整的利润循环：
  1. `preBalance = address(this).balance`
  2. 执行两组指令（攻击 + 利润转换）
  3. `WETH.withdraw(WETH.balanceOf(this))` — 全量提取 WETH
  4. `require(postBalance > preBalance)` — 利润校验
  5. `callerPayment` → `block.coinbase` (builder tip) 或指定地址
  6. 剩余 → `PROFIT_RECEIVER`

### 4.3 多协议深度

- **Lotus**：仅支持 DEX（UniV2/V3），是纯交换路由器
- **AttackContract**：增加了借贷协议操作，支持 Moonwell（Comptroller.enterMarkets → mToken.mint → mToken.borrow）和 Morpho Blue（supplyCollateral → borrow）的完整借贷流程

### 4.4 运维能力

- **Lotus**：无运维函数，一次性部署
- **AttackContract**：`0x725f071c` ops 函数实现批量 gas 分发到子 EOA 等运维操作

### 4.5 `amount` 传递寄存器

- **Lotus**：每个操作独立解码所有参数，操作间无隐式状态
- **AttackContract**：`amount` 变量在 opcode 间隐式传递（如 `BALANCE_OF` → amount → `CALL_WITH_AMT`），减少 calldata 冗余

### 4.6 编译器版本

- **Lotus**：Solidity 0.8.28，使用 `via-IR` 优化管线
- **AttackContract**：Solidity 0.8.15（经字节码 CBOR 元数据验证确认），cancun EVM，optimizer 200 runs，非 `via-IR`

---

## 五、判断依据

### 5.1 架构指纹高度吻合

fallback-driven execution loop + 1-byte opcode dispatch + pointer-based calldata parsing + callback re-entry pattern — 这 4 个架构特征的组合非常独特。在已知的 DeFi 合约中，这种 "嵌入式 VM" 模式极为罕见，不太可能独立进化出完全相同的架构。

### 5.2 Opcode 编号范围精确匹配

Lotus 和 AttackContract 恰好都是 **12 个 opcode**，范围 **0x00-0x0b**。在设计空间上，opcode 数量可以是任意值（8、16、24...），两者不约而同选择了完全相同的数量和范围，这不太可能是巧合。

### 5.3 特征性设计决策一致

- **DynCall（任意 call）放在高编号位**（Lotus=0x0b, AttackContract=0x09/0x0a/0x0b 三个变体）
- **UniV3 swap 和 flash** 在 Lotus 中分为两个独立 opcode (0x02, 0x03)，AttackContract **合并为一个带 flag 字段的 opcode** (0x01) — 这是典型的基于原始设计的**优化合并**
- **V2 swap 和 WETH deposit/withdraw** 功能完全对应，仅编号重新分配

### 5.4 进化方向合理且连贯

从 Lotus → AttackContract 的变化完全符合 "将通用路由器改造为 MEV 攻击引擎" 的需求：
- 删除无用 opcode（ERC721/ERC6909/TransferFrom）→ 腾出编号空间
- 增加金额管理和闪贷操作码（BALANCE_OF/SUB_BALANCE/SET_OR_MIN/FLASH_LOAN_INITIATE/REGISTER_COPY）→ 适应借贷攻击场景
- 从变长编码简化为固定宽度 → 降低解码 gas
- 增加 `amount` 寄存器 → 减少 calldata 冗余
- 将入口从 `takeAction` 改为 `approve` → 链上伪装
- 增加利润分配和 builder tip → MEV 必备

### 5.5 BBCDecoder 注释自述源头

`"Inspired by the calldata schema of BigBrainChad.eth"` — AttackContract 的编码方案同样可追溯到 BBC 系列的设计理念，只是从变长简化为固定宽度。

---

### 5.6 版权争议佐证内部起源

jtriley2p 开源 Lotus Router 后遭前雇主版权投诉，指控盗用商业秘密。这表明 BBC 编码方案和嵌入式 VM 架构最初是某 MEV 团队/公司的**内部闭源技术**，而非独立的开源创新。bigbrainchad.eth 作为该编码方案的命名来源，极可能是该团队的核心成员或同一人。

---

## 六、最可能的关系模型

### 关键时间线

理解三者关系的核心在于时间线：

| 时间 | 事件 |
|------|------|
| 2024 年 9 月 | bigbrainchad.eth INUMI 事件（12 秒清空新合约） |
| 2025 年初 | jtriley2p 开源 Lotus Router（AGPL-3.0） |
| ~2025 年 3 月 | 前雇主 DMCA 投诉，GitHub 仓库被删除；代码通过 IPFS 继续传播 |
| 2025 年 9 月 30 日 | AttackContract 首次部署（`0xA98E339f`，几乎所有主要 EVM 链，nonce=0） |
| 2025 年 10 月 11 日 | AttackContract Base 链部署（`0x42Ecd332`，nonce=53） |
| 2025 年 10-11 月 | AttackContract 活跃期，累计获利 ~$4.63M |

这个时间线表明：**Lotus Router 源码在 AttackContract 部署前至少 6 个月就已公开可获取**（GitHub 公开期 + IPFS 永久存储）。AttackContract 的开发者完全有条件研究 Lotus Router 的完整源码，包括 BBC 编码方案、嵌入式 VM 架构和递归回调模型。

### 关系图

```
BigBrainChad.eth (0xd215...0dfd)
  │  通用型 MEV 搜索者，开创 BBC calldata 压缩编码
  │  链上 bot: 0xd129...ecd, 0xBEEF...638
  │  标志: 所有 TX hash 以 0xbeef 开头
  │
  ▼
某 MEV 团队/公司的内部闭源路由器技术
  │  （jtriley2p 前雇主版权投诉 → 证实内部起源）
  │  核心架构: 嵌入式 VM + BBC 编码 + callback re-entry
  │
  ├──────────────────────────────────────────────────┐
  │                                                  │
  ▼                                                  ▼
Lotus Router (jtriley2p 开源, 2025 年初)         bigbrainchad.eth
  │  代码清理 + 文档化                              链上 MEV Bot
  │  BBC 变长编码标准化                             原始实践者
  │  AGPL-3.0 + Manifesto                          自动漏洞利用
  │  仅 4 callback，无运维/利润逻辑                  0xBEEF 炫技
  │
  │  ~2025.03 GitHub DMCA → IPFS 传播
  │
  ▼  源码公开可获取（至少 6 个月）
  │
  ▼
AttackContract (0xA98E / 0x42Ecd, 2025.09 部署)
  ├─ 架构同源：嵌入式 VM + 1B opcode + callback re-entry
  ├─ 编码简化：BBC 变长 → 固定宽度（降低解码 gas）
  ├─ 武器化扩展：借贷支持 + approve 伪装 + 利润提取 + builder tip
  ├─ 大幅扩展回调：4 → 42 函数 (18+ 协议)
  ├─ 新增 amount 寄存器 + ops 运维函数
  └─ 几乎所有主要公链部署
```

### 分析

基于时间线和架构证据，最可能的关系是：AttackContract 的开发者**在 Lotus Router 源码公开后研究了其架构**，并在此基础上进行了深度改造。这不是简单的"fork + 修改"——两者的编码方案（BBC 变长 vs 固定宽度）、回调模型（递归 vs 线性）、编译器版本（0.8.28 vs 0.8.15）都有本质差异，说明 AttackContract 是一次**基于相同架构范式的独立重新实现**，而非对 Lotus Router 源码的直接修改。

两者分别向不同方向演化：

- **Lotus Router** → 开源公益化（文档完善 + AGPL 许可 + 理想主义宣言）
- **AttackContract** → 武器化（借贷集成 + 利润提取 + 入口伪装 + 多链部署）

另一种可能的路径是：AttackContract 的开发者并非通过 Lotus Router 的公开源码学习，而是独立接触到了同一套内部闭源技术（版权投诉的事实说明这套架构确实源于一个商业组织的内部项目，可能在行业内有更广泛的传播）。但无论具体路径如何，核心结论不变：**两者共享同一架构范式，AttackContract 是该范式在攻击场景下的深度改造实现**。

值得反思的是，Lotus Router Manifesto 中 "I am an act of defiance against hoarders of technology and capital" 的理想主义愿景，与同一架构范式被用于大规模价值提取的现实形成了张力——这也反映了开源技术的双刃剑特性：技术公开既能促进透明和创新，也可能被用于开发者未曾预期的方向。

---

## 七、对比总表

| 维度 | Lotus Router | AttackContract |
|---|---|---|
| 许可证 | AGPL-3.0 | 闭源（链上字节码） |
| Solidity 版本 | 0.8.28 (via-IR) | 0.8.15 (非 via-IR，已验证) |
| Opcode 数量 | 12 (0x00-0x0b) | 12 (0x00-0x0b) |
| 执行引擎 | fallback() while 循环 | _execLoop() while 循环 |
| 编码方案 | BBC 变长（长度前缀） | 固定宽度（无前缀） |
| 入口点 | takeAction (显式) | approve (伪装) |
| 回调 | 4 个 (UniV2/V3) | 42 个函数 (18+ 协议) |
| DEX 支持 | UniV2, UniV3 | UniV2/V3, Balancer, iZiSwap, PancakeV3, Algebra, Solidly 等 18+ |
| 借贷支持 | 无 | Moonwell, Morpho Blue, AAVE V2/V3, Euler V2 |
| 利润提取 | 无 | 完整（PROFIT_RECEIVER + builder tip） |
| 运维 | 无 | 0x725f071c ops 函数 |
| `amount` 寄存器 | 无（参数独立） | 有（opcode 间传递） |
| Storage | 无 | 无（仅 immutable WETH） |
| 部署链 | 未知 | 几乎所有主要公链（逆向分析选取了其中 13 条链） |
| 已知获利 | N/A | ~$4.63M（14 个部署合计） |
