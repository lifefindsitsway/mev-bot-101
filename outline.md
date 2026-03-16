# 《MEV Bot 开发 101》系列教程 —— 详细大纲

> 本文件是各章节内容生成的权威参考。生成某章节前必须读取对应部分。

---

## 第 1 篇：一笔 "approve(0, 0)" 背后的百万美元 —— MEV 全景导论

**文件名**: `01-mev-overview.md`

**核心目标**: 让读者在不接触任何技术细节的情况下，建立 MEV 的全局图景，并对后续内容产生强烈期待。

**开场钩子**: 展示 Base 链 `0x42Ecd332` 合约的 TX_01 Basescan 页面——一笔 Method 显示为 `Approve` 的交易，参数为 `approve(address(0), 0)`，消耗超过 160 万 gas，最终将约 30.79 ETH 发送到攻击者 EOA。30 秒内 12 笔类似交易（05:44:57 ~ 05:45:23 UTC），净提取共计 295.75 ETH（~$1.06M）。然后揭示更大的画面：同一攻击者从 2025-09-30 起在几乎所有主要 EVM 链上部署了相同合约（`0xA98E339f`），仅我们分析的 13 条主要公链上就有 289 笔交易，攫取约 $3.56M。经字节码同一性验证，这些部署实际上来自**同一份 Solidity 源码**（AttackContract.sol）——同一套攻击基础设施，仅分析的 14 个部署就有 304 笔交易，~$4.63M 到手利润。

**知识点覆盖**:
- MEV 的定义：从交易排序的角度解释 Maximal Extractable Value
- MEV 四大类型：DEX 套利、三明治攻击、清算、预言机套利（本案例）
- MEV 供应链：Searcher → Builder → Proposer
- 案例定位：AttackContract 是一份通用 DeFi 套利引擎的源码，14 次参数化部署，而非单次攻击脚本
- 教学参照物预告：Lotus Router（开源正向参照）、AttackContract（逆向重建）

**Flash Boys 2.0 引用点**:
- 引用论文中 MEV 的原始定义："value that is extractable by miners directly from smart contracts as cryptocurrency profits"（Section VII）。指出该定义最初称为 "Miner Extractable Value"，后随以太坊转为 PoS，社区将 "Miner" 改为 "Maximal"，含义扩展为任何能影响交易排序的参与者可提取的价值
- 一句话提及论文的历史地位："2019 年 Philip Daian 等人在 Flash Boys 2.0 中首次定义了这个概念，从此开启了一个年产值数十亿美元的研究与产业领域"
- 不需要展开论文的技术细节（PGA 模型、共识安全等留给后续篇章）

**写作提示**:
- 本篇完全不涉及技术实现细节（不讲闪电贷、calldata、回调机制）
- 用叙事而非说教的方式讲述——"一笔看似无害的交易背后隐藏着什么"
- 结尾给出系列路线图："到最后一篇，你将能读懂这 932 字节 calldata 的每一个字节"
- 第 1 篇生成完成后，提取术语表保存为 `glossary.md`

---

## 第 2 篇：交易的一生 —— 从 Mempool 到区块打包

**文件名**: `02-mempool-and-gas.md`

**核心目标**: 让读者理解一笔交易从提交到被打包的完整生命周期，以及 MEV 如何在这个过程中产生。

**案例锚点**: AttackContract Base 链部署（`0x42Ecd332`）的 12 笔主攻击 gas price 为 175-253 gwei（Base 正常水平 <1 gwei 的 200 倍以上），仅 gas 成本就达 4.42 ETH（~$15,900），占净提取利润的 1.5%。对比 10/17 试探性攻击的 2-4 gwei。

**知识点覆盖**:
- 交易生命周期：签名 → RPC 广播 → Mempool → Builder 选择 → 打包 → 确认
- Mempool 的公开性——MEV 的温床
- EIP-1559 的 base fee + priority fee
- 为什么 Base 链攻击时 gas price 暴涨到 253 gwei——时间窗口约 30 秒
- 攻击拆分的多重原因：流动性限制、风险分散、gas limit、竞态防御
- 私有交易通道：Flashbots Protect、Builder API
- Ethereum 链部署向 Titan Builder 支付 43.82 ETH builder tip

**Flash Boys 2.0 引用点**:
- 引用论文中的 Priority Gas Auction（PGA）概念：2018-2019 年，MEV Bot 在公开 mempool 中通过不断提高 gas price 来竞价——论文 Figure 2 展示了两个 Bot 在 13 秒内将 gas price 从 25 gwei 竞抬到 8856 gwei 的真实案例
- 与 2025 年的 AttackContract 案例形成历史对照：从"公开 mempool 中的 PGA 竞价"到"通过 Flashbots 私有通道直接向 Builder 支付 tip"，MEV 基础设施在 6 年间经历了根本性变革。AttackContract 的 `block.coinbase` 贿赂机制和 Ethereum 链部署向 Titan Builder 支付 43.82 ETH 的 tip，都是这个演进的直接产物
- 不需要展开论文的博弈论模型，只需用 1-2 段描述"从 PGA 到 Flashbots"的演进线索

**动手环节**: 用 ethers.js 写一个 mempool 监听器，订阅 pending 交易并过滤特定合约地址。

**写作提示**:
- gas price 异常是一个非常直观的切入点——"为什么有人愿意付正常价的 200 倍"
- 不要深入讲 EIP-1559 的数学细节，重点是"为什么 MEV 场景下 gas 策略与普通交易不同"
- "从 PGA 到 Flashbots"的演进线索不要占太多篇幅（2-3 段即可），重点仍然是 AttackContract 的真实案例

---

## 第 3 篇：闪电贷与 DEX —— MEV 的两大基础设施

**文件名**: `03-flashloan-and-dex.md`

**核心目标**: 让读者理解闪电贷的原子性魔法和 DEX swap 的两大范式（V2 先转账 vs V3 回调），为后续理解 MEV 路由合约的回调架构奠定基础。

**案例锚点**: AttackContract Base 链部署的一笔典型攻击（TX_01）仅闪贷极微量 wrsETH（价值几美元）作为抵押品，却借出数千美元资产，最终净提取约 30.79 ETH。

**知识点覆盖**:
- 闪电贷原理：同一交易内借还，归还失败则回滚
- 闪电贷协议全景：AAVE V2/V3、Balancer、Uniswap V3 flash、Morpho
- 每种协议的回调函数签名差异——解释合约需要 42 个函数选择器的根本原因（覆盖 18+ DEX 协议的闪贷和 swap 回调）
- DEX swap 两大范式：V2 先转账后 swap vs V3 回调模式
- Algebra 的有符号 delta 语义
- 合约按参数类型（uint256 vs int256）分派回调的设计决策：flash 回调 `(uint256,uint256,bytes)` → `_handleUintCb`，swap 回调 `(int256,int256,bytes)` → `_handleIntCb`
- AMM 数学基础：V2 恒定乘积、V3 集中流动性、sqrtPriceLimitX96

**动手环节**:
1. 写一个最简 AAVE V3 闪贷合约：闪贷 → 回调中直接归还
2. 写一个 V3 swap 合约：调用 swap() → 在 callback 中转账欠款

**写作提示**:
- 闪电贷的"原子性"是核心——强调"要么全部成功，要么全部回滚"
- AMM 数学不需要深推，重点是"DEX swap 是确定性的——给定输入，输出可以精确计算"

---

## 第 4 篇：MEV 路由合约设计 —— Lotus Router 源码精读

**文件名**: `04-lotus-router.md`

**核心目标**: 通过正向阅读 Lotus Router 源码，让读者理解 MEV 路由合约的核心设计模式：Calldata 驱动 VM、递归回调、findPtr 机制。

**Lotus Router 源码位置**: `reference/lotus-router/`，架构分析见 `reference/lotus-router-report.md`

**过渡叙事**: 第 3 篇手写了独立的闪贷和 swap 合约，但真实 MEV Bot 需要在一笔交易中串联多个操作。Lotus Router 正是这样一个路由合约。

**知识点覆盖**:
- 所有路由合约的本质：Calldata 驱动的虚拟机
- `fallback()` 主循环（读取 `reference/lotus-router/src/LotusRouter.sol`）：读 1 字节 action → 解码参数 → 执行 → 下一个 action → `Action.Halt`（0x00）时 `stop()` 成功返回
- Action 指令集（0x00~0x0b，共 12 个，定义在 `reference/lotus-router/src/types/Action.sol`）
- 递归回调模型：V3 swap 把未执行的 calldata 作为 data 传给 Uniswap，回调中通过 `findPtr()` 恢复（代码在 `reference/lotus-router/src/types/PayloadPointer.sol`）
- `findPtr()` 机制：根据 `msg.sig` 返回不同偏移（`takeAction` → 0x04，`uniswapV2Call` → 0xa4，V3 回调 → 0x84）
- `canFail` 容错机制：`success = result || canFail`
- 协议交互层的内联汇编（`reference/lotus-router/src/types/protocols/ERC20.sol` 的 `transfer` 函数）：scratch space 复用、FMP 备份、零槽清理
- WETH deposit 优化：用空 calldata 触发 `receive()` 而非调用 `deposit()`（见 `reference/lotus-router/src/types/protocols/WETH.sol`）

**动手环节**:
1. 完整阅读 Lotus Router 源码，走一遍 "ERC20 transfer + V3 swap" 流程
2. 手动构造一条 calldata，理解 BBCEncoder 编码规则

**写作提示**:
- 可以引用 WongSSH 博文（https://blog.wssh.dev/posts/lotus-router/）中的流程图辅助讲解
- 递归回调模型是最难理解的部分——用 A→B→C 的多跳 swap 例子展示实际执行顺序反转（README.md 中有 mermaid 时序图）
- jtriley2p 被前雇主 DMCA 的故事可以作为"行业背景"简要提及

---

## 第 5 篇：Calldata 压缩编码 —— 三套方案的工程权衡

**文件名**: `05-calldata-encoding.md`

**核心目标**: 让读者理解为什么 MEV 路由合约需要自定义编码格式，以及三种编码方案（Lotus Router 长度前缀、AttackContract 固定宽度、标准 ABI）的工程权衡。

**知识点覆盖**:
- 为什么要压缩 calldata：非零字节 16 gas vs 零字节 4 gas
- 方案 A：Lotus Router "长度前缀"（BBC 编码）——byte_len_u8 + 去前导零值。README 中的量化对比：同一笔 V2 swap，ABI 编码 288 字节 vs BBC 编码 66 字节（压缩 77%）
- 方案 B：AttackContract "固定宽度"——地址 20B、uint256 32B
- 逆向认知演进：早期独立分析阶段因仅观测到 15 笔交易的 opcode 子集，曾将某些 opcode 误判为不同宽度（如 READ_VALUE 20B→实为 32B，SET_AMOUNT 7B→实为 0B）。跨链 replay 验证后确认为分析错误
- Lotus Router `BBCDecoder` 内联汇编精读（`reference/lotus-router/src/util/BBCDecoder.sol`）：`calldataload`、`shr`、`signextend` 的解码模式
- `int256` 的 `signextend` 处理（`BBCEncoder.byteLen(int256)` 中的符号保留逻辑）
- 内存布局：0x40-0x60 空闲指针保护、0x60-0x80 零槽清理
- AttackContract 的 `_rAddr()`、`_r16()`、`_slice()` 辅助函数（参见 `moonwell_exploit_reverse_analysis/AttackContract/src/AttackContract.sol`）
- 工程权衡总结表：压缩率 vs 解码成本 vs 代码复杂度

**动手环节**:
1. 手动编码 Lotus Router 的 transfer_erc20 操作
2. 用两种方案编码同一操作，计算 calldata gas 差异

**写作提示**:
- 这篇偏技术深度，用具体的字节级示例让读者"看到"编码差异
- signextend 的讲解可以简化——"将短字节的有符号数扩展为 int256"
- README 中 288B vs 66B 的量化对比是最直观的教学素材

---

## 第 6 篇：拆解攻击合约 —— 从字节码到重建源码

**文件名**: `06-reverse-engineering.md`

**核心目标**: 展示完整的逆向方法论——从没有源码的 24,543 字节的字节码到可编译、replay 验证通过的 AttackContract.sol。本篇讲述第一阶段（以 Base 链 15 笔攻击交易为切入点的独立逆向），为第 9 篇的字节码同一性发现埋下伏笔。这篇是系列中最具原创性的内容。

**重要背景**: 本篇展示的是逆向工程的**第一阶段**——以 Base 链部署（`0x42Ecd332`）的 15 笔攻击交易为切入点的独立分析。由于仅观测到部分交易，初始分析只识别出合约 42 个函数中被实际调用的子集。后续跨链分析和字节码同一性验证（第 9 篇展开）揭示了完整的 42 个函数（对应字节码中 45 个 dispatch 入口）的全貌。本篇应忠实记录这个从"局部观察"到"完整认知"的发现历程。

**知识点覆盖**:
- 逆向工具链：WhatsABI → Heimdall → cast run --trace → 字节码直接分析
- 选择器分发表重建：初始从 15 笔交易中识别出部分 selector → 跳板架构发现（后经字节码完整分析确认为 45 个 dispatch selector）
- 硬编码常量提取：WETH 地址（5 处引用的 immutable）、PROFIT_RECEIVER（`0x6997...58ff`）等
- approve 执行包装器分析：反重放、利润检查、WETH 转换、利润发送
- flags 参数语义修正过程（提及即可，详细分析在第 8 篇）
- calldata 驱动逆向：真实 TX calldata 逐字节对照 trace
- V3_SWAP flag=1 表示闪贷的发现
- 双指令集架构的发现
- CALL_WITH_AMOUNT trail 机制的发现
- 迭代修复："编译→重放→失败→字节级对比→修复"
- 代理合约陷阱：proxy + delegatecall 导致 Gas Profiler 双重计数
- 留下悬念：24,543 字节的字节码中有大量函数在 Base 链 15 笔交易中从未被触发——它们的用途在跨链分析中才会揭晓

**动手环节**:
1. 用 Heimdall 反编译一个简单的 ERC20 合约
2. 用 cast run --trace 重放一笔 Base 链攻击交易
3. 对照 AttackContract.sol 和 attack_flow.md 验证执行流程

**写作提示**:
- 这篇要有"侦探叙事"的节奏——展示发现过程中的困惑、假设、验证和修正
- "编译→重放→失败→字节级对比→修复"的循环是核心工作流，用具体的失败案例展示
- 不要一次性抛出所有发现，按时间顺序讲述逆向过程

---

## 第 7 篇：指令引擎深度解析 —— 12 操作码的两种实现

**文件名**: `07-instruction-engine.md`

**核心目标**: 系统对比 Lotus Router 与 AttackContract 两套指令引擎的设计差异，揭示 MEV 路由合约设计空间的核心权衡。本篇是系列的技术核心。

**知识点覆盖**:
- 两套指令集的完整对比表（按功能域：V2 Swap、V3 Swap、闪贷、通用调用、金额管理、协议覆盖、Flash repay）。参考 `reference/lotus-router-report.md` 中 §3.2 的操作码映射表
- "有状态 VM" vs "无状态路由器"：amount 寄存器的意义
- 回调架构对比：Lotus Router 递归（findPtr + calldata 嵌套）vs AttackContract 线性（闪贷回调执行指令，swap 回调仅转账）
- 回调路由设计：按参数数据类型分派（`_handleUintCb` 处理 `(uint256,uint256,bytes)` 的 flash 回调，`_handleIntCb` 处理 `(int256,int256,bytes)` 的 swap 回调），覆盖 18+ DEX 协议
- 逆向认知演进专栏：逆向过程中的 7 个关键误判（参数类型混淆、flags 语义、opcode 0x02/0x06 误判等）如何在跨链 replay 验证中被逐一修正。这些不是合约的 Bug，而是逆向分析者从局部观察推断整体时的必然误差
- canFail vs require(ok) vs CALL_WITH_CHECK 的容错哲学
- trail 机制：CALL_WITH_AMOUNT 如何适配不同协议 ABI

**动手环节**:
1. 用 Base 链 TX_01 calldata 手动解码完整指令序列
2. 用 Lotus Router 指令集编码等价的攻击流程，对比 calldata 体积

**写作提示**:
- 对比表是核心——但不要只列表，每个重要差异都要解释"为什么"
- amount 寄存器是"有状态 VM vs 无状态路由器"最本质的差异，要讲透
- 按参数类型分派回调是一个优雅的设计决策，值得展开
- "逆向认知演进"专栏是本篇的独特教学价值——展示逆向工程中"从局部到整体"的认知过程

---

## 第 8 篇：安全机制与 MEV 基础设施

**文件名**: `08-security-and-infra.md`

**核心目标**: 系统讲解 MEV Bot 的安全设计和 Flashbots 生态，同时通过 flags 参数语义修正的故事展示逆向工程中"假设→验证→修正"的方法论。

**案例锚点**: AttackContract 的 approve() 安全包装层（反重放、利润保证、coinbase 贿赂、硬编码收款）vs Lotus Router 的裸奔设计。flags 参数语义修正：从"gas 补偿位域"到"直接 wei 金额"——这个发现来自 Ethereum 链 replay 验证。

**知识点覆盖**:
- 两种安全哲学："组件"（Lotus Router）vs "自治系统"（AttackContract）
- Flashbots 生态：Protect、MEV-Share、Builder API
- block.coinbase 贿赂原理
- Builder tip 实例：Titan Builder 43.82 ETH、Sonic MEV ~170,751 S
- 反重放机制：msg.value vs block.number
- flags 参数语义修正的完整故事（初始假设 → replay 差异 → wei 级验证 → 修正）
- approve 伪装的心理学
- 运维函数 0x725f071c（合约内置，仅在 BNB/Ethereum 链上被实际调用）：批量 gas 分发 + 子 EOA 管理。注意：该函数存在于所有 14 个部署的字节码中（因为是同一合约），但仅在 BNB（24 笔）和 Ethereum（1 笔）链上被调用
- jtriley2p 版权投诉与 IPFS 传播

**Flash Boys 2.0 引用点（可选，作为延伸）**:
- 论文提出的 time-bandit attack 概念：矿工可以回溯区块链历史，重新执行过去的 MEV 机会。这是 MEV 对共识层安全最激进的威胁形式
- 论文的测量数据显示，2019 年已有 OO fees 超过区块奖励的区块（Figure 16，最高 101.6 ETH vs 3 ETH 区块奖励）——这预见了后来 Flashbots 等 MEV 基础设施诞生的必要性
- 作为"进一步阅读"推荐，不需要在正文中展开数学模型

**动手环节**:
1. 为 Lotus Router 添加 approve() 安全包装层
2. 通过 Flashbots Protect RPC 提交一笔测试交易
3. 讨论题：部署到生产环境还需要哪些安全机制？

**写作提示**:
- flags 语义修正是一个很好的"方法论教学"案例——"逆向工程中，初始假设经常是错的"
- 运维函数揭示了 MEV 团队的运营模式，不只是技术问题
- Flash Boys 2.0 的引用应该自然融入"MEV 基础设施的历史演进"的叙事中，而非生硬插入

---

## 第 9 篇：字节码同一性与跨链泛化 —— 14 次部署 = 1 份源码

**文件名**: `09-cross-chain.md`

**核心目标**: 揭示逆向研究中最重大的发现——14 个链上部署实为同一份 AttackContract 源码的参数化部署，并展示 MEV 策略如何从单笔交易扩展为跨链、多协议的系统化运营。

**案例锚点**: Base 链 13 笔 Moonwell 攻击共享同一 calldata 模板（5 个可变字段，73B / 7.8%）；14 个链上部署仅差 132 字节（5×WETH + IPFS metadata），Polygon 额外 +1,149 字节（atlasSolverCall）。

**知识点覆盖**:
- **字节码同一性验证**（本篇核心叙事）：
  - 逐字节比对的三个层级：完全相同（Base×2 + Optimism，仅 IPFS 32B 差异）→ 参数化部署（10 链，132B = 5×WETH + IPFS）→ 功能扩展（Polygon，+atlasSolverCall）
  - CREATE 地址验证：`0xA98E339f` nonce=0，`0x42Ecd332` nonce=53，同一部署者 EOA
  - 编译器一致性：全部 solc 0.8.15，CBOR 51B
  - 统一重建 AttackContract.sol 的验证：一份源码，141/141 TX replay PASS
  - 早期逆向中的认知偏差：为什么最初会误认为是"两个不同合约"（观测子集有限、独立分析路径）
- Calldata 模板化：5 个可变字段的偏移和含义
- 多市场扫描逻辑：可借流动性 × DEX 出口流动性
- 跨链泛化：14 次部署策略、CREATE nonce=0、132 字节差异分析
- "逆向 Base = 逆向全部"的原理——字节码同一性的直接推论
- 跨协议泛化：RAW_CALL + CALL_WITH_AMT trail 适配不同 ABI
- BNB 链三地址轮转运营模式（主 EOA + 2 子 EOA）
- 部署时间线：`0xA98E339f` 13 链（09/30 一天内全部部署）→ `0x42Ecd332` Base 链（10/11 部署，10/17 首次攻击）→ 并行运营至 11/05
- 机会发现系统架构概述：预言机偏差检测 → 市场扫描 → 利润模拟 → calldata 生成

**动手环节**:
1. Python 脚本：读取 Moonwell 各市场可借余额和预言机价格
2. Calldata 模板填充器：自动生成完整 calldata
3. Foundry fork 测试验证生成的 calldata

**写作提示**:
- 字节码同一性验证是本篇的"高潮时刻"——从第 6 篇留下的悬念（"24,543 字节中有大量未触发的函数"）到本篇的"啊哈！它们就是同一个合约"
- 跨链差异分析（132 字节）是一个非常具体、可验证的数据点
- BNB 三地址轮转揭示了 MEV 不只是"写代码"，还有"运营管理"的维度
- 注意区分"部署日期"和"首次攻击日期"：Base 链 `0x42Ecd332` 10/11 部署，10/17 首次出手

---

## 第 10 篇：构建你自己的 MEV Router —— 基于 Lotus Router 的实战改造

**文件名**: `10-build-your-router.md`

**核心目标**: 读者基于 Lotus Router 源码，融合从 AttackContract 逆向分析中学到的生产级设计，动手实现 4 个改造方向。

**Lotus Router 源码位置**: `reference/lotus-router/`

**知识点覆盖**:
- 改造 1：添加 amount 寄存器（balance_of、set_amount、check_amount）—— 参考 AttackContract 的 `_exec()` 中 opcodes 0x05-0x08 的实现
- 改造 2：扩展协议覆盖（Algebra 回调、CLPool flash、Balancer）—— 参考 AttackContract 按参数类型分派的架构（`_handleUintCb` / `_handleIntCb`）
- 改造 3：安全包装层（反重放、利润保证、coinbase 贿赂）—— 参考 AttackContract 的 `approve()` 函数
- 改造 4：canFail + CALL_WITH_CHECK 混合容错
- Foundry fork 测试验证
- Gas 对比：原版 Lotus Router vs 改造版 vs AttackContract

**动手环节**:
1. 实现改造 1（amount 寄存器）和改造 3（安全包装层）
2. 编写 Foundry 测试验证功能
3. Gas 对比测试

**写作提示**:
- 这篇是"动手为主"，代码量会比较大
- 改造 2 和 4 可以作为课后练习，不需要完整实现
- 系列收束：回顾从第 1 篇到第 10 篇的学习路径
- 指出延伸方向：链上 VM 设计子系列、Rust MEV 框架（artemis/rusty-sando）、跨链深度分析
- 推荐 Flash Boys 2.0 论文作为进一步阅读材料
