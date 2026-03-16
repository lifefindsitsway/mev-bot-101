# MEV Bot 开发 101 系列教程 —— 项目指令

## 项目概述

本项目是《MEV Bot 开发 101》系列教程的内容生成工程。全系列共 10 篇，使用 Markdown 格式输出，存放在 `chapters/` 目录下。

**关键指令：首次生成某章节内容时，必须先读取 `outline.md` 中对应章节的详细说明。** `outline.md` 包含每篇文章的核心内容规划、案例锚点、知识点覆盖范围、动手环节要求和写作提示，是内容生成的权威参考。不要仅凭章节标题猜测内容方向。如果该章节已生成并存在于 `chapters/` 目录下，后续对其特定部分进行修改或润色时，则不必强制读取 `outline.md`，直接读取已有章节内容并按作者要求修改即可。

## 作者背景

作者是一名资深以太坊合约开发者，具备以下技术背景：

- 精通 Solidity 编程、EVM 底层原理（ABI 编码、Gas 优化、代理合约、存储布局、内联汇编等）
- 有安全服务（渗透测试）工作经验，对合约安全漏洞有审计视角
- 已完成一套真实 MEV Bot 合约系统的逆向工程，最终重建为 `AttackContract.sol`（800+ 行）：
  - 14 个链上部署（Base 链 `0x42Ecd332` + 13 条链 `0xA98E339f`）经字节码同一性验证确认为**同一份 Solidity 源码**（24,543 字节 runtime，42 函数 / 45 dispatch selectors；仅 WETH 地址和 IPFS 元数据不同）
  - 141 笔 mainnet fork replay 全部 PASS (100%)，详见 `moonwell_exploit_reverse_analysis/bytecode_identity_verification.md`
- 熟悉 Calldata 驱动架构、闪贷回调机制、Flashbots 贿赂、链上字节流 VM 等 MEV 核心概念
- 2025 年全年在 Solana 链上活跃，对链上数据分析、流动性池、Meme 币交易有丰富的用户侧实操经验
- 已完整阅读 Lotus Router 源码（jtriley2p 的开源 MEV 路由合约）

但作者对以下内容处于学习阶段：

- MEV 理论：对 MEV 供应链（Searcher → Builder → Proposer）、Flashbots 生态、MEV-Share 等概念有实操认知但缺乏系统性理论框架
- Mempool 监听：没有实际编写过链下 mempool 监听器或机会发现系统

## 教学资产

本系列教程的两个核心教学参照物：

1. **Lotus Router**（开源源码，`reference/lotus-router/`）—— jtriley2p 的 MEV 路由合约，教科书级的 Calldata 驱动 VM 实现。研究报告见 `reference/lotus-router-report.md`
2. **AttackContract.sol**（800+ 行逆向重建 Solidity，`moonwell_exploit_reverse_analysis/AttackContract/src/`）—— 逆向工程最终成果，一份源码复现 14 个链上部署的全部行为。通过构造函数传入不同链的 WETH 地址即可编译出与链上字节码匹配的合约。141 笔 mainnet fork replay 全部 PASS (100%)

`moonwell_exploit_reverse_analysis/` 目录下的其他子目录和文件（`0x42Ecd332.../`、`0xA98E339f.../`、`bytecode_identity_verification.md`、`moonwell_exploit_reverse_report.md` 等）是逆向分析过程的原始数据和验证记录，教程生成时作为**事实核查的数据源**使用，不作为独立的教学参照物

### 学术参考

`reference/Flash_Boys_2_0.pdf` 是 Philip Daian 等人 2019 年发表的 "Flash Boys 2.0" 论文（arXiv:1904.05234），首次定义了 Miner Extractable Value（MEV）概念，记录了 Priority Gas Auction（PGA）现象，并证明了交易排序依赖会产生共识层安全风险。这篇论文是整个 MEV 领域的创世文献。

**使用原则：不要求 Claude Code 逐页阅读 PDF 来生成内容。** 论文的关键引用点已在 `outline.md` 对应章节中明确标注。Claude Code 应使用自身知识准确引用论文的核心概念，必要时读取 PDF 验证具体定义或数据。具体来说：

- **第 1 篇**：引用论文中 MEV 的原始定义，作为理论起点
- **第 2 篇**：引用 PGA 机制（Figure 2 的两 Bot 竞价案例），与 AttackContract 的 gas 策略形成历史对照
- **第 8 篇**：可选引用 time-bandit attack 概念，作为"MEV 对共识安全的威胁"的延伸阅读

论文中的博弈论模型（Section V）和实测数据（2017-2019 年）不需要在教程中展开——教程面向 Solidity 开发者而非博弈论研究者，且论文数据已过时（2025 年 MEV 生态已被 Flashbots/PBS 彻底改变）。

### 利润引用规范

涉及 Base 链部署（`0x42Ecd332`）利润时，统一使用**净提取利润 295.75 ETH**（约 $1.06M，按攻击当日 2025-11-04 ETH 价格 $3,600.72 计算）。该数字为攻击者 EOA 链上实际转出金额，已扣除全部 gas 成本 4.74 ETH。毛利润 300.49 ETH 仅在需要拆解 gas 成本结构时作为参考引用。

涉及攻击者总利润时，使用 **~$4.63M**（Base 链部署 ~$1.06M + 跨链部署 ~$3.56M）。14 个部署来自同一份 AttackContract 源码，总利润来自同一套攻击基础设施。

## 写作规范

### 视角与语气

- 以"一位熟悉以太坊但首次系统学习 MEV"的视角来写，对 MEV 的每一个新概念都从基础开始循序渐进地解释
- Solidity / EVM 的底层知识可以作为"已知"背景，不需要从头讲解，但涉及 MEV 特有的概念（如 Searcher、Builder、bundle、backrun 等）需要明确定义
- 语气保持专业但平易近人，像一位正在做逆向研究的安全研究员在向同行分享发现，而不是教科书式的灌输
- 逆向分析相关的内容要有"侦探叙事"的节奏感——展示发现过程中的困惑、假设、验证和修正，而非只呈现最终结论

### 真实案例的使用原则

- 每篇文章都有一个"案例锚点"——来自 AttackContract 逆向研究或 Lotus Router 源码的真实数据/代码
- 案例锚点用于引出理论概念，不是简单的"举例说明"，而是"从真实数据中发现规律"
- 引用链上数据时必须给出具体的交易哈希、合约地址或代码位置，不要使用"某笔交易"这样的模糊表述
- 引用 AttackContract 的分析结果时，以 `moonwell_exploit_reverse_analysis/` 目录下的文档为权威来源

### Lotus Router 与 AttackContract 的对比原则

- Lotus Router 是"正向阅读"的参照物（开源源码），AttackContract 是"逆向分析"的参照物（字节码重建）
- 当同一概念可以用两种方式讲解时，优先用 Lotus Router 引入（源码更易读），再用 AttackContract 做对比（展示生产级实现的差异）
- 不要在每个小节都同时引用两个参照物，根据当前小节的教学目标选择最合适的一个
- 引用 Lotus Router 源码时，可以读取 `reference/lotus-router/` 目录下的实际代码。整体架构分析见 `reference/lotus-router-report.md`
- 引用 AttackContract 源码时，读取 `moonwell_exploit_reverse_analysis/AttackContract/src/AttackContract.sol`

### 排版格式

- 中文与英文字母、数字之间必须留一个空格（例如："Solidity 的 ABI 编码"而非"Solidity的ABI编码"）
- 使用 Markdown 格式输出
- 代码块使用对应语言的语法高亮标记（```solidity、```javascript、```python、```bash 等）
- 所有代码示例必须包含中文注释，解释关键逻辑步骤
- 适当使用表格来做系统间的对比（Lotus Router vs AttackContract）
- 不要在正文中滥用加粗，只在引入关键术语或核心结论时加粗
- 链上地址使用等宽字体（反引号包裹），长地址可以缩写为 `0x42Ec...34bB` 格式
- 涉及攻击交易的日期和时间统一使用 **UTC** 格式（例如："2025-11-04 05:44 UTC"），不使用其他时区

### 内容结构

每篇文章遵循以下结构：

```
# 第 X 篇：标题

开篇引言（2-3 段）：用一个具体的案例场景或数据点开场，引出本篇要解决的核心问题。

## 正文（按逻辑递进分为 3-5 个小节）

每个小节围绕一个核心概念展开，配合真实案例数据、代码分析和系统对比。

## 动手环节

1-3 个具体的实践任务，让读者动手操作。每个任务给出明确的输入、步骤和预期输出。

## 小结

用 3-5 句话总结本篇的核心要点。用一句话预告下一篇的内容。
```

### 内容质量要求

- 结构紧凑、逻辑流畅，避免杂乱无序的信息堆砌
- 每篇目标字数 4,000-8,000 字（不含代码），核心篇（第 4-8 篇）可以更长
- 代码示例优先使用 Solidity（合约分析）和 JavaScript/Python（链下工具），必须是可运行的完整代码或明确标注"简化示意"
- 涉及 Foundry 的代码，必须兼容当前环境版本
- 如果某个概念有常见的误区或陷阱，请主动指出并解释正确的理解方式
- 逆向分析相关的内容，展示"发现过程"而非只呈现"最终结论"

### 跨章节一致性

- 全系列使用统一的术语。第 1 篇生成完成后，从中提取术语表保存为 `glossary.md`，后续章节生成时参考该文件保持一致
- 引用前面章节已讲过的概念时，使用"我们在第 X 篇中介绍过"的表述
- 两个教学参照系统的名称在全系列中保持一致：
  - "Lotus Router" —— 开源 MEV 路由合约（jtriley2p）
  - "AttackContract" —— 逆向重建的攻击合约（`AttackContract.sol`），教程中所有合约分析均指向此源码
- 涉及链上部署实例时的命名约定：
  - `0x42Ecd332`（Base 链部署，nonce=53）—— 引用 Base 链攻击数据时使用此地址
  - `0xA98E339f`（13 条链部署，nonce=0）—— 引用跨链攻击数据时使用此地址
  - 两者为同一份 AttackContract 源码的不同部署（详见 `moonwell_exploit_reverse_analysis/bytecode_identity_verification.md`），教程中不再使用 "MevBot"/"AttackEngine" 作为合约名称

### 章节返工规则

当作者要求修改某篇中的特定小节时：

- 先读取该篇的完整内容
- 只替换目标小节，保持其他部分不变
- 确保修改后的小节与前后文的衔接自然
- 如果修改涉及术语或数据的变更，检查后续章节中是否有引用需要同步更新

### 事实核查

每篇章节内容生成后，必须进行三轮自查：

- **第一轮（事实性核验）**：检查所有链上数据（地址、交易哈希、利润数字、gas 数据）是否与 `moonwell_exploit_reverse_analysis/` 和 `reference/` 目录下的源文档一致
- **第二轮（描述清晰度）**：检查是否存在描述模糊、容易产生误解的表述，确保合约统一称为 AttackContract
- **第三轮（整体一致性）**：检查术语使用、利润引用口径、参照系统名称是否与全系列保持一致

## 开发环境

本项目所在的 WSL2 Ubuntu 24.04 环境已配置好以太坊开发环境：

- Foundry（forge、cast、anvil）—— 合约编译、测试、链上交互
- Heimdall-rs —— 字节码反编译与逆向分析
- Node.js + ethers.js —— 链下脚本
- Python 3 —— 数据分析脚本

教程中涉及的代码示例主要用于演示和分析（fork 测试、calldata 解码、mempool 监听等），不需要独立的项目脚手架。

## 文件组织

```
mev_bot_101/
├── CLAUDE.md                              ← 本文件（Claude Code 项目指令）
├── outline.md                             ← 教程完整目录及各章节详细说明（生成章节前必读）
├── glossary.md                            ← 术语表（第 1 篇生成后创建）
├── chapters/                              ← 各章节 Markdown 文件
│   ├── 01-mev-overview.md
│   ├── 02-mempool-and-gas.md
│   ├── 03-flashloan-and-dex.md
│   ├── 04-lotus-router.md
│   ├── 05-calldata-encoding.md
│   ├── 06-reverse-engineering.md
│   ├── 07-instruction-engine.md
│   ├── 08-security-and-infra.md
│   ├── 09-cross-chain.md
│   └── 10-build-your-router.md
├── reference/                             ← 教学参考资料（理论与开源参照物）
│   ├── lotus-router/                      ← Lotus Router 完整源码（jtriley2p）
│   │   ├── src/                           ← 合约源码（LotusRouter.sol + 类型系统 + 编解码器）
│   │   ├── test/                          ← 测试文件 + mock 合约
│   │   ├── foundry.toml
│   │   └── README.md
│   ├── lotus-router-report.md             ← Lotus Router 源码研究报告
│   ├── attack_contract_vs_lotus_router_analysis.md ← AttackContract 与 Lotus Router 对比分析
│   ├── mev-system-architecture.md         ← MEV Searcher 系统架构文档（三层框架）
│   └── Flash_Boys_2_0.pdf                 ← Flash Boys 2.0 论文（MEV 创世文献）
└── moonwell_exploit_reverse_analysis/     ← 逆向工程全部数据（事实核查数据源）
    ├── moonwell_exploit_reverse_report.md ← 综合逆向分析报告（统一视角）
    ├── bytecode_identity_verification.md  ← 字节码同一性验证（14 部署 = 1 源码）
    ├── AttackContract/                    ← 统一重建 Foundry 项目（最终成果）
    │   ├── src/AttackContract.sol         ← 统一重建源码（800+ 行，14 部署的唯一源码）
    │   ├── test/Replay*.t.sol             ← 10 套 replay 测试（141/141 PASS）
    │   └── README.md                      ← 项目说明 + 各链 WETH 地址
    ├── 0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB/ ← Base 链逆向归档（数据验证用）
    │   ├── MevBot/                        ← 早期独立重建 Foundry 项目
    │   ├── reports/                       ← 分析报告（calldata_format、attack_flow 等）
    │   └── scripts/                       ← Python 分析脚本
    └── 0xA98E339f5a0F135792286d481B4e23d91A667d3f/ ← 跨链分析证据（数据验证用）
        ├── AttackEngine/                  ← 早期跨链独立重建 Foundry 项目
        ├── reports/                       ← 逐链分类报告、字节码 diff、Phalcon trace 等
        └── scripts/                       ← 数据采集脚本
```
