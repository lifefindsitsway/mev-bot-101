# 第 2 篇：交易的一生 —— 从 Mempool 到区块打包

Base 链的正常 gas price 是多少？不到 1 gwei。绝大多数时候，用户甚至不需要关心 gas 费用——一笔普通转账的成本不过几美分。

但在 2025-11-04 UTC 凌晨，AttackContract Base 链部署（`0x42Ec...34bB`）的 12 笔攻击交易将 gas price 推到了 175 至 253 gwei——正常水平的 200 倍以上。仅这 12 笔交易的 gas 成本就达到 4.42 ETH，按当日价格约合 $15,900。这个数字听起来不小，但对比 295.75 ETH（~$1.06M）的净提取利润，gas 成本仅占 1.5%。

为什么有人愿意为一笔交易支付正常价格 200 倍的 gas？要回答这个问题，我们需要理解一笔交易从被签名到最终被打包进区块的完整生命周期，以及 MEV 如何在这个过程中的每一个环节寻找机会。

## 一笔交易的完整生命周期

当你在钱包里点击"确认"的那一刻，一笔交易的旅程才刚刚开始。它要经历六个阶段，才能最终成为区块链历史的一部分：

**第一步：签名。** 你的钱包使用私钥对交易数据进行签名——收款地址、转账金额、gas 参数、nonce、calldata，所有这些被打包成一个签名后的交易对象。此时交易还只存在于你的设备上。

**第二步：广播。** 签名后的交易被发送到你连接的 RPC 节点（Infura、Alchemy，或者你自己运行的全节点）。RPC 节点验证交易格式和签名的合法性，然后将它广播到以太坊的 P2P 网络中。

**第三步：进入 Mempool。** 交易被网络中的节点接收后，进入各自的 **Mempool**（内存交易池）。Mempool 不是一个全局统一的数据库，而是每个节点各自维护的待处理交易集合。但由于 P2P 网络的广播机制，一笔交易通常在几百毫秒内就会传播到大部分节点。

**第四步：Builder 选择。** 在当前的 PoS 以太坊中，专业的 Builder 从 mempool 中选取交易，将它们组装成一个完整的区块。Builder 的目标是最大化区块价值——优先选择愿意支付更高 gas 费的交易，同时也纳入 Searcher 提交的 bundle（我们在第 1 篇中介绍过，bundle 是 Searcher 构造的一组有序交易）。

**第五步：打包。** Builder 将组装好的区块提交给当前轮次的 Proposer（通过 MEV-Boost 中继）。Proposer 从多个 Builder 的候选区块中选择出价最高的一个，签名确认。

**第六步：确认。** 区块被广播到网络，经过其他验证者的确认，交易成为区块链永久记录的一部分。

整个过程通常在 12 秒内完成——以太坊 PoS 的出块间隔就是 12 秒。但就是在这 12 秒里，MEV 的博弈已经完成了无数轮。

## Mempool：MEV 的温床

在交易生命周期的六个阶段中，第三步——进入 mempool——是 MEV 诞生的关键时刻。

为什么？因为 mempool 在默认情况下是**公开的**。

当你的交易进入 mempool，它对所有监听 mempool 的参与者都是可见的——包括专业的 MEV Searcher。他们运行高性能的节点，实时订阅每一笔进入 mempool 的新交易，分析每笔交易可能产生的链上状态变化，计算从中可以提取多少利润。

这就像在扑克牌局中，你的手牌对所有其他玩家公开：

- 你提交了一笔大额 Uniswap swap？Searcher 看到了，可以在你之前插入一笔交易推高价格（三明治攻击的前半段）。
- 某个借贷仓位即将触及清算线？Searcher 也看到了，准备好清算交易抢在第一个执行。
- 预言机即将更新价格？Searcher 已经在计算更新后哪些协议会出现价格偏差。

Mempool 的公开性是以太坊去中心化设计的自然产物——交易需要被广播到整个网络才能被打包。但这种透明性也造就了一个信息不对称的竞技场：普通用户只是提交一笔交易然后等待确认，而 Searcher 则将每一笔待处理的交易视为潜在的获利机会。

AttackContract 在 Base 链上的攻击利用的是预言机价格偏差，不依赖于监听其他用户的交易。但理解 mempool 的公开性仍然至关重要——因为攻击者自己的交易也会暴露在 mempool 中。如果其他 Searcher 发现了同样的预言机偏差，他们可能会提交竞争交易。这就是为什么攻击者需要用 200 倍的 gas price 来抢占优先级，也是为什么整个 MEV 生态逐渐从公开 mempool 转向了私有交易通道。

## EIP-1559 与 MEV 场景下的 Gas 策略

要理解为什么攻击者愿意支付 253 gwei 的 gas price，需要先理解以太坊的 gas 定价机制。

### base fee + priority fee

自 2021 年 EIP-1559 生效以来，以太坊的 gas 费用由两部分组成：

- **Base fee（基础费用）**：由协议自动调整，取决于上一个区块的拥堵程度。base fee 会被销毁，不归任何人。
- **Priority fee（优先费/小费）**：用户自愿支付给 Builder/Proposer 的额外费用，用于激励他们优先打包自己的交易。

对普通用户来说，钱包会根据当前网络状况自动设置一个合理的 priority fee，通常只有几 gwei 甚至不到 1 gwei。只要交易在几个区块内被打包，用户就不会在意是第一个还是第三个被执行。

但 MEV 场景完全不同。

### MEV 场景：执行顺序就是一切

对 Searcher 来说，交易被打包在区块的第 1 个位置和第 10 个位置，可能意味着获利与亏损的区别。因为：

- 套利机会是瞬时的——你的交易排在前面，利润归你；排在后面，机会已经被别人吃掉
- 三明治攻击要求精确的顺序——你的前置交易必须在目标交易之前，后置交易必须在目标交易之后
- 预言机偏差是有时间窗口的——偏差可能在下一个区块就被修正

因此，Searcher 愿意为优先级支付远高于普通用户的费用。这笔额外费用的上限取决于 MEV 机会的预期利润——只要 gas 成本低于预期利润，交易就值得执行。

Base 链上的 12 笔攻击交易中，gas price 高达 175-253 gwei，总 gas 成本 4.42 ETH。但每笔交易的利润在 22-31 ETH 之间，gas 成本占比不到 2%。从纯经济学角度看，支付 200 倍 gas price 完全合理——因为不支付的后果是利润归零。

## 为什么支付 200 倍 Gas Price

我们已经知道 MEV 场景下 gas 策略与普通交易不同。但这次攻击的 gas 行为还有一个更具体的背景：**时间窗口**。

### 30 秒内的 $1.06M

2025-11-04 UTC 凌晨，Moonwell 协议使用的 wrsETH 预言机出现了严重的价格错误——偏差高达约 1657 倍。这个偏差不是永久的，一旦预言机更新，机会就会消失。攻击者面临一个极端的时间约束。

从链上数据来看，12 笔主攻击交易从 TX_01（区块 37,722,875）到 TX_12 密集地分布在一个极短的时间窗口内。攻击者选择了一个激进的策略：将 gas price 推到 175-253 gwei，确保每一笔交易都在最短时间内被打包。

作为对比，同一个攻击者在 2025-10-17 UTC 的试探性攻击中，gas price 仅为 2-4 gwei——与 Base 链正常水平一致。那一天，weETH 的预言机偏差约为 9%，相对稳定，攻击者没有面临时间压力。同样，2025-11-03 18:03 UTC 攻击 tBTC 市场时（区块 37,701,831），gas price 也是正常水平，利润仅 0.181 ETH。

| 时间 | 目标 | Gas Price | 利润 | 时间压力 |
|------|------|-----------|------|----------|
| 10/17 | weETH (Morpho) | 2-4 gwei | 0.141 ETH | 低（偏差稳定） |
| 11/03 | tBTC (Moonwell) | 2-4 gwei | 0.181 ETH | 低（偏差幅度未验证，从 0.181 ETH 的微小利润推断偏差不大） |
| 11/04 | 6 市场 (Moonwell) | 175-253 gwei | 295.75 ETH | 极高（1657x 偏差，随时修正） |

这张表清楚地展示了 gas 策略与时间压力之间的关系：偏差越大、机会越转瞬即逝，攻击者愿意支付的 gas 溢价就越高。175-253 gwei 不是盲目的出价，而是攻击者对"这个机会值多少"的实时博弈判断。

## 为什么拆分成 12 笔交易

一个自然的问题：既然攻击者要在最短时间内完成攻击，为什么不把所有操作合并成一笔交易？答案涉及多个工程约束：

### 流动性限制

每个 DEX 流动性池的深度是有限的。AttackContract 的攻击路径是"从 Moonwell 借出资产 → 在 DEX 上卖出换取 WETH"。如果一笔交易卖出太多资产，会导致严重的价格滑点，大幅减少实际收益。拆分成多笔较小的交易，每笔都在滑点可控的范围内操作，总利润反而更高。

### 多市场覆盖

Moonwell 上的不同 mToken 市场（wstETH、cbETH、EURC、AERO、USDC、cbXRP）各自独立，每个市场有不同的可借余额和对应的 DEX 出口。攻击者同时扫描了多个市场，每个市场的最优攻击参数不同，自然需要独立的交易。

12 笔交易的利润分布也证实了这一点：

| 借贷资产 | 攻击笔数 | 利润合计 (ETH) |
|----------|---------|---------------|
| wstETH | 4 | ~98.97 |
| AERO | 2 | ~49.63 |
| cbETH | 2 | ~49.34 |
| EURC | 2 | ~49.03 |
| cbXRP | 1 | ~30.79 |
| USDC | 1 | ~22.40 |

wstETH 被攻击了 4 次（而非 1 次大额交易），正是因为每次需要控制滑点。

### 风险隔离

12 笔独立交易意味着每笔交易都是原子性的——如果其中一笔因为某种原因失败（gas 不够、池子被其他交易影响、滑点超限），不会影响其他交易的执行。事实上，AttackContract 在 2025-10-17 UTC 的 VIRTUAL 市场攻击就以失败告终（revert），但同一时段的 Morpho Blue 攻击成功获利 0.141 ETH。

### 竞态防御

如果将全部攻击逻辑放在一笔巨大的交易中，该交易的 gas 消耗会非常高（12 笔交易的 gas 合计超过 2200 万），执行时间更长。在 mempool 中，一笔大交易更容易被其他 Searcher 发现并构造竞争交易。拆分成 12 笔高 gas price 的交易快速连续提交，是一种更稳健的竞态防御策略。

## 从 PGA 到 Flashbots：MEV 基础设施的六年演进

AttackContract 的 gas 策略看起来简单粗暴——"出高价抢先"。但和 6 年前的 MEV Bot 相比，它已经精密得多了。

2019 年，Flash Boys 2.0 论文记录了 **Priority Gas Auction（PGA）** 现象——多个 MEV Bot 在公开 mempool 中反复提交更高 gas price 的交易来竞争同一个机会。论文 Figure 2 展示了一个典型案例：两个 Bot 在极短时间内将 gas price 从几十 gwei 竞抬到数千 gwei，直到其中一方放弃或机会消失。

这种竞价模式有严重的副作用：大量失败交易浪费链上资源，gas 竞拍的收益完全归矿工（当时还是 PoW），而且竞价本身是公开的——任何人都能看到、模仿甚至抢跑。

Flashbots 的诞生彻底改变了这个格局。从 2020 年开始，Flashbots 团队构建了一套 MEV 的"有序提取"基础设施：Searcher 不再在公开 mempool 中竞价，而是通过**私有通道**直接向 Builder 提交 bundle。Builder 评估所有 bundle 的价值，将最有利可图的组合打包进区块。这个过程对公开 mempool 完全不可见。

AttackContract 的设计正是这个演进的产物。来看它的 `approve()` 函数中的利润分配逻辑：

```solidity
// AttackContract.sol - approve() 函数中的利润分配（简化）
uint256 callerPayment = 0;
if (flags != 0) {
    callerPayment = flags;
    // to == address(0) 时，tip 自动发给当前区块的 Builder
    address recipient = to == address(0) ? block.coinbase : to;
    // 防止 drain：最多支付利润的 66%
    uint256 maxPayment = postBalance * 66 / 100;
    if (callerPayment > maxPayment) callerPayment = maxPayment;
    _sendETH(recipient, callerPayment);
}
// 剩余利润全部发给硬编码的攻击者地址
_sendETH(PROFIT_RECEIVER, postBalance - callerPayment);
```

这段代码揭示了一个关键机制：`block.coinbase` 贿赂。在 PoS 以太坊中，`block.coinbase` 返回当前区块 Builder 的 fee recipient 地址。当以 `approve(address(0), 0)` 调用时（`to == address(0)`，`flags == 0`），不支付 Builder tip，所有利润归攻击者。但如果通过私有通道提交并需要 Builder 优先打包，攻击者可以设置非零的 `flags` 值，将指定金额的 ETH 直接转给 Builder。

这比 PGA 时代精密得多：
- **不公开竞价**：交易通过私有通道提交，其他 Searcher 看不到
- **精确定价**：`flags` 参数直接指定 tip 的 wei 金额，而非通过 gas price 间接竞价
- **利润保护**：最多支付 66% 的利润作为 tip，确保攻击者至少保留 34%

同一份合约在其他链上将这种机制推到了更大的规模：Ethereum 链部署向 Titan Builder 支付了 43.82 ETH 的 builder tip（按当时价格约 $196,651）。这些都不是通过 gas price 竞价完成的，而是通过 `block.coinbase` 直接转账。

从 2019 年两个 Bot 在 mempool 中疯狂加价到 8856 gwei，到 2025 年 AttackContract 在私有通道中精确支付 builder tip——MEV 的基础设施在 6 年间经历了根本性变革。公开的无序竞争被替换为与 Builder 的直接交易，但利润提取的本质没有改变：谁能更快发现机会、更准确地定价、更可靠地执行，谁就能拿到利润。

## 动手环节

### 任务 1：用 ethers.js 监听 Mempool 中的 Pending 交易

以下脚本连接到一个支持 WebSocket 的以太坊节点，订阅所有 pending 交易，并过滤出与 Uniswap 系列路由合约交互的交易。这是 MEV Searcher 构建机会发现系统的第一步。

```javascript
// mempool-watcher.js
// 用法: node mempool-watcher.js
// 需要: npm install ethers@6
// 注意: 需要支持 WebSocket 的节点 URL（Infura/Alchemy 的免费层即可）

const { ethers } = require("ethers");

// ========== 配置 ==========
// 替换为你自己的 WebSocket RPC URL
const WS_URL = "wss://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY";

// Uniswap 相关合约地址（小写）
const WATCH_LIST = {
    "0xe592427a0aece92de3edee1f18e0157c05861564": "Uniswap V3 Router",
    "0x3fc91a3afd70395cd496c647d5a6cc9d4b2b7fad": "Universal Router",
    "0x7a250d5630b4cf539739df2c5dacb4c659f2488d": "Uniswap V2 Router",
    "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45": "SwapRouter02",
};

async function main() {
    const provider = new ethers.WebSocketProvider(WS_URL);
    console.log("已连接到节点，开始监听 pending 交易...\n");

    let txCount = 0;
    let targetCount = 0;
    const MAX_DETAIL = 10; // 只打印前 10 笔命中交易的详情
    let detailPrinted = 0;

    // 订阅 pending 交易
    provider.on("pending", async (txHash) => {
        txCount++;

        try {
            const tx = await provider.getTransaction(txHash);
            if (!tx || !tx.to) return;

            // 匹配 Uniswap 路由合约
            const toAddr = tx.to.toLowerCase();
            const label = WATCH_LIST[toAddr];

            if (label) {
                targetCount++;

                if (detailPrinted < MAX_DETAIL) {
                    detailPrinted++;
                    const gasPrice = tx.gasPrice
                        ? ethers.formatUnits(tx.gasPrice, "gwei")
                        : "N/A";
                    const maxFee = tx.maxFeePerGas
                        ? ethers.formatUnits(tx.maxFeePerGas, "gwei")
                        : "N/A";
                    const priorityFee = tx.maxPriorityFeePerGas
                        ? ethers.formatUnits(tx.maxPriorityFeePerGas, "gwei")
                        : "N/A";

                    console.log(`[#${targetCount}] 发现目标交易! → ${label}`);
                    console.log(`  Hash:         ${txHash}`);
                    console.log(`  From:         ${tx.from}`);
                    console.log(`  Gas Price:    ${gasPrice} gwei`);
                    console.log(`  Max Fee:      ${maxFee} gwei`);
                    console.log(`  Priority Fee: ${priorityFee} gwei`);
                    console.log(`  Calldata:     ${tx.data.length / 2 - 1} bytes`);
                    console.log(`  Selector:     ${tx.data.slice(0, 10)}`);
                    console.log(`  Value:        ${ethers.formatEther(tx.value)} ETH`);
                    console.log("");
                }
            }

            // 每 1000 笔交易打印统计
            if (txCount % 1000 === 0) {
                console.log(
                    `--- 已扫描 ${txCount} 笔 pending 交易, ` +
                    `命中 Uniswap 交易 ${targetCount} 笔 ---\n`
                );
            }
        } catch (err) {
            // 交易可能在获取前已被打包, 忽略
        }
    });

    // 优雅退出
    process.on("SIGINT", () => {
        console.log(
            `\n监听结束. 共扫描 ${txCount} 笔交易, 命中目标 ${targetCount} 笔.`
        );
        provider.destroy();
        process.exit(0);
    });
}

main().catch(console.error);
```

**运行步骤**：

1. 注册 Alchemy 或 Infura 账号，获取 WebSocket URL
2. 替换脚本中的 `WS_URL`
3. 执行：

```bash
npm install ethers@6
node mempool-watcher.js
```

**预期输出**：

```
已连接到节点，开始监听 pending 交易...

[#1] 发现目标交易! → Uniswap V2 Router
  Hash:         0x7262...98ea
  From:         0xfDD9...Dd60
  Gas Price:    0.042107168 gwei
  Max Fee:      N/A gwei
  Priority Fee: N/A gwei
  Calldata:     228 bytes
  Selector:     0x7ff36ab5
  Value:        0.07 ETH

[#2] 发现目标交易! → SwapRouter02
  Hash:         0xbb3b...5551
  From:         0x2766...E137
  Gas Price:    0.038829051 gwei
  Max Fee:      N/A gwei
  Priority Fee: N/A gwei
  Calldata:     260 bytes
  Selector:     0xb858183f
  Value:        0.0 ETH

--- 已扫描 1000 笔 pending 交易, 命中 Uniswap 交易 3 笔 ---
```

**观察要点**：

- 脚本同时监听 4 个 Uniswap 路由合约（V2 Router、V3 Router、SwapRouter02、Universal Router），输出会标注命中的具体合约
- 注意 `Priority Fee` 的分布——普通用户的 Priority Fee 通常不超过 0.01 gwei，而 AttackContract 攻击交易的 Priority Fee 高达 175-253 gwei，是正常水平的数万倍
- 如果你幸运地捕捉到一笔 MEV 交易，它的 `Priority Fee` 可能是普通交易的数十甚至数百倍
- 常见 Selector：`0x7ff36ab5` 是 V2 Router 的 `swapExactETHForTokens()`（用 ETH 买币），`0x791ac947` 是 `swapExactTokensForETHSupportingFeeOnTransferTokens()`（卖币换 ETH）
- 你正在看到的，和 MEV Searcher 看到的，是同一个 mempool

### 任务 2：用 cast 查看 AttackContract 攻击交易的 Gas 数据

使用 Foundry 的 `cast` 命令行工具，直接查询链上数据：

```bash
# 查看 TX_01 的交易详情
cast tx 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  --rpc-url https://mainnet.base.org

# 查看该交易的 gas 使用情况
cast receipt 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  --rpc-url https://mainnet.base.org

# 对比: 查看同一区块的 base fee
cast block 37722875 baseFeePerGas --rpc-url https://mainnet.base.org
```

**思考**：将查到的 `effectiveGasPrice` 与该区块的 `baseFeePerGas` 相减，得到的就是攻击者实际支付的 priority fee。它是正常水平的多少倍？

### 任务 3：观察 Gas Price 对比

将你在任务 1 中观察到的普通交易 priority fee 与 AttackContract 的 175-253 gwei 放在一起，思考以下问题：

1. 假设你是这个 Searcher，预言机偏差可能在 30 秒内被修正，你愿意为一笔预期利润 25 ETH 的交易支付多少 gas？
2. 如果你出价 175 gwei 但另一个 Searcher 出价 253 gwei，会发生什么？
3. 如果你可以通过私有通道直接向 Builder 提交交易（而不是在公开 mempool 中竞价），你的 gas 策略会有什么不同？

**参考分析**：

**问题 1**：关键约束是 **30 秒时间窗口**。Base 链出块时间 2 秒，意味着最多 15 个区块的机会。从 TX_01 的链上数据倒推攻击者的实际决策——30.79 ETH 利润对应 ~0.386 ETH gas 成本，成本/利润比仅 1.25%。如果预期利润 25 ETH，按同样比例，gas 预算约 0.31 ETH。但这个比例不是固定的：竞争越激烈、窗口越短，愿意支付的比例越高。理论上限是 25 ETH（全部利润），实际上限取决于你对机会被抢走的概率估计。一个理性 Searcher 的出价逻辑大致是：

> 愿付 gas = 预期利润 × (1 - 机会被抢概率) - 安全边际

攻击者实际只花了利润的 ~1.25%，说明在那个时刻面临的竞争压力并不大——235 gwei 虽然是普通交易的 23 万倍，但相对于 30 ETH 的利润而言非常便宜。

**问题 2**：取决于提交通道。在公开 mempool 场景（PGA 时代），Sequencer/Builder 按 priority fee 排序，253 gwei 的交易排在前面——如果这是一个先到先得的机会（比如清算），你的 175 gwei 交易会落后于对手被打包，等你执行时机会已被消耗，交易 revert，白白浪费 gas。在私有通道场景（Flashbots 时代），Builder 收到两个 bundle，对比谁给的 tip 更高，253 gwei 的 bundle 产生更多 builder 收入，你的 bundle 被直接丢弃——不上链、不消耗 gas，但机会归对手。从我们在任务 2 中查到的同区块数据看，TX_01 的 priority fee 是区块内第二高交易的 6.7 倍，说明攻击者用绝对优势碾压而非边际竞价。

**问题 3**：

| 维度 | 公开 Mempool（PGA） | 私有通道（Flashbots） |
|---|---|---|
| 失败成本 | 交易上链 revert，**白付 gas** | Bundle 被丢弃，**零成本** |
| 信息泄露 | 出价公开可见，对手可跟价加价 | 出价仅 Builder 可见，对手无法跟价 |
| 定价策略 | 被迫持续加价（军备竞赛） | 一次性精确出价 |
| 最优策略 | 尽可能快地加价到利润上限 | 给 Builder 刚好足够有吸引力的 tip |

私有通道下你可以更从容——不用担心被抢跑或信息泄露，可以精确计算一个合理的 builder tip 而非盲目加价。AttackContract 实际使用的就是这种模式：gas 成本只占利润的 ~1.5%（4.42 ETH / 295.75 ETH），而 2019 年 PGA 时代那两个 Bot 曾把 gas 价格竞争到 8,856 gwei，大量利润被浪费在 gas 竞价上。这正是从 PGA 到 Flashbots 的核心演进：将无序的公开竞价变为与 Builder 的一对一精确定价。

## 小结

一笔交易从签名到被打包进区块，要经历签名、广播、mempool、Builder 选择、打包和确认六个阶段。MEV 的博弈主要发生在 mempool 和 Builder 选择这两个环节——交易的公开可见性创造了信息优势，交易排序的可操控性创造了利润空间。

AttackContract 的 gas 策略是一个完美的实证：正常水平 200 倍的 gas price 不是浪费，而是对 30 秒时间窗口的精确定价。4.42 ETH 的 gas 成本换来 295.75 ETH 的净利润，投资回报率接近 67 倍。而从 2019 年 PGA 时代的公开 mempool 竞价，到 2025 年通过 `block.coinbase` 直接向 Builder 支付 tip，MEV 的基础设施演进让利润提取变得更加精密和高效。

**下一篇**：第 3 篇《闪电贷与 DEX——MEV 的两大基础设施》，我们将深入 AttackContract 的攻击路径内部——闪电贷如何让攻击者"空手套白狼"，以及 V2 和 V3 DEX 的两种 swap 范式为什么决定了 MEV 路由合约的回调架构。
