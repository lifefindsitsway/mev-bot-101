# MEV Bot 开发 101

一套基于真实攻击合约逆向工程的 MEV 系列教程，共 10 篇。全部内容使用 Claude Opus 4.6 生成。

## 背景

2025 年 9-11 月，一个攻击者利用 Moonwell 协议的预言机偏差，在几乎所有主要 EVM 链上发起了系统化的 DeFi 套利攻击，累计获利约 $4.63M。攻击使用了两个链上合约地址：

- `0xA98E339f5a0F135792286d481B4e23d91A667d3f` — 部署于几乎所有主要 EVM 链（2025-09-30）
- `0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB` — 部署于 Base 链（2025-10-11），净提取 295.75 ETH（~$1.06M）

两个地址由同一 EOA（`0x6997...58ff`）通过 CREATE 部署（nonce=0 和 nonce=53）。

## 逆向工程历程

最初，我将这两个合约视为**独立的攻击工具**分别进行逆向分析：

1. **第一阶段** — 以 Base 链部署 `0x42Ecd332` 的 15 笔攻击交易为切入点，通过 Heimdall 反编译、`cast run --trace` 交易重放和 calldata 逐字节对照，完成了初步的 Solidity 重建。此阶段仅观测到 42 个函数中的部分子集，多个操作码的参数格式存在误判。

2. **第二阶段** — 对 `0xA98E339f` 在 13 条链上的 289 笔交易进行跨链分析和 replay 验证，修正了第一阶段的认知偏差（操作码语义、参数宽度、flags 含义等）。

3. **字节码同一性验证** — 逐字节比对发现：两个合约的 24,543 字节 runtime 字节码**几乎完全相同**，差异仅来自 immutable WETH 地址（5 处 × 20 字节）和 IPFS 元数据哈希（32 字节）。它们就是**同一份 Solidity 源码**的参数化部署。

4. **统一重建** — 将两阶段的分析成果合并为一份 `AttackContract.sol`（800+ 行），通过构造函数传入不同链的 WETH 地址即可编译出与链上字节码匹配的合约。**141 笔 mainnet fork replay 全部 PASS（100%）**，利润精确匹配到 wei 级别。

完整的逆向数据和验证记录见 `moonwell_exploit_reverse_analysis/` 目录。

## AttackContract 概览

AttackContract 是一个**无状态的 Calldata 驱动指令引擎**：

- **12 个自定义操作码**（0x00-0x0b）：V2/V3 swap、闪电贷、WETH 操作、余额查询、通用调用等
- **45 个 dispatch selector**（42 个函数）：覆盖 18+ DEX 协议的闪贷和 swap 回调
- **approve() 伪装入口**：借用 ERC-20 的函数签名隐藏攻击载荷，内建反重放、利润保证、Builder 贿赂等安全机制
- **amount 寄存器**：跨指令共享的有状态 VM 设计，支持运行时余额查询和动态金额管理

攻击流程：链下系统检测到预言机偏差 → 生成 calldata 指令序列 → 合约在一笔交易内原子化执行闪贷、借贷、DEX swap、利润提取。

## Lotus Router

Lotus Router 是 [jtriley2p](https://x.com/jtriley2p) 编写的开源 MEV 路由合约（AGPL-3.0），原 GitHub 仓库因前雇主 DMCA 投诉已被删除，源码通过 IPFS 继续传播（本项目 `reference/lotus-router/` 保留了完整副本）。它与 AttackContract 共享同一架构范式——fallback 驱动的指令循环、1 字节 opcode dispatch、回调重入模型。两者的关键差异在于：

| 维度 | Lotus Router | AttackContract |
|------|-------------|----------------|
| 定位 | 开源通用组件 | 生产级攻击引擎 |
| 编码 | BBC 变长前缀（压缩 ~77%） | 固定宽度（解码更快） |
| 回调 | 递归模型（4 个入口） | 线性模型（45 个入口，18+ 协议） |
| 状态 | 无状态 | amount 寄存器 |
| 安全 | 无 | 反重放 + 利润保证 + Builder 贿赂 |

教程中将 Lotus Router 作为"正向阅读"的参照物（源码清晰、有完整测试），AttackContract 作为"逆向分析"的参照物（生产级实现），两者互补形成完整的教学视角。

## 教程目录

| 状态 | 篇 | 标题 | 核心内容 |
|:----:|----|------|---------|
| ✅ | 1 | 一笔 "approve(0, 0)" 背后的百万美元 —— MEV 全景导论 | MEV 定义、四大类型、供应链、案例全景 |
| ✅ | 2 | 交易的一生 —— 从 Mempool 到区块打包 | 交易生命周期、gas 策略、PGA 到 Flashbots 的演进 |
| ✅ | 3 | 闪电贷与 DEX —— MEV 的两大基础设施 | 闪贷原子性、V2/V3 swap 范式、回调机制 |
| ✅ | 4 | MEV 路由合约设计 —— Lotus Router 源码精读 | fallback 主循环、递归回调、findPtr、BBC 编码 |
| ✅ | 5 | Calldata 压缩编码 —— 三套方案的工程权衡 | BBC 变长 vs 固定宽度 vs 标准 ABI，gas 成本分析 |
| ✅ | 6 | 拆解攻击合约 —— 从字节码到重建源码 | 逆向方法论、calldata 驱动逆向、迭代验证 |
| ✅ | 7 | 指令引擎深度解析 —— 12 操作码的两种实现 | 两套指令集对比、amount 寄存器、回调架构 |
| ✅ | 8 | 安全机制与 MEV 基础设施 | approve 包装器、Flashbots 生态、flags 语义修正 |
| ✅ | 9 | 策略参数化与跨链泛化 —— 从 1 条链到全网部署 | 字节码同一性验证、calldata 模板化、跨链部署策略 |
|    | 10 | *（规划中）* | 基于所学知识的实战项目 |

## 项目结构

```
mev_bot_101/
├── README.md                              ← 本文件
├── CLAUDE.md                              ← Claude Code 项目指令
├── outline.md                             ← 各章节详细大纲
├── glossary.md                            ← 术语表
├── chapters/                              ← 教程章节（Markdown）
├── reference/                             ← 教学参考资料
│   ├── lotus-router/                      ← Lotus Router 完整源码
│   ├── lotus-router-report.md             ← Lotus Router 研究报告
│   ├── attack_contract_vs_lotus_router_analysis.md
│   ├── mev-system-architecture.md         ← MEV Searcher 三层架构
│   └── Flash_Boys_2_0.pdf                 ← MEV 创世论文
└── moonwell_exploit_reverse_analysis/     ← 逆向工程全部数据
    ├── AttackContract/                    ← 统一重建 Foundry 项目（141/141 PASS）
    ├── 0x42Ecd332.../                     ← Base 链逆向归档
    ├── 0xA98E339f.../                     ← 跨链分析数据
    ├── bytecode_identity_verification.md  ← 字节码同一性验证
    └── moonwell_exploit_reverse_report.md ← 综合逆向报告
```

## 生成工具

全部教程内容由 [Claude Code](https://claude.ai/claude-code)（Claude Opus 4.6）生成，项目指令见 `CLAUDE.md`。
