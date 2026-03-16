# 第 6 篇：拆解攻击合约 —— 从字节码到重建源码

想象你面前有一段 24,543 字节的十六进制字符串。没有源码，没有 ABI，没有文档。你只知道它部署在 Base 链的 `0x42Ecd332D47C91CbC83B39bD7f53CEbe5E9734bB`，在约 30 秒内净提取了 295.75 ETH。

你的任务：把这段字节码还原为可编译的 Solidity 源码，并通过 Foundry fork 测试验证——重放所有 15 笔真实交易，利润精确到 wei。

这一篇讲述的就是这个过程。不是最终结论的展示，而是**发现过程本身**——困惑、假设、验证、修正，以及"编译→重放→失败→字节级对比→修复"的迭代循环。这是本系列中最具原创性的内容。

## 第一层：工具链——与字节码的初次接触

逆向工程的第一步不是直接阅读字节码，而是让自动化工具先跑一遍，建立初始认知。

### WhatsABI：选择器提取

WhatsABI 是一个轻量级工具，它扫描字节码中的 `PUSH4` 指令模式，提取所有函数选择器。对 Base 链部署的字节码运行后，结果令人意外：

**发现了 45 个外部函数选择器。**

45 个——这不是一个普通合约该有的数量。一个标准的 ERC20 合约只有 6-8 个选择器，一个复杂的 DeFi 协议通常也不超过 20 个。45 个选择器暗示着大量的外部接口，但这些接口都做什么？

### Heimdall：反编译

Heimdall v0.9.2 的反编译器输出了 17,622 行伪 Solidity 代码。这个体量本身说明了合约的复杂度——但更重要的是，伪代码的质量。

Heimdall 的输出是**骨架而非产品**。它能正确识别函数边界、选择器路由表和大致的控制流，但大量的底层操作被表示为未解析的 `MLOAD`、`MSTORE` 和内存偏移计算。对于一个重度使用紧凑编码和内联汇编的 MEV 合约来说，反编译器能做的有限。

但 Heimdall 给出了一个关键线索：`approve(address,uint256)` 选择器（`0x095ea7b3`）对应的函数体异常庞大——包含 `msg.value` 与 `block.number` 的比较、`WETH.balanceOf()` 调用、以及一个指向地址 `0x1e9a` 的内部函数调用。

**第一个困惑产生了**：一个 ERC20 的 `approve` 函数为什么要检查 `msg.value` 和 `block.number`？

## 第二层：字节码直接分析——提取硬编码信息

自动化工具的输出不够精确，需要直接分析字节码。用 Python 脚本扫描所有 `PUSH20` 和 `PUSH4` 指令，提取结构化元数据。

### 硬编码常量：4 个独特的 PUSH20 值

在 24,543 字节中，扫描所有 `PUSH20` 指令后提取出 4 个独特的地址值（部分值出现多次）：

| 位置 | 值 | 含义 |
|------|-----|------|
| — | `0x4200000000000000000000000000000000000006` | Base 链 WETH 地址 |
| — | `0x6997a8c804642AE2de16D7B8Ff09565a5D5658ff` | 攻击者 EOA |
| — | `0xfffd8963efd1fc6a506488495d951d5263988d25` | MAX_SQRT_RATIO - 1 |
| — | `0xffffffffffffffffffffffffffffffffffffffff` | 地址掩码 |

前两个立即揭示了合约的身份——WETH 地址（出现 5 次，作为 immutable 变量）确认了 Base 链部署，攻击者 EOA 作为利润接收者被硬编码在字节码中。第三个是 Uniswap V3 的 `MAX_SQRT_RATIO - 1`，我们在第 3 篇中见过它——AttackContract 在 swap 时使用极限值不设滑点保护。

**关键洞察**：除了这 4 个常量，**所有 DEX 地址和协议地址都不在字节码中**。它们必然通过 calldata 传入——这是"通用引擎"而非"专用攻击脚本"的直接证据。

### 编译器元数据

字节码尾部的 CBOR 编码元数据显示：Solidity 0.8.15，非 via-IR 编译。这个信息后续在组装重建源码时用于确保编译配置一致。

## 第三层：45 个选择器，7 个函数——跳板架构

将 45 个选择器的 JUMPI 目标地址提取出来，一个意想不到的模式出现了：

**45 个选择器，但只有 7 个不同的跳转目标。**

这意味着大量选择器共享相同的实现代码。进一步分析每个跳转目标的字节码，发现它们都是极短的"薄包装器"——仅 6 条 EVM 指令：加载参数、JUMP 到真正的实现地址。

```
45 个选择器 (dispatch table)
    ↓ 跳转到
43 个 trampoline（6 条指令的薄包装器）+ 2 个独立函数
    ↓ 最终汇聚到
7 个真实实现
```

其中最主要的 7 个实现（覆盖了 37 个选择器）：

| 实现地址 | 汇聚的选择器数 | 功能 |
|---------|--------------|------|
| `0x1891` | 15 | UniV3 风格闪贷回调 → `_handleUintCb` |
| `0x1c45` | 16 | 所有 swap 回调 → `_handleIntCb` |
| `0x1e9a` | 2 | iZiSwap + 未知签名回调 → 独立实现 |
| `0x0cdd` | 1 | approve() 执行包装器 |
| `0x1002` | 1 | AAVE V2 `executeOperation` |
| `0x1427` | 1 | AAVE V3 `executeOperation` |
| `0x1b14` | 1 | Balancer `receiveFlashLoan` |

剩余 8 个选择器路由到其他较小的实现（onMorphoFlashLoan、ops 运维函数、tryAggregate、balances 等工具函数），在初始分析中暂未深入。

**这就是我们在第 3 篇中讨论的回调签名爆炸**——15 个闪贷回调函数名不同但实现完全一样（全部路由到 `_handleUintCb`），16 个 swap 回调也是（全部路由到 `_handleIntCb`）。跳板架构让字节码保持紧凑——每个 trampoline 只有 6 条指令的开销，真实逻辑不重复。

45 个选择器中，26 个通过 4byte.directory 匹配到已知签名。剩下 19 个无法匹配——但因为它们与已知回调共享跳板目标，可以推断它们是更冷门的 DEX fork 的回调函数。

## 第四层：approve() 不是 approve

回到最初的困惑：`approve(address,uint256)` 为什么检查 `msg.value` 和 `block.number`？

结合 Heimdall 伪代码和字节码分析，`approve()` 的完整逻辑逐渐浮现：

```solidity
function approve(address to, uint256 flags) external payable {
    // 1. 反重放保护：用 msg.value 与 block.number 比较
    if (msg.value > 0) {
        if (flags & 0x02 != 0) require(msg.value > block.number);
        else require(msg.value <= block.number);
    }

    // 2. 记录执行前 ETH 余额
    uint256 preBalance = address(this).balance;

    // 3. 执行两段指令序列
    _execCalldataChunk(0x64);  // 指令集 1：闪贷 + 借贷 + swap
    _execCalldataChunk(0x84);  // 指令集 2：利润提取

    // 4. 将所有 WETH 转换为 ETH
    uint256 wethBal = WETH.balanceOf(address(this));
    if (wethBal > 0) WETH.withdraw(wethBal);

    // 5. 利润保证
    require(address(this).balance > preBalance);

    // 6. Builder tip（flags 直接作为 wei 金额）
    if (flags != 0) {
        address recipient = to == address(0) ? block.coinbase : to;
        uint256 maxPayment = address(this).balance * 66 / 100;
        uint256 payment = flags > maxPayment ? maxPayment : flags;
        _sendETH(recipient, payment);
    }

    // 7. 剩余利润发送给硬编码地址
    _sendETH(PROFIT_RECEIVER, address(this).balance);
}
```

**它是一个完整的攻击执行包装器**，只是披着 ERC20 `approve` 的外衣。`approve` 的两个标准参数被重新赋予了含义：`to` 控制 tip 接收者（`address(0)` 时自动使用 `block.coinbase`），`flags` 直接指定 tip 的 wei 金额。

### 双指令集架构的发现

注意步骤 3 中的两次 `_execCalldataChunk()` 调用——分别从 calldata 偏移 `0x64` 和 `0x84` 读取两段独立的指令序列。这是一个关键的架构发现：

- **指令集 1**（约 600 字节）：闪贷 → 存入抵押品 → 借出资产 → DEX swap → 还闪贷
- **指令集 2**（77 字节）：将剩余资产 swap 为 WETH → 利润准备

为什么要拆成两段？因为指令集 1 在闪贷回调中执行——`V3_SWAP flag=1` 将剩余指令打包传给 `pool.flash()`，回调中执行完毕后闪贷自动还款。闪贷还款后，控制权返回 `approve()`，此时执行指令集 2 完成最后的利润提取。

## 第五层：指令引擎——Calldata 驱动的逆向

`_execCalldataChunk()` 最终调用的是指令引擎 `_execLoop()`——位于字节码 `0x1e9a` 附近。Heimdall 的伪代码显示了一个 `while(cur < len)` 循环和 `switch(op)` 分支结构，包含 12 个 case（0x00 到 0x0b）。

但伪代码中每个 case 的具体参数解析是混乱的——大量的 `MLOAD` 和偏移计算。要准确理解每个操作码的编码格式，需要一种更直接的方法：**用真实交易的 calldata 作为地面真值**。

### Calldata 驱动逆向法

这是整个逆向过程中最核心的方法论。步骤如下：

1. 取 TX_01 的 932 字节 calldata
2. 提取指令集 1（600 字节）
3. 从第 1 个字节开始，读取操作码
4. 结合 `cast run --trace` 的执行 trace，对照每一步：
   - 操作码是什么？
   - 它读了多少字节的参数？
   - 参数的含义是什么（地址？金额？标志位？）？
   - `cur` 指针前进了多少？
5. 用下一条指令的偏移量反推上一条指令的总长度

举例：TX_01 指令集 1 的前 57 字节：

```
01                         ← opcode = 0x01 (V3_SWAP)
01                         ← flag = 1 (→ 闪贷模式！)
14dc79c46e6285a0fa62...    ← pool 地址 (20 字节)
00000000000000000000...    ← amt (32 字节)
01                         ← dir = 1 (token1)
00                         ← cb = 0
00                         ← d = 0 (cb==0 时的额外字节)
```

`flag = 1` ——这就是我们在第 3 篇提到的"V3_SWAP flag=1 表示闪贷"。这个发现不是从伪代码中猜到的，而是从 calldata 字节与 trace 的对照中直接观察到的。

## 第六层：关键突破

### flag=1 → 闪贷路径

在字节码中追踪 `op == 0x01` 的分支，发现 `flag` 字段控制了两条完全不同的执行路径：

- `flag == 0`：调用 `pool.swap()`——标准的 V3 swap
- `flag == 1`：调用 `pool.flash()`——闪贷

这是一个优雅的设计：用 swap 操作码的一个标志位复用闪贷功能，不需要独立的闪贷操作码。当 `flag=1` 时，指令引擎将当前指针之后的**所有剩余字节**打包为回调数据，设置 `cur = len` 终止当前循环——后续操作全部在闪贷回调中执行。

### CALL_WITH_AMOUNT 的 trail 机制

操作码 0x0a（CALL_WITH_AMOUNT）的格式比其他操作码复杂：

```
[op][target:20B][vflag:1B][plen:2B][prefix:NB][trail:2B][trail_data:MB]
```

它构造的 calldata 是 `prefix + abi.encode(amount) + trail_data`。在 Moonwell 攻击中，`trail` 字段始终为 0——没有额外数据。但在 Morpho Blue 攻击中，`trail` 字段为非零值，因为 Morpho Blue 的 `supplyCollateral()` 等函数需要在 amount 之后追加额外的 ABI 编码参数（如 MarketParams 结构体和其他参数），trail 机制将这些额外数据拼接在 amount 之后。

`trail` 机制让同一个操作码可以适配不同协议的 ABI——不管目标函数需要多少额外参数，都可以通过 trail 数据追加。

## 第七层：编译→重放→失败→修复

到这里，指令引擎的 12 个操作码已经大致理解。下一步是将所有发现组装成可编译的 Solidity 代码，然后用 Foundry fork 测试验证。

验证方法：

```solidity
// 测试架构核心（简化）
function _replay(uint256 forkBlock, bytes memory cd) internal {
    // 1. 编译重建合约，获取 runtime bytecode
    AttackContract temp = new AttackContract(WETH_ADDR);
    bytes memory reconRuntime = address(temp).code;

    // 2. Fork 到攻击前一个区块
    vm.createSelectFork(RPC, forkBlock);

    // 3. 用重建字节码覆盖原始合约地址
    vm.etch(BOT, reconRuntime);

    // 4. 以攻击者身份执行
    vm.prank(OWNER);
    (bool ok,) = BOT.call(cd);

    // 5. 对比利润（同样方法测试原始字节码）
    // 断言：重建利润 == 原始利润（精确到 wei）
}
```

关键设计：`vm.etch()` 将重建的字节码注入到原始合约地址，确保所有硬编码地址引用保持一致。两次独立 fork 防止前一次执行污染链上状态。

### 迭代修复案例：V2_SWAP 编码错误

首次组装完成后，对 TX_01 到 TX_08 的重放全部通过——利润精确匹配。然而 TX_09（cbETH 借贷市场）失败了，报错 `INSUFFICIENT_INPUT_AMOUNT`。

**排查过程**：

1. TX_01 使用 V3_SWAP，TX_09 使用 V2_SWAP——这是唯一的差异
2. 对比两笔交易的 calldata 长度：TX_01 是 600 字节，TX_09 是 601 字节——多了 1 字节
3. 逐字节扫描 TX_09 的指令流，发现 V2_SWAP 末尾有一个额外字节 `0x1e`（十进制 30）
4. 这是手续费字段：30 基点 = 0.3%，标准的 V2 swap 费率

**初始假设被推翻**：原以为 V2_SWAP 采用紧凑编码，实际上它与 V3_SWAP 共享完全相同的基础编码（`flag + pool + amt + dir + cb`），只是末尾多 1 字节 fee。

**更深层的错误**：V2 swap 需要在调用 `swap()` 之前先将输入代币 `transfer` 到池子（我们在第 3 篇中讨论过的"先转后 swap"范式）。初始版本遗漏了这步转账。

修复后 TX_09 和 TX_10 通过，利润精确匹配。

### 最终验证结果

经过多轮迭代修复：

| 验证维度 | 覆盖情况 |
|---------|---------|
| 利润精确匹配 | 14/15 笔（总偏差 0 wei） |
| 一致 revert | 1/15 笔（TX_FAIL，链上也 revert） |
| 借贷市场 | 7 个 Moonwell + 1 个 Morpho Blue |
| Swap 类型 | V3_SWAP（11 笔）+ V2_SWAP（2 笔） |
| 操作码覆盖 | 0x00/0x01/0x07/0x08/0x09/0x0a/0x0b（7 个，15 笔 TX 实际触发） |

2025-10-17 UTC 的 TX_FAIL（VIRTUAL 市场）链上即 revert（流动性不足），重建合约与原始合约行为一致——这本身就是一致性的验证。

未覆盖的部分：操作码 0x02（FLASH_LOAN_INITIATE）、0x03（WETH_DEPOSIT）、0x05（REGISTER_COPY）、0x06（SET_OR_MIN）等未被 Base 链 15 笔交易触发，仅基于字节码静态分析推断。42 个函数中仅少数被实际触发，其余基于跳板架构推断——它们共享同一 handler 实现，正确性有高置信度但非直接验证。后续跨链 replay 验证（13 条链 304 笔交易）覆盖了这些 opcode 的完整执行路径，最终统一重建为 AttackContract.sol（800+ 行），319 笔 replay 全部 PASS。

## 代理合约陷阱

在使用 Gas Profiler 分析交易 trace 时，一个异常现象引起了注意：`CLPool.flash()` 和 `MErc20Delegator.borrow()` 各自显示被调用了 2 次——但从指令流分析，它们应该各只调用 1 次。

**根因**：这两个合约都使用了代理模式（proxy + delegatecall）。外部调用到达 proxy 合约时，proxy 的 `fallback()` 触发一次计数，然后 `delegatecall` 到实际实现合约触发第二次计数。Gas Profiler 把两次都记录了。

Gas 差值佐证了这个判断：flash 的两次"调用"之间差 2,796 gas，borrow 差 4,235 gas——恰好是 proxy fallback 的开销。

**教训**：在使用 trace 工具分析代理合约时，需要区分"proxy 层调用"和"实现层 delegatecall"，否则会误判调用次数和 gas 分布。使用 `cast run --trace` 可以看到完整的 call 层级，更容易识别 delegatecall 关系。

## 动手环节

### 任务 1：用 Heimdall 反编译一个简单合约

选择一个已验证源码的简单合约（如 WETH），体验从字节码到伪代码的过程：

```bash
# 安装 Heimdall
cargo install heimdall-rs

# 反编译 Base 链上的 WETH 合约
heimdall decompile 0x4200000000000000000000000000000000000006 \
  --rpc-url https://mainnet.base.org \
  --output ./heimdall_output

# 查看反编译输出
cat ./heimdall_output/decompiled.sol
```

**观察**：对比已知的 WETH 源码（简单的 deposit/withdraw/transfer），Heimdall 的伪代码能还原多少原始逻辑？哪些部分是准确的？哪些是混乱的？

### 任务 2：用 cast run --trace 重放一笔 Base 链攻击交易

```bash
# 重放 TX_01，输出完整执行 trace
cast run 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  --rpc-url https://mainnet.base.org \
  --trace

# 简化输出：只看 CALL 层级
cast run 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  --rpc-url https://mainnet.base.org \
  --trace 2>&1 | grep -E "CALL|DELEGATECALL|STATICCALL"
```

**观察要点**：
- 第一个 `CALL` 是 `CLPool.flash()`——闪贷发起
- 回调 `uniswapV3FlashCallback()` 中可以看到对 Moonwell 的 `mint()`、`enterMarkets()`、`borrow()` 调用
- 最后是 `AlgebraPool.swap()` 和还贷的 `transfer()`

### 任务 3：对照 AttackContract.sol 验证

打开 `reference/mixed_contract/src/AttackContract.sol` 和 `reference/archive_0x42Ecd332/reports/attack_flow.md`，对照 trace 输出验证以下内容：

1. `approve()` 函数中两次指令集执行分别对应 trace 中的哪些调用？
2. 闪贷回调 `_handleUintCb()` 中执行了哪些指令？
3. 指令集 2 执行了哪些操作？

## 小结

逆向工程 AttackContract 的过程可以概括为六层递进的发现：从 45 个选择器的困惑，到跳板架构的揭示；从 `approve()` 的伪装，到双指令集的架构；从 V3_SWAP flag=1 的闪贷路径，到 CALL_WITH_AMOUNT 的 trail 适配机制。每一层发现都建立在前一层的基础上，逐步拼出完整的拼图。

核心方法论是**Calldata 驱动逆向**——不依赖反编译器的伪代码猜测，而是用真实交易的 calldata 逐字节对照 trace，让数据本身告诉你编码格式。而"编译→重放→失败→字节级对比→修复"的迭代循环，是逆向工程中将假设转化为验证的核心工作流。

第一阶段的重建代码通过了 Base 链 15 笔交易的 fork 重放验证——14 笔利润精确匹配到 wei 级别，1 笔链上也 revert（一致 revert）。功能等价性得到高置信度的确认。后续跨链分析和字节码同一性验证（详见第 9 篇）揭示了一个更大的发现：24,543 字节的字节码中那些在 Base 链 15 笔交易中从未触发的函数，实际上是为其他 13 条链上的 DEX 和闪贷协议准备的回调——这是同一份源码在几乎所有主要 EVM 链上参数化部署的直接证据。

**下一篇**：第 7 篇《指令引擎深度解析——12 操作码的两种实现》，我们系统对比 Lotus Router 与 AttackContract 两套指令引擎的设计差异，揭示 MEV 路由合约设计空间的核心权衡。
