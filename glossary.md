# 术语表（Glossary）

> 本文件在第 1 篇生成后创建，后续章节生成时参考此表保持术语一致。随章节推进持续更新。

## MEV 核心概念

| 术语 | 英文 | 定义 | 首次出现 |
|------|------|------|----------|
| MEV | Maximal Extractable Value | 最大可提取价值。区块生产者（或能影响交易排序的参与者）通过对交易进行排序、插入或审查所能提取的利润。最初由 Flash Boys 2.0 论文定义为 Miner Extractable Value，后更名为 Maximal。 | 第 1 篇 |
| DEX 套利 | DEX Arbitrage | 在两个或多个 DEX 之间利用同一代币的价格差异进行买卖获利。被视为"良性 MEV"。 | 第 1 篇 |
| 三明治攻击 | Sandwich Attack | 在目标交易前后分别插入买入和卖出交易，从价格滑点中获利。直接损害普通用户利益。 | 第 1 篇 |
| 清算 | Liquidation | 当借贷协议中借款人的抵押品价值跌破清算线时，代为清算并获取清算奖励。 | 第 1 篇 |
| 预言机套利 | Oracle Arbitrage | 利用预言机报价与真实市场价格之间的偏差，通过借贷和 DEX 交易提取利润。AttackContract 案例的攻击类型。 | 第 1 篇 |

## MEV 供应链

| 术语 | 英文 | 定义 | 首次出现 |
|------|------|------|----------|
| Searcher | Searcher（搜索者） | MEV 供应链的起点。运行机会发现系统，监听 mempool 和链上状态，构造 bundle 提交给 Builder。 | 第 1 篇 |
| Builder | Builder（构建者） | 收集 Searcher 的 bundle 和普通交易，组装成完整区块并提交给 Proposer。 | 第 1 篇 |
| Proposer | Proposer（提议者） | PoS 以太坊中被随机选中的验证者，从 Builder 提交的候选区块中选择一个进行提议。 | 第 1 篇 |
| Bundle | Bundle（交易束） | 一组必须按特定顺序执行的交易，由 Searcher 构造并提交给 Builder。 | 第 1 篇 |
| PGA | Priority Gas Auction | 优先 Gas 竞拍。早期 MEV Bot 在公开 mempool 中通过不断提高 gas price 竞价的现象。由 Flash Boys 2.0 论文首次描述。 | 第 1 篇 |

## 两个教学参照系统

| 名称 | 说明 | 首次出现 |
|------|------|----------|
| Lotus Router | jtriley2p 编写的开源 MEV 路由合约。教科书级的 Calldata 驱动 VM 实现，12 个操作码。用于正向理解设计模式。 | 第 1 篇 |
| AttackContract | 逆向重建的跨链攻击合约（`AttackContract.sol`，800+ 行）。链上部署实例：Base 链 `0x42Ecd332`（nonce=53）+ 几乎所有主要 EVM 链 `0xA98E339f`（nonce=0），经字节码同一性验证确认为同一份源码。24,543 字节 runtime，42 个函数（45 dispatch 入口），12 个自定义操作码。总利润 ~$4.63M（14 个部署，涵盖 13 条链）。141 笔 mainnet fork replay 全部 PASS。 | 第 1 篇 |

## 技术术语

| 术语 | 英文 | 定义 | 首次出现 |
|------|------|------|----------|
| Calldata | Calldata | 交易中携带的输入数据，包含函数选择器和参数。MEV 路由合约使用自定义编码的 calldata 来传递指令序列。 | 第 1 篇 |
| 函数选择器 | Function Selector | 函数签名的 Keccak-256 哈希的前 4 个字节，用于标识调用的目标函数。 | 第 1 篇 |
| Mempool | Mempool（交易池） | 已广播但尚未被打包进区块的待处理交易的集合。MEV 的主要信息来源。 | 第 1 篇 |
| 闪电贷 | Flash Loan | 同一笔交易内借入并归还资金的无抵押贷款机制。归还失败则整笔交易回滚。 | 第 1 篇 |
| Builder Tip | Builder Tip | Searcher 向 Builder 支付的费用，以确保自己的 bundle 被优先纳入区块。 | 第 1 篇 |
| Calldata 驱动 VM | Calldata-driven VM | MEV 路由合约的核心设计范式：将攻击逻辑编码为 calldata 中的指令序列，合约内置虚拟机逐条解码执行。 | 第 1 篇 |
| Base Fee | Base Fee（基础费用） | EIP-1559 引入的 gas 费用组成部分，由协议根据区块拥堵程度自动调整，会被销毁。 | 第 2 篇 |
| Priority Fee | Priority Fee（优先费） | EIP-1559 中用户自愿支付给 Builder/Proposer 的额外 gas 费用，用于激励优先打包。MEV 场景下远高于普通交易。 | 第 2 篇 |
| block.coinbase | block.coinbase | Solidity 全局变量，返回当前区块 Builder 的 fee recipient 地址。AttackContract 用它实现向 Builder 的链上直接转账（贿赂）。 | 第 2 篇 |
| Flashbots Protect | Flashbots Protect | Flashbots 提供的私有交易提交服务，交易不经过公开 mempool，防止被 MEV Bot 抢跑或三明治攻击。 | 第 2 篇 |
| MEV-Boost | MEV-Boost | Flashbots 构建的中间件，连接 Builder 和 Proposer，让 Proposer 可以从多个 Builder 的候选区块中选择出价最高的。 | 第 2 篇 |
| 原子性 | Atomicity | 以太坊交易的核心特性：一笔交易中的所有操作要么全部成功，要么全部失败回滚。闪电贷的安全性依赖于此。 | 第 3 篇 |
| 回调模式 | Callback Pattern | 协议在执行过程中调用用户合约的指定函数，用于闪电贷（"资金到账，执行你的逻辑"）和 V3 swap（"交易完成，转账你的欠款"）。 | 第 3 篇 |
| V2 Swap | V2 Swap（先转后 swap） | Uniswap V2 范式：调用者先将输入代币 transfer 到池子，再调用 swap()。无回调，同步完成。 | 第 3 篇 |
| V3 Swap | V3 Swap（回调模式） | Uniswap V3 范式：调用者调用 swap()，池子通过回调函数收取输入代币。支持多跳路由和灵活资金来源。 | 第 3 篇 |
| sqrtPriceLimitX96 | sqrtPriceLimitX96 | Uniswap V3 swap 中的价格滑点保护参数。Q64.96 定点数格式表示的价格平方根。AttackContract 使用极限值（不限制滑点）。 | 第 3 篇 |
| 恒定乘积公式 | Constant Product Formula | Uniswap V2 的 AMM 核心公式 x·y=k。投入越多，单位产出越低（价格滑点）。 | 第 3 篇 |
| 有符号 Delta | Signed Delta | V3 风格 swap 回调中的参数语义：正数 = 调用者欠池子（需付出），负数 = 池子付给调用者（已收到）。Algebra 等协议采用相同语义。 | 第 3 篇 |
| fallback() | fallback() | Solidity 特殊函数，在没有匹配到任何函数选择器时触发。Lotus Router 用它作为主入口，绕过 ABI 编码开销。 | 第 4 篇 |
| findPtr() | findPtr() | Lotus Router 的指令指针恢复机制。根据 msg.sig 判断当前入口类型（直接调用/V2 回调/V3 回调），返回 calldata 中指令流的起始偏移。 | 第 4 篇 |
| 递归回调模型 | Recursive Callback Model | Lotus Router 的核心架构：将未执行的指令作为 data 参数传入 swap/flash 调用，在回调中通过 findPtr() 恢复指针继续执行。执行顺序与编码顺序反向。 | 第 4 篇 |
| canFail | canFail | Lotus Router 的操作级容错标志。当 canFail=true 时，操作失败不终止执行循环。适用于多路径探测。AttackContract 不支持此机制，使用硬性 require。 | 第 4 篇 |
| BBC 编码 | BBC Encoding（Big Brain Chad） | Lotus Router 的自定义 calldata 压缩编码，灵感来自 bigbrainchad.eth 的 calldata schema。用 1 字节长度前缀 + 去前导零的紧凑值替代 ABI 的 32 字节固定宽度，压缩率可达 77%。 | 第 4 篇 |
| Scratch Space | Scratch Space | EVM 内存 0x00-0x3f（64 字节）区域，Solidity 保留用于临时计算。Lotus Router 直接在此构造 calldata 以节省内存分配开销。 | 第 4 篇 |
| DynCall | DynCall | Lotus Router 操作码 0x0b，可调用任意合约的任意函数。类似 AttackContract 的 RAW_CALL（0x09），是可扩展性的关键。 | 第 4 篇 |
| signextend | signextend | EVM 原生指令，将短字节的有符号数正确扩展为 int256。BBC 编码中解码 int256 参数时必须使用，否则负数会被解释为大正数。 | 第 5 篇 |
| 固定宽度编码 | Fixed-width Encoding | AttackContract 的 calldata 编码方案。按类型固定字段宽度（地址 20B、uint256 32B、uint16 2B），不使用长度前缀。解码简单但压缩率不如 BBC。 | 第 5 篇 |
| amount 寄存器 | Amount Register | AttackContract 的有状态设计。一个跨指令共享的 uint256 变量，通过 BALANCE_OF（0x07）、REGISTER_COPY（0x05）、SET_OR_MIN（0x06）、SUB_BALANCE（0x08）等操作码读写。Lotus Router 无此机制（无状态）。 | 第 5 篇 |
| Calldata 驱动逆向 | Calldata-driven Reverse Engineering | 用真实交易的 calldata 逐字节对照执行 trace，推断操作码编码格式和字段含义的逆向方法。比依赖反编译器伪代码更精确。 | 第 6 篇 |
| 跳板架构 | Trampoline Architecture | AttackContract 的选择器分发设计：45 个 dispatch 入口通过薄包装器汇聚到少数真实实现（7 个主要目标覆盖 37 个选择器，其余 8 个路由到较小的实现）。解决回调签名爆炸导致的代码膨胀。 | 第 6 篇 |
| vm.etch | vm.etch | Foundry 作弊码，用指定字节码覆盖某地址的合约代码。逆向验证中用于将重建字节码注入原始合约地址进行 fork 重放。 | 第 6 篇 |
| CALL_WITH_AMOUNT | CALL_WITH_AMOUNT | AttackContract 操作码 0x0a。构造 `[prefix] + [amount] + [trail_data]` 格式的 calldata，通过 trail 字段（2 字节 uint16）指定额外参数长度，实现同一操作码适配不同协议 ABI（如 Moonwell trail=0，Morpho Blue trail=96）。 | 第 7 篇 |
| CALL_WITH_CHECK | CALL_WITH_CHECK | AttackContract 操作码 0x0b。执行外部调用并对返回值进行条件断言（4 种比较：EQ/GTE/LT/NEQ）。相比 Lotus Router 的纯执行成功/失败判断，支持链上条件验证。 | 第 7 篇 |
| 线性回调模型 | Linear Callback Model | AttackContract 的回调架构：闪贷回调中按编码顺序逐条执行全部指令，swap 回调仅转账欠款。编码顺序与执行顺序一致。与 Lotus Router 的递归回调模型形成对比。 | 第 7 篇 |
| approve() 包装器 | approve() Wrapper | AttackContract 的攻击入口函数。借用 ERC-20 的 `approve(address,uint256)` 签名隐藏攻击载荷，内建五层安全机制：反重放、利润保证、WETH 转换、Builder 贿赂、硬编码收款。 | 第 8 篇 |
| 反重放 | Anti-Replay | AttackContract 使用 `msg.value` 作为区块号约束（而非转账金额），配合 `flags & 0x02` 位控制方向：默认要求 `msg.value <= block.number`（不早于约束），`flags & 0x02 != 0` 时要求 `msg.value > block.number`（deadline 约束）。防止交易在错误时间窗口执行。 | 第 8 篇 |
| ops 函数 | ops Function | AttackContract 内置的运维函数（选择器 `0x725f071c`），存在于所有部署的字节码中，但仅在 BNB 链（24 笔）和 Ethereum 链（1 笔）被实际调用。批量向子 EOA 补充 gas 费，揭示了多 EOA 协作的攻击组织架构。 | 第 8 篇 |
| time-bandit attack | Time-bandit Attack | Flash Boys 2.0 论文提出的威胁模型：验证者可以回溯区块链历史，重组过去的区块以重新提取 MEV 机会。MEV 对共识层安全最激进的威胁形式。 | 第 8 篇 |
| MEV-Share | MEV-Share | Flashbots 推出的 Order Flow Auction 机制。让原始交易的用户也能分享 MEV 收益，推动 MEV 生态从"纯攻击性"向"价值共享"演进。 | 第 8 篇 |
| Calldata 模板化 | Calldata Templatization | 将攻击 calldata 分为固定部分和可变部分，通过参数替换快速生成针对不同目标的交易。AttackContract Base 链部署的 12 笔主攻击共享同一 932B 模板，仅 73B（7.8%）根据目标市场变化。 | 第 9 篇 |
| immutable | immutable | Solidity 变量修饰符，值在部署时通过 constructor 写入字节码（非存储槽）。AttackContract 将 WETH 声明为 immutable，实现同一份编译产物部署到所有链（仅 constructor 参数不同）。 | 第 9 篇 |
