# 第 8 篇：安全机制与 MEV 基础设施

在区块浏览器上搜索 AttackContract 的任意一笔攻击交易，你会看到一个看起来完全无害的函数调用：`approve(address, uint256)`。方法名是 ERC-20 标准的授权函数，参数是一个地址和一个数值——与你日常授权 DEX 花费代币的操作没有任何区别。但点开 Input Data 面板，你会发现 calldata 远比标准 approve 的 68 字节长得多——TX_01 的 calldata 长达 932 字节。这额外的 864 字节，就是我们前六篇解析过的完整指令序列：闪贷、铸造、借款、swap、还款。

这种"用合法函数签名包裹攻击载荷"的设计不是巧合。它是 AttackContract 安全架构的第一层——**伪装**。而 Lotus Router 的 `fallback()` 入口完全没有这种伪装——任何看到函数调用的人都知道这不是标准 ABI。本篇系统对比两种安全哲学，深入 `approve()` 包装器的五层安全机制，通过 `flags` 参数语义修正的完整故事展示逆向工程中"假设→验证→修正"的方法论，并回顾从 PGA 到 Flashbots 的 MEV 基础设施演进。

## 两种安全哲学："组件" vs "自治系统"

我们在第 7 篇末尾预告了这个对比。两套参照系统在安全设计上的差异不是程度差异，而是**类型差异**——源于它们对"合约是什么"的根本不同理解。

### Lotus Router：纯组件

Lotus Router 的设计哲学是"我只是一个执行工具"：

- **无权限控制**：任何人都可以调用 `fallback()` 执行指令
- **无利润保护**：合约不检查执行后余额是否增加
- **无硬编码收款地址**：没有 `PROFIT_RECEIVER`，利润去向完全由指令序列决定
- **无 Builder 贿赂**：不涉及 `block.coinbase` 或 Flashbots 集成
- **无反重放**：同样的 calldata 可以被任何人在任何区块重复提交

这不是"安全缺失"——这是有意为之的设计选择。Lotus Router 的定位是一个**可嵌入的执行层组件**，安全机制应该由调用它的上层系统负责。就像 Linux 的 `exec()` 系统调用不会检查你执行的程序是否合法——那是用户空间的责任。

### AttackContract：自治系统

AttackContract 的设计哲学截然不同——"我是一个完整的攻击系统，必须自我保护"：

- **approve() 包装器**：所有攻击都通过这个入口，强制执行五层安全检查
- **硬编码收款**：利润接收地址 `0x6997...58ff` 以 `PUSH20` 指令写死在字节码中，无法被 calldata 覆盖
- **反重放保护**：使用 `msg.value` vs `block.number` 限制交易执行窗口
- **利润保证**：`require(postBalance > preBalance)` 确保每笔交易必须盈利
- **Builder 贿赂**：通过 `block.coinbase` 向 Builder 支付包含费，确保交易被优先打包

| 维度 | Lotus Router（组件） | AttackContract（自治系统） |
|------|-------------------|----------------------------|
| 调用权限 | 任何人 | 任何人（但利润硬编码） |
| 利润去向 | 由指令决定 | 硬编码 `0x6997...58ff` |
| 执行后检查 | 无 | `require(postBalance > preBalance)` |
| 反重放 | 无 | `msg.value` vs `block.number` |
| Builder 集成 | 无 | `block.coinbase` 直接转账 |
| 失败成本 | 链下承担 | 链上 revert 保护 |

注意一个微妙但重要的点：AttackContract 的 `approve()` 函数是 `external payable`，**没有 `onlyOwner` 修饰符**。任何人都可以调用它。但这并不意味着任何人都能从中获利——`PROFIT_RECEIVER` 硬编码为攻击者的地址，即使你成功执行了攻击逻辑，利润也会被发送到攻击者的钱包。这是一种"开放执行、锁定收益"的模型。

## approve() 安全包装器：五层防护

让我们逐层解析 AttackContract 的 `approve()` 函数（`reference/mixed_contract/src/AttackContract.sol`）：

```solidity
function approve(address to, uint256 flags) external payable {
    // === 第 1 层：反重放 ===
    if (msg.value > 0) {
        if (flags & 0x02 != 0) {
            require(msg.value > block.number);  // 未来区块号之前有效
        } else {
            require(msg.value <= block.number); // msg.value 区块号已到达
        }
    }

    // === 第 2 层：记录执行前状态 ===
    uint256 preBalance = address(this).balance;

    // === 第 3 层：执行攻击 ===
    _execCalldataChunk(0x64);   // 指令集 1：闪贷 + 攻击逻辑
    _execCalldataChunk(0x84);   // 指令集 2：利润提取

    // === 第 4 层：WETH → ETH + 利润保证 ===
    uint256 wethBal = WETH.balanceOf(address(this));
    if (wethBal > 0) WETH.withdraw(wethBal);
    uint256 postBalance = address(this).balance;
    require(postBalance > preBalance);  // 必须盈利

    // === 第 5 层：利润分配 ===
    uint256 callerPayment = 0;
    if (flags != 0) {
        callerPayment = flags;  // flags 直接作为 wei 金额
        address recipient = to == address(0) ? block.coinbase : to;
        uint256 maxPayment = postBalance * 66 / 100;  // 上限 66%
        if (callerPayment > maxPayment) callerPayment = maxPayment;
        _sendETH(recipient, callerPayment);
    }
    _sendETH(PROFIT_RECEIVER, postBalance - callerPayment);
}
```

### 第 1 层：反重放

`msg.value` 在这里不是用来转账的——它被**重新定义**为区块号截止时间：

- `flags & 0x02 == 0`（默认）：要求 `msg.value <= block.number`，即"msg.value 指定的区块号已到达才执行"（不早于约束）
- `flags & 0x02 != 0`：要求 `msg.value > block.number`，即"在 msg.value 指定的未来区块号之前执行"（deadline 约束）

这个机制的目的是防止攻击交易在错误的时间窗口被执行。MEV 机会通常只在极短的时间内存在——比如 AttackContract 的预言机套利窗口只有约 30 秒（Base 链出块时间 2 秒，约 15 个区块）。如果交易在机会消失后才被打包，`require` 会让交易 revert，避免无谓的 gas 消耗。

用 `msg.value` 而非常规参数来传递截止时间是刻意的——它使 calldata 中不出现可变的时间参数，保持指令序列的稳定性。

### 第 2-3 层：执行

`preBalance` 记录执行前的 ETH 余额。然后依次执行两个指令集——我们在第 6 篇和第 7 篇中详细分析过的指令引擎。

### 第 4 层：利润保证

执行完毕后，先将所有 WETH 转换为 ETH（因为利润可能以 WETH 形式存在），然后强制检查：

```solidity
require(postBalance > preBalance);
```

如果攻击没有产生利润（比如预言机偏差已被修正），整笔交易 revert。这是一个"全有或全无"的保护——宁可损失 gas 费，也不执行亏损的攻击。配合第 7 篇讨论过的 `require(ok)` 容错策略，AttackContract 的设计哲学是：确定性路径上的任何失败都意味着整条路径不可行。

### 第 5 层：利润分配与 Builder 贿赂

利润分配逻辑涉及三个参与方：

1. **Caller（调用者）**：当 `flags != 0` 时，`flags` 值直接作为 `callerPayment`（wei），支付给 `to` 地址或 `block.coinbase`
2. **Builder**：当 `to == address(0)` 时，caller payment 发送给 `block.coinbase`——即当前区块的 Builder
3. **PROFIT_RECEIVER**：所有剩余 ETH 发送给硬编码地址 `0x6997...58ff`

66% 的上限保护是一个安全阀——即使 `flags` 被设置为一个极大的值，也最多只支付 66% 的利润作为 Builder tip，确保 `PROFIT_RECEIVER` 至少收到 34%。

我们在第 2 篇中介绍过 `block.coinbase` 贿赂的基本原理。现在可以看到它在生产级合约中的完整实现：

```solidity
address recipient = to == address(0) ? block.coinbase : to;
```

当攻击者通过 Flashbots 或其他 MEV 通道提交交易时，将 `to` 设为 `address(0)`，`flags` 设为愿意支付的 tip 金额。Builder 看到这笔交易会产生利润（通过模拟执行），并且其中一部分利润会直接流入自己的 `coinbase` 地址，因此有动力将交易纳入区块。

AttackContract 在多链部署中实际使用了这个机制。Ethereum 链的 7 笔攻击交易向 Titan Builder 支付了 43.82 ETH（约 $196,651），Arbitrum 链向 Arbitrum MEV 支付了 3.80 ETH（约 $17,053）。这些 Builder tip 的金额可以从链上的 `block.coinbase` 转账记录中精确验证。

## flags 语义修正：逆向中的"假设→验证→修正"

`flags` 参数的真实语义经历了一次完整的认知修正过程。这个故事本身就是逆向工程方法论的最佳教材。

### 初始假设：gas 补偿位域

在逆向 AttackContract 字节码时，我们发现了一段与 `flags` 相关的计算逻辑：

```
(gasUsed + 50000) * DUP11
```

这看起来像是一个 gas 补偿公式——将实际消耗的 gas 加上 50,000 的缓冲，乘以某个价格系数，计算出应支付给 Builder 的费用。基于这个发现，初始假设是：

> flags 是一个 gas 补偿位域。合约根据实际 gas 消耗动态计算 Builder tip。

这个假设在直觉上很合理——MEV Bot 为什么不根据 gas 消耗来计算 tip 呢？固定金额不是更容易多付或少付吗？

### Replay 差异

但当我们在 Ethereum 链上进行交易重放验证时，发现了一个不一致：

- 重放交易的利润与链上实际利润之间存在微小差异
- 差异的大小恰好等于 `flags` 参数的值
- 差异精确到 **wei 级别**

如果 `flags` 是一个 gas 补偿位域，那么 `callerPayment` 应该等于 `(gasUsed + 50000) * gasPrice` 的某种计算结果。但实际差异精确匹配 `flags` 的原始值——不是任何计算的结果，就是 `flags` 本身。

### Wei 级验证

对多笔 Ethereum 链交易的逐一验证确认了修正后的语义：

```
callerPayment = flags    // 不是 (gasUsed + 50000) * xxx
```

字节码中确实存在 `(gasUsed + 50000) * DUP11` 的计算逻辑，但 replay 验证表明它没有被实际使用——可能是编译器优化的残留代码，也可能是被条件分支跳过的未激活路径。

### 修正后的理解

```solidity
// 错误理解：flags 是 gas 补偿位域
callerPayment = calculateGasCompensation(gasUsed, flags);

// 正确理解：flags 直接作为 callerPayment (wei)
callerPayment = flags;
```

这个修正看起来很小——只是一行赋值的区别。但它揭示了一个重要的逆向工程原则：**字节码中存在的代码不一定被执行**。编译器优化、条件分支、废弃代码路径都可能在字节码中留下痕迹。只有 replay 验证——用真实交易的输入在 fork 环境上执行，对比链上实际结果——才能确认哪些代码路径真正被使用。

在 `reference/mixed_contract/src/AttackContract.sol` 的注释中可以看到修正后的记录：

```solidity
// flags = callerPayment (direct wei amount, NOT gas bitfield)
// Verified via AttackContract Ethereum replay: profit diff == flags at wei precision
```

这个经验可以推广为一条逆向方法论原则：

> 初始假设经常是错的。逆向工程不是一次性的"看懂字节码"，而是"假设→重放→比对→修正"的迭代循环。字节码告诉你合约**能**做什么，replay 告诉你合约**实际**做了什么。

## MEV 基础设施演进：从 PGA 到 Flashbots

理解了 `approve()` 中的 `block.coinbase` 贿赂机制后，我们可以将它放入 MEV 基础设施的历史演进中。

### 2019：PGA 时代

我们在第 2 篇中引用过 Flash Boys 2.0 论文（Daian et al., 2019）描述的 Priority Gas Auction 现象。在那个时代，MEV Bot 通过在公开 mempool 中不断提高 gas price 来竞争交易排序位置。论文的 Figure 2 记录了两个 Bot 在数轮竞价中将 gas price 从基线水平推高数十倍。

PGA 有三个严重问题：

1. **网络拥堵**：竞价产生大量失败交易，浪费区块空间
2. **价值泄露**：gas 费用被所有验证者分享（销毁），而不是直接支付给打包你交易的验证者
3. **信息泄露**：竞价过程在 mempool 中完全公开，其他 Bot 可以窥探你的策略并抢先执行

论文的测量数据还揭示了一个更深层的威胁——部分区块的 MEV 收益已经超过了标准区块奖励（Figure 16 显示最高达 101.6 ETH vs 3 ETH 区块奖励）。这预示了 MEV 对共识层安全的潜在风险：如果 MEV 收益足够大，验证者可能被激励去重组历史区块以重新提取过去的 MEV 机会——论文称之为 **time-bandit attack**。

### 2020-2021：Flashbots 诞生

Flashbots 的出现直接回应了 PGA 的三个问题：

**Flashbots Protect**：Searcher 将交易提交到私有通道而非公开 mempool。交易对其他 Bot 不可见，消除了抢跑和三明治攻击的风险。Base 链使用中心化排序器（Sequencer），攻击者通过高 gas price（175-253 gwei）确保交易被优先排序。是否使用了排序器的私有提交通道无法从链上数据直接确认。

**MEV-Boost**：Builder 从多个 Searcher 收集 bundle，组装成完整区块并竞价。Proposer 从 Builder 提交的候选区块中选择出价最高的。这个架构实现了 Searcher → Builder → Proposer 供应链的分工——我们在第 1 篇中介绍过的 PBS（Proposer-Builder Separation）。

**block.coinbase 直接转账**：取代 gas price 竞价，Searcher 在合约内部通过 `block.coinbase` 直接向 Builder 转账。这就是 AttackContract 的 `approve()` 包装器中实现的机制。

| 维度 | PGA（2019） | Flashbots（2021+） |
|------|-----------|------------------|
| 竞价方式 | gas price 加价 | block.coinbase 直接转账 |
| 交易可见性 | 公开 mempool | 私有通道 |
| 失败成本 | 支付 gas（失败交易上链） | 零（模拟失败不上链） |
| 价值分配 | gas 费销毁 + 矿工分享 | 直接支付给 Builder |
| AttackContract 使用的方式 | 不使用 | approve() 中的 coinbase 转账 |

### MEV-Share：Order Flow Auction

Flashbots 后续推出的 MEV-Share 更进一步——让原始交易的用户也能分享 MEV 收益。Searcher 不再独占从用户交易中提取的全部价值，而是通过 Order Flow Auction 将部分收益返还给用户。这与 AttackContract 的利润模型无关（AttackContract 的攻击不依赖于抢跑用户交易），但代表了 MEV 生态从"纯攻击性"向"价值共享"演进的方向。

## 运营基础设施：从代码到组织

逆向工程不仅揭示了合约的技术架构，也揭示了背后的**运营模式**。

### ops 函数：子 EOA 管理

AttackContract 包含一个运维函数——选择器 `0x725f071c`，逆向时命名为 `ops`（参见 `reference/mixed_contract/src/AttackContract.sol`），虽然存在于所有 14 个部署的字节码中，但仅在 BNB 链（24 笔）和 Ethereum 链（1 笔）被实际调用：

```solidity
function ops(address[] calldata addrs, uint256 minAmount) external payable {
    uint256 remaining = msg.value;
    for (uint256 i = 0; i < addrs.length; i++) {
        address addr = addrs[i];
        uint256 bal = addr.balance;
        if (bal < minAmount) {
            uint256 deficit = minAmount - bal;
            uint256 toSend = deficit > remaining ? remaining : deficit;
            _sendETH(addr, toSend);
            remaining -= toSend;
            if (remaining == 0) break;
        }
    }
    if (remaining > 0) {
        _sendETH(msg.sender, remaining);  // 退还未用完的 ETH
    }
}
```

这个函数的功能很简单：批量向子 EOA 补充 gas 费。主 EOA（`0x6997...58ff`）调用 `ops()`，传入子 EOA 地址列表和目标最低余额，合约自动计算差额并补充。未用完的 ETH 退还给调用者。

BNB 链上有 24 笔交易调用了这个函数，向 `0x8ca6...3fc5`、`0xa1d2...aa74` 等子 EOA 补充 gas。这揭示了一个多 EOA 协作的攻击组织架构：

```
主 EOA (0x6997...58ff)
  ├── 部署合约（多链，nonce=0）
  ├── ops() → 批量分发 gas 给子 EOA
  ├── approve() → 直接执行攻击
  └── 接收所有利润（PROFIT_RECEIVER）

子 EOA (0x8ca6, 0xa1d2, 0x194f...)
  ├── 接收 gas 补充
  ├── approve() → 执行攻击（利润流向主 EOA）
  └── BNB 链：3 个子 EOA 轮转攻击
```

为什么需要子 EOA？可能的原因包括：

- **并发执行**：多个 EOA 可以同时在不同链上提交交易
- **风险隔离**：如果某个 EOA 被标记或限制，不影响其他 EOA
- **nonce 管理**：每个 EOA 独立的 nonce 序列避免了跨链 nonce 冲突

### approve 伪装的深层动机

回到开篇的观察——为什么选择 `approve(address, uint256)` 作为攻击入口？

技术上，任何函数签名都可以作为入口。AttackContract 同时也有 `fallback()` 作为第二入口。但 `approve` 有几个独特优势：

1. **区块浏览器掩护**：Etherscan 等浏览器会将 `approve` 交易显示为"ERC-20 Approval"，不会触发自动标记或告警
2. **参数复用**：`address to` 和 `uint256 flags` 在标准 approve 中是"被授权地址"和"授权金额"，在 AttackContract 中被重新定义为"tip 接收者"和"tip 金额"。参数类型完全匹配标准 ABI，不需要自定义编码
3. **calldata 延伸空间**：标准 `approve` 只需要 68 字节（4B selector + 32B address + 32B amount），EVM 不会因为 calldata 比预期长而报错。额外的字节被 `_execCalldataChunk` 解析为指令序列

这种"在合法接口下隐藏攻击载荷"的思路在安全领域并不罕见——Web 安全中的参数污染（Parameter Pollution）、HTTP Request Smuggling 都采用类似策略。区别在于，传统攻击利用的是解析差异，而 AttackContract 利用的是 EVM 对 calldata 长度不做强制校验的特性。

### jtriley2p 与开源 MEV 的困境

Lotus Router 的故事本身揭示了 MEV 行业的一个结构性矛盾。

jtriley2p 以 AGPL-3.0 许可证在 GitHub 上公开了 Lotus Router 的完整源码。README 中收录了一句宣言：

> "We grow tired of building the same software again and again"

这句话直接回应了 MEV 行业的现状：几乎每个 Searcher 团队都在独立开发功能高度相似的路由合约——calldata 驱动 VM、DEX swap 操作码、闪贷回调——但这些代码被 NDA（保密协议）和字节码混淆器严密保护。jtriley2p 试图打破这个循环。

然而项目发布后不久，jtriley2p 的前雇主对其发起了版权投诉（DMCA），声称代码涉及商业机密。GitHub 仓库被删除。但源码已通过 IPFS 继续传播（CID: `bafkreif2ffb2kghamkdjp5pcgrsxu26hx42w3imujcq6zeqacwzsg5pbla`），这正是去中心化存储抗审查的经典案例。

这个事件提醒我们：MEV 路由合约的核心架构（calldata VM、操作码设计、回调机制）并不复杂——我们用 7 篇文章就已经完整解析了 2 套实现。真正的竞争壁垒不在合约本身，而在链下系统：机会发现算法、mempool 监听基础设施、低延迟网络接入、多链策略调度。这也是为什么 AttackContract 的合约可以被逆向重建到 15/15 交易 replay 通过，但我们仍然无法复制其攻击能力——链下 Searcher 系统才是真正的护城河。

## 动手环节

### 任务 1：为 Lotus Router 添加 approve() 安全包装层

Lotus Router 的"裸奔设计"适合作为组件使用，但如果要独立部署，至少需要添加基本的安全保护。编写一个 wrapper 合约：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILotusRouter {
    fallback() external payable;
}

/// @notice 为 Lotus Router 添加安全包装层
/// @dev 模仿 AttackContract 的 approve() 安全模型
contract SecureLotusWrapper {
    address public immutable router;         // Lotus Router 地址
    address public immutable profitReceiver; // 硬编码利润接收者

    constructor(address _router, address _profitReceiver) {
        router = _router;
        profitReceiver = _profitReceiver;
    }

    function execute(uint256 deadline) external payable {
        // 第 1 层：反重放
        require(block.number <= deadline, "expired");

        // 第 2 层：记录执行前余额
        uint256 preBal = address(this).balance - msg.value;

        // 第 3 层：转发 calldata 到 Lotus Router
        // 注意：实际使用中需要将指令序列编码为 Lotus Router 格式
        (bool ok,) = router.call{value: msg.value}(msg.data[36:]); // 跳过 execute 的 selector + deadline
        require(ok, "router call failed");

        // 第 4 层：利润保证
        uint256 postBal = address(this).balance;
        require(postBal > preBal, "no profit");

        // 第 5 层：利润分配
        uint256 profit = postBal - preBal;
        // 简化版：全部发送给 profitReceiver
        (bool sent,) = profitReceiver.call{value: profit}("");
        require(sent, "transfer failed");
    }

    receive() external payable {}
}
```

**思考题**：这个简化版包装器缺少了 AttackContract 的哪些安全机制？（提示：Builder 贿赂、WETH 自动转换、66% 上限）

### 任务 2：通过 Flashbots Protect 提交测试交易

体验 Flashbots Protect 的私有交易提交：

```javascript
// submit-flashbots-protect.js
const { ethers } = require("ethers");

// Flashbots Protect RPC — 交易不经过公开 mempool
const FLASHBOTS_PROTECT_RPC = "https://rpc.flashbots.net";

async function submitProtectedTx() {
    // 使用 Flashbots Protect RPC 创建 provider
    const provider = new ethers.JsonRpcProvider(FLASHBOTS_PROTECT_RPC);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

    // 构造一笔普通转账（用于测试）
    const tx = {
        to: wallet.address,              // 发给自己
        value: ethers.parseEther("0"),    // 0 ETH
        maxFeePerGas: ethers.parseUnits("30", "gwei"),
        maxPriorityFeePerGas: ethers.parseUnits("2", "gwei"),
    };

    console.log("通过 Flashbots Protect 提交交易...");
    console.log("交易将不会出现在公开 mempool 中");

    const txResponse = await wallet.sendTransaction(tx);
    console.log("TX Hash:", txResponse.hash);
    console.log("等待上链...");

    const receipt = await txResponse.wait();
    console.log("已上链，区块:", receipt.blockNumber);

    // 验证：这笔交易在提交后、上链前，无法通过公开 mempool 监听到
}

submitProtectedTx().catch(console.error);
```

注意：实际 MEV Bot 使用的是 Flashbots Builder API（`eth_sendBundle`），可以将多笔交易打包为 bundle 提交。Flashbots Protect 是面向普通用户的简化版本。

### 任务 3：讨论题

如果你要将本系列教程中的路由合约部署到生产环境，除了 `approve()` 包装器中的五层安全机制，还需要哪些额外保护？

思考方向：

- **合约升级**：如果发现 bug 或需要支持新协议，如何升级合约逻辑？（代理合约模式 vs 重新部署）
- **资金回收**：如果代币意外留在合约中，如何取回？（AttackContract 没有通用的 `rescue` 函数）
- **多签控制**：`PROFIT_RECEIVER` 是单一地址——如果私钥泄露会怎样？
- **监控告警**：如何检测合约是否被他人利用（即使利润流向你的地址）？
- **gas 限制**：如何防止单笔交易消耗过多 gas（比如恶意的无限循环指令）？

## 小结

MEV 路由合约的安全设计分为两种哲学：Lotus Router 作为"组件"将安全责任外推给调用者；AttackContract 作为"自治系统"内建五层防护——反重放、利润保证、WETH 转换、Builder 贿赂、硬编码收款。`approve()` 函数签名的选择不仅是技术便利，也是刻意的伪装策略。

`flags` 参数语义从"gas 补偿位域"修正为"直接 wei 金额"的过程，展示了逆向工程的核心方法论：字节码告诉你合约能做什么，replay 告诉你合约实际做了什么。初始假设经常是错的，只有通过 wei 级别的精确对比才能确认真实语义。

从 PGA 到 Flashbots 的演进解决了 MEV 竞价中的网络拥堵、价值泄露和信息泄露问题，`block.coinbase` 直接转账取代了 gas price 竞价。AttackContract 在 Ethereum 和 Arbitrum 等链上向 Builder 支付了可观的 tip（仅 Ethereum 链就达 43.82 ETH），这是 Flashbots 生态在生产环境中的真实运作。

**下一篇**：第 9 篇《策略参数化与跨链泛化》，我们将分析 13 笔 Moonwell 攻击如何共享一套 calldata 模板（73 字节变量 / 932 字节总长 = 7.8% 差异），以及 14 个链上部署如何仅凭 132 字节的差异实现跨链泛化。
