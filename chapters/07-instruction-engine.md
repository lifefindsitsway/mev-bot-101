# 第 7 篇：指令引擎深度解析 —— 12 操作码的两种实现

前六篇我们已经分别认识了 Lotus Router（第 4 篇源码精读）和 AttackContract（第 6 篇逆向重建）的指令引擎。本篇的目标是把两套实现放在同一张桌上，逐功能域对比，揭示 MEV 路由合约设计空间中最核心的工程权衡。

两套指令引擎都使用 12 个操作码——这不是巧合。12 个操作码覆盖了 MEV 场景所需的全部功能域：DEX swap、闪贷、代币操作、通用调用和金额管理。但同样的 12 个操作码，两套实现在状态管理、回调架构和容错策略上的选择截然不同。

## 两套指令集：完整对比表

| 功能域 | Lotus Router | AttackContract |
|--------|-------------|---------------|
| **V2 Swap** | SwapUniV2 (0x01) — 调用 pair.swap()，data 参数携带后续指令 | V2_SWAP (0x00) — 先 transfer 输入代币，再调用 swap()。内置 AMM 公式计算输出 |
| **V3 Swap** | SwapUniV3 (0x02) — 调用 pool.swap()，data 携带后续指令，回调中恢复执行 | V3_SWAP (0x01, flag=0) — 调用 pool.swap()，回调仅转账。amount 寄存器更新为输出 |
| **V3 Flash** | FlashUniV3 (0x03) — 独立操作码 | V3_SWAP (0x01, flag=1) — 复用 swap 操作码 |
| **多协议闪贷** | 无 | FLASH_LOAN_INITIATE (0x02) — Balancer/AaveV3/EulerV2 |
| **ERC20 Transfer** | TransferERC20 (0x04) — 专用操作码 | 通过 RAW_CALL (0x09) 构造 transfer calldata |
| **WETH Deposit** | DepositWETH (0x09) — WETH 地址从 calldata 传入 | WETH_DEPOSIT (0x03) — WETH 地址为 immutable（构造函数传入） |
| **WETH Withdraw** | WithdrawWETH (0x0a) — WETH 地址从 calldata 传入 | WETH_WITHDRAW (0x04) — 全额提取 |
| **通用调用** | DynCall (0x0b) — 任意 target + calldata + value | RAW_CALL (0x09) — 任意 target + calldata |
| **带金额调用** | 无 | CALL_WITH_AMT (0x0a) — prefix + amount + trail |
| **条件验证** | 无 | CALL_WITH_CHECK (0x0b) — 调用 + 返回值断言 |
| **金额管理** | 无 | REGISTER_COPY (0x05)、SET_OR_MIN (0x06)、BALANCE_OF (0x07)、SUB_BALANCE (0x08) |
| **终止** | Halt (0x00) — `stop()` 成功返回 | 无终止码 — `while(cur < len)` 自然结束 |
| **容错** | canFail 标志（操作级跳过） | `require(ok)`（硬失败） |

几个结构性差异值得展开。

## 有状态 VM vs 无状态路由器

两套引擎最本质的架构差异在于**是否维护运行时状态**。

### Lotus Router：纯无状态

Lotus Router 没有任何跨指令共享的状态变量。每条指令的所有参数都从 calldata 中读取——包括转账金额、目标地址、swap 数量。这意味着链下系统在生成 calldata 之前，必须**预计算所有中间值**。

例如，要执行"查询 WETH 余额 → 全部 swap 为 USDC"，链下系统需要：
1. 调用 `WETH.balanceOf(router)` 获取当前余额
2. 将这个余额硬编码到 calldata 的 swap 金额参数中
3. 提交交易

如果在链下查询和交易执行之间，余额发生了变化（比如另一笔交易先执行了），硬编码的金额就不准确——可能导致 swap 失败或利润计算错误。

### AttackContract：有状态 VM

AttackContract 引入了一个关键创新——**amount 寄存器**：一个 `uint256` 变量，在指令执行过程中动态读写，跨指令共享。

```solidity
// AttackContract _execLoop() — amount 寄存器的使用
function _execLoop(bytes calldata instructions) internal {
    uint256 amount;  // ← 跨指令共享的状态
    // ...
    if (op == 0x07) {  // BALANCE_OF
        amount = IERC20(token).balanceOf(address(this));
    }
    else if (op == 0x01 && flag == 0) {  // V3_SWAP
        // 使用 amount 作为 swap 输入
        (int256 a0, int256 a1) = pool.swap(..., int256(amount), ...);
        amount = uint256(-a1);  // 更新为 swap 输出
    }
}
```

5 个金额管理操作码围绕 amount 寄存器工作：

| 操作码 | 功能 | 典型用途 |
|--------|------|---------|
| BALANCE_OF (0x07) | `amount = balanceOf(token)` | 查询闪贷后的抵押品余额 |
| REGISTER_COPY (0x05) | `amount = secondaryRegister` | 恢复辅助寄存器保存的中间值 |
| SET_OR_MIN (0x06) | `amount = value` 或 `amount = min(amount, value)` | 设置金额或做上限约束 |
| SUB_BALANCE (0x08) | `amount -= balanceOf(token)` | 计算差额利润 |
| V2/V3_SWAP | `amount = swap 输出` | 自动更新为换得的代币数 |

有了 amount 寄存器，同样的"查余额→全部 swap"操作变成：

```
BALANCE_OF(WETH)   → amount = 当前 WETH 余额（运行时查询）
V3_SWAP(pool)      → 用 amount 执行 swap，amount 自动更新为输出
```

不需要链下预计算，不需要担心余额在链下查询和交易执行之间变化。amount 寄存器让指令流可以对**运行时状态做出动态响应**。

### 设计权衡

| 特性 | 无状态（Lotus Router） | 有状态（AttackContract） |
|------|-------------------|---------------|
| 链下复杂度 | 高（必须预计算所有值） | 低（可动态查询） |
| 链上复杂度 | 低（无状态管理） | 中（5 个额外操作码） |
| 确定性 | 完全确定（所有值预设） | 部分动态（运行时查询） |
| 抗干扰性 | 弱（值可能过期） | 强（运行时适应） |
| 适用场景 | 精确预计算的套利路径 | 需要动态适应的攻击策略 |

AttackContract 的预言机套利场景特别适合有状态设计——攻击者无法完全预测闪贷后 Moonwell 会给出多少 mToken、能借出多少资产。BALANCE_OF + amount 寄存器让这些值在运行时自动确定。

## 回调架构：递归 vs 线性

我们在第 4 篇中详细分析了 Lotus Router 的递归回调模型。现在对比 AttackContract 的线性模型。

### Lotus Router：递归模型

```
指令编码：[SwapBC] [SwapAB] [TransferA→AB] [TransferB→BC]
                ↓ 嵌套回调
执行顺序：SwapBC 发起
              → 回调中 SwapAB 发起
                  → 回调中 TransferA + TransferB
              ← SwapAB 完成
          ← SwapBC 完成
```

- Swap 回调中**继续执行指令**（通过 findPtr 恢复指针）
- 编码顺序与执行顺序**反向**
- 多跳 swap 通过嵌套回调实现

### AttackContract：线性模型

```
指令编码：[FLASH(pool)] [BALANCE_OF] [APPROVE] [MINT] [BORROW] [SWAP] [SWAP]
                ↓ 闪贷回调中顺序执行
执行顺序：FLASH 发起 → 回调中按编码顺序逐条执行 → 还贷 → 返回
```

- 闪贷回调中执行全部指令（线性顺序）
- Swap 回调**不执行指令**，仅转账欠款
- 编码顺序与执行顺序**一致**

### 关键差异的根源

两种模型的差异源于一个设计选择：**swap 回调中是否执行指令**。

Lotus Router 让 swap 回调成为指令执行的延续点——回调中恢复指令指针继续执行。这实现了"先 swap 后筹资"的灵活性，但代价是编码复杂度和调试难度的增加。

AttackContract 让 swap 回调只做一件事——转账欠款。所有策略逻辑集中在闪贷回调中线性执行。这牺牲了多跳 swap 的灵活性，但获得了极大的简洁性——线性 trace 容易调试，线性编码容易生成。

对于 AttackContract 的使用场景（预言机套利，固定的闪贷→借贷→swap 路径），线性模型完全够用。Lotus Router 的递归模型在多跳套利场景下更有优势——但那不是 AttackContract 需要的。

## 逆向认知演进：7 个关键误判的修正

在第 5 篇和第 6 篇中，我们已经提到了逆向过程中的一些 opcode 误判。本节系统总结这些误判，因为它们不是合约的 Bug，而是逆向分析者从局部观察推断整体时的必然误差——理解这些误差本身就是逆向方法论的核心教学价值。

### Flash Repay 机制的认知修正

早期分析（仅基于 Base 链 15 笔交易）曾将闪贷回调的还款逻辑理解为"从 callback data 前 32 字节读取 flashAmount，归还 flashAmount + fee"。这个理解在 15 笔交易中恰好产生正确结果——因为调用前余额等于 flashAmount。

跨链 replay 验证证明了实际行为是 `balanceOf(this)` 方案：

```solidity
// AttackContract _handleUintCb — 实际实现
uint256 preBalance = IERC20(token).balanceOf(address(this));  // 运行时查询
_execLoop(d);  // 执行指令
_safeTransfer(token, pool, preBalance + fee);  // 归还 preBalance + 手续费
```

callback data 中不包含 flashAmount，而是纯指令流。`preBalance` 记录的是闪贷到账后的合约余额，而非显式编码的闪贷金额。这个方案更通用——链下系统不需要在 callback data 中硬编码闪贷金额。

### 回调路由设计

我们在第 3 篇中已详细讨论过 AttackContract 的回调路由：按参数类型分派而非按协议名称分派。

```
所有 (uint256, uint256, bytes) 回调  →  _handleUintCb（执行指令 + 还贷）
所有 (int256, int256, bytes) 回调    →  _handleIntCb（仅转账）
```

这个设计的优势在于可扩展性：当新的 DEX fork 出现时，只需添加一个外部函数（同样的函数体、不同的函数名），就能自动路由到正确的处理逻辑。42 个函数中有 31 个（15 flash + 16 swap）通过这种机制实现了代码零重复。

### Opcode 误判总结

第 5 篇已详细分析的三处 opcode 误判：

| 操作码 | 早期误判 | 实际功能 | 误判原因 |
|--------|---------|---------|---------|
| 0x02 | READ_ADDR (20B) | FLASH_LOAN_INITIATE (73B) | Base 链 15 笔 TX 未触发此 opcode |
| 0x05 | SET_AMOUNT (7B) | REGISTER_COPY (0B) | 同上 |
| 0x06 | CHECK_AMOUNT (20B) | SET_OR_MIN (33B) | 同上 |

此外还有 4 个逆向过程中修复的关键 Bug（回调参数 int256/uint256 类型混淆、flags 语义从"位域"到"直接 wei 金额"、V2 Flash Swap 模式、vflag 带 ETH value 调用），详见 `reference/final_report.md` §11.6。

## 容错哲学：三种策略

两套引擎对"操作失败"的处理策略有本质差异，反映了不同的设计哲学。

### Lotus Router：canFail（操作级跳过）

```solidity
success = pool.swap(...) || canFail;
// canFail=true 且 swap 失败 → success=true → 继续下一条指令
```

**哲学**：失败是可预期的，部分操作失败不应终止整个流程。适合多路径探测——"试几个池子，哪个行就用哪个"。

**风险**：如果关键操作（如闪贷还款的 transfer）被错误标记为 canFail=true，失败后执行继续，最终闪贷检查 revert，但已消耗大量 gas。

### AttackContract：require(ok)（全有或全无）

```solidity
(bool ok,) = target.call(cd);
require(ok);  // 任何失败 → 立即 revert 整笔交易
```

**哲学**：攻击路径是确定的——如果任何一步失败，后续步骤也不可能成功。早期 revert 节省 gas。

**适用场景**：预言机套利这种"非此即彼"的机会。要么预言机偏差存在、所有步骤成功、利润到手；要么偏差已被修正、第一步就失败、revert 仅损失少量 gas。

### AttackContract CALL_WITH_CHECK：条件验证

```solidity
(bool ok, bytes memory ret) = target.call(cd);
require(ok);
uint256 val = abi.decode(ret, (uint256));
if (cmp == 0) require(val == expected);      // 精确相等
else if (cmp == 1) require(val >= expected);  // 大于等于
else if (cmp == 2) require(val < expected);   // 小于
else if (cmp == 3) require(val != expected);  // 不等于
```

**哲学**：不只是"成功或失败"，而是"返回值是否满足预期"。这是 AttackContract 和 Lotus Router 的一个本质区别——AttackContract 可以在链上验证条件（比如"池子储备量是否足够"），而 Lotus Router 只能在链下做所有验证。

三种策略的对比：

| 维度 | canFail | require(ok) | CALL_WITH_CHECK |
|------|---------|------------|----------------|
| 失败行为 | 跳过，继续 | 立即 revert | 按条件 revert |
| gas 浪费 | 可能高（执行完才 revert） | 低（早期退出） | 低（早期退出） |
| 链上验证 | 无（仅执行成功/失败） | 无 | 有（4 种比较） |
| 适用场景 | 多路径探测 | 确定性路径 | 条件性攻击 |

## trail 机制：一个操作码适配多种 ABI

CALL_WITH_AMT（0x0a）是 AttackContract 指令集中最灵活的操作码。它构造的 calldata 格式为：

```
[prefix (函数选择器 + 前置参数)] + [amount (32B)] + [trail_data (额外参数)]
```

`trail` 字段（2 字节 uint16）指定额外数据的长度。当 `trail=0` 时，calldata 就是 `prefix + abi.encode(amount)`，适合简单的单参数函数。当 `trail>0` 时，从指令流中读取 trail 字节追加到 calldata 末尾。

AttackContract 使用这个机制适配了两种不同的借贷协议：

**Moonwell（trail=0）**：
```solidity
// mToken.mint(amount)
// calldata = [mint selector (4B)] + [amount (32B)]
// trail = 0：无额外参数
CALL_WITH_AMOUNT(mToken, prefix=[0xa0712d68], trail=0)
```

**Morpho Blue（trail=96）**：
```solidity
// morpho.borrow(MarketParams, amount, shares, onBehalf, receiver)
// calldata = [borrow selector (4B)] + [MarketParams (160B)] + [amount (32B)]
//            + [shares (32B)] + [onBehalf (32B)] + [receiver (32B)]
// 但实际编码：prefix 包含 selector + MarketParams，
//   amount 由寄存器提供，trail 包含后续 3 个参数
CALL_WITH_AMOUNT(morpho, prefix=[selector+MarketParams], trail=96)
// trail_data = [shares:32B] + [onBehalf:32B] + [receiver:32B]
```

同一个操作码，通过调整 prefix 和 trail，适配了完全不同的函数签名。这避免了为每个新协议添加专用操作码——RAW_CALL 处理无需 amount 的调用，CALL_WITH_AMT 处理需要动态金额的调用，两者配合覆盖了所有 DeFi 协议交互。

## 动手环节

### 任务 1：手动解码 Base 链 TX_01 指令集 1

取 TX_01 的指令集 1（约 600 字节），逐条手动解码。前两条指令的解码示例：

```
偏移 0x000: 01                → opcode = V3_SWAP (0x01)
偏移 0x001: 01                → flag = 1 (FLASH 模式)
偏移 0x002: 14dc...e2a4       → pool = CLPool (20 字节)
偏移 0x016: 0000...08f5       → amt = 650064525566293 (32 字节)
偏移 0x036: 01                → dir = 1 (token1)
偏移 0x037: 00                → cb = 0
偏移 0x038: 00                → d = 0 (cb==0 时额外字节)
                              → 总长度: 57 字节

偏移 0x039: 07                → opcode = BALANCE_OF (0x07)
偏移 0x03a: [wrsETH addr:20B] → token = wrsETH
                              → 总长度: 21 字节
```

**练习**：继续解码剩余 9 条指令（RAW_CALL、CALL_WITH_AMT 等），参照 `reference/archive_0x42Ecd332/reports/calldata_format.md` 中的操作码格式。

可以使用 `cast` 获取原始 calldata：

```bash
# 获取 TX_01 calldata
cast tx 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  input --rpc-url https://mainnet.base.org
```

### 任务 2：用 Lotus Router 指令集编码等价流程

尝试用 Lotus Router 的 12 个 Action 编码 AttackContract TX_01 的攻击流程。你会发现以下挑战：

1. **没有 amount 寄存器**：Lotus Router 无法运行时查询余额，所有金额必须硬编码
2. **没有 CALL_WITH_AMT**：Moonwell 的 `mint(amount)` 和 `borrow(amount)` 需要通过 DynCall 实现，但无法动态传入 amount
3. **递归 vs 线性**：闪贷和 swap 的编码顺序需要反转

**思考题**：如果要让 Lotus Router 支持 AttackContract 的攻击流程，最少需要添加哪些功能？（提示：amount 寄存器和 BALANCE_OF 操作码是最关键的两个——这正是第 10 篇的改造方向。）

## 小结

两套指令引擎共享 12 个操作码的基本设计空间，但在三个维度上做出了不同的选择：

**状态管理**——Lotus Router 是纯无状态路由器，所有值由链下预计算；AttackContract 引入 amount 寄存器实现运行时状态，金额管理操作码让指令流可以动态响应链上状态。这是"组件"与"自治系统"的分界线。

**回调架构**——Lotus Router 的递归模型让 swap 回调成为指令执行的延续点，实现灵活的多跳路由；AttackContract 的线性模型将所有逻辑集中在闪贷回调中顺序执行，以简洁性换取灵活性。两种模型的选择取决于使用场景——多跳套利选递归，固定路径攻击选线性。

**容错策略**——Lotus Router 的 canFail 允许操作级跳过，适合探测性场景；AttackContract 的 require(ok) 加 CALL_WITH_CHECK 提供"全有或全无"加"条件验证"的双层策略，适合确定性攻击路径。

逆向过程中发现的 7 个关键误判（flash repay 机制、回调参数类型混淆、flags 语义、opcode 0x02/0x05/0x06 等）不是合约的演进，而是分析者从局部观察推断整体时的认知演进——理解这些误差本身就是逆向方法论的核心价值。

**下一篇**：第 8 篇《安全机制与 MEV 基础设施》，我们将系统对比 Lotus Router 的"裸奔设计"与 AttackContract 的安全包装层，并通过 flags 参数语义修正的完整故事展示逆向工程中"假设→验证→修正"的方法论。
