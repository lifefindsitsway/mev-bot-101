# 第 4 篇：MEV 路由合约设计 —— Lotus Router 源码精读

在第 3 篇中，我们分别写了一个最简的 AAVE V3 闪贷合约和一个 Uniswap V3 swap 回调合约。它们各自都能工作——但问题是，真实的 MEV 攻击需要在一笔交易中**串联**多个操作：先闪贷，再存入借贷协议，再借出资产，再在 DEX 上 swap，再还闪贷，再提取利润。如果为每一种攻击策略都写一个专用合约，开发和部署成本不可接受。

MEV 路由合约的核心思想正是为了解决这个问题：不把策略逻辑写死在合约里，而是让合约成为一个**通用执行引擎**——策略以指令序列的形式编码在 calldata 中，合约逐条解码执行。换一套 calldata，就换一套策略。

Lotus Router 是开发者 jtriley2p 编写的一个开源 MEV 路由合约，也是我们能找到的最精炼的 Calldata 驱动 VM 实现。12 个操作码，全内联汇编的协议交互层，递归回调模型，自定义的 BBC（Big Brain Chad）压缩编码——所有这些设计都服务于一个目标：用最少的 gas 执行任意的 DeFi 操作序列。

这一篇，我们打开源码，从 `fallback()` 函数开始，逐层理解 MEV 路由合约的运行机制。

> **行业背景**：Lotus Router 发布后不久，jtriley2p 的前雇主对其提起版权投诉（DMCA），GitHub 仓库被删除。但源码已通过 IPFS 继续传播。jtriley2p 在 README 中写道："We grow tired of building the same software again and again"——这反映了 MEV 行业中路由合约技术被 NDA 和字节码混淆器严密保护的现实。

## 所有路由合约的本质：Calldata 驱动的虚拟机

在第 1 篇中我们提到，AttackContract 是"Calldata 驱动的虚拟机"。现在来精确定义这个概念。

一个 Calldata 驱动的 VM 有三个核心要素：

1. **指令集**：一组预定义的操作码（如"V2 swap"、"V3 swap"、"ERC20 transfer"），每个操作码对应一种链上操作
2. **指令流**：编码在 calldata 中的操作码序列，指定"先做 A，再做 B，再做 C"
3. **执行循环**：合约内的 `while` 循环，逐条读取操作码、解码参数、执行操作，直到遇到终止指令

Lotus Router 完美体现了这三个要素：

```
指令集：  12 个 Action（0x00 Halt ~ 0x0b DynCall）
指令流：  BBC 编码的 calldata（由链下系统生成）
执行循环：fallback() 中的 while(success) 循环
```

类比传统计算机：操作码是 CPU 的指令集，calldata 是程序的机器码，`fallback()` 是 CPU 的取指-解码-执行流水线。区别在于这个"CPU"运行在 EVM 上，每一条"指令"的执行都是一次链上操作。

## fallback() 主循环：取指-解码-执行

Lotus Router 的入口不是一个命名函数（如 `execute()`），而是 `fallback()`。这是一个有意的设计选择——`fallback()` 在没有匹配到任何函数选择器时触发，完全绕过 Solidity 的 ABI 编码和函数分派开销。

```solidity
// LotusRouter.sol — fallback() 核心逻辑（简化）
fallback() external payable {
    Ptr ptr = findPtr();          // 第 1 步：定位指令流的起始位置
    Action action;
    bool success = true;

    while (success) {             // 第 2 步：执行循环
        (ptr, action) = ptr.nextAction();  // 读取 1 字节操作码

        if (action == Action.Halt) {
            assembly { stop() }   // 0x00 → 成功终止（不是 revert！）
        }
        else if (action == Action.SwapUniV2) {
            // 解码 BBC 参数，执行 V2 swap
            (ptr, canFail, pair, amount0Out, amount1Out, to, data) =
                BBCDecoder.decodeSwapUniV2(ptr);
            success = pair.swap(amount0Out, amount1Out, to, data) || canFail;
        }
        else if (action == Action.SwapUniV3) {
            // 解码 BBC 参数，执行 V3 swap
            (ptr, canFail, pool, recipient, zeroForOne,
             amountSpecified, sqrtPriceLimitX96, data) =
                BBCDecoder.decodeSwapUniV3(ptr);
            success = pool.swap(recipient, zeroForOne, amountSpecified,
                                sqrtPriceLimitX96, data) || canFail;
        }
        else if (action == Action.FlashUniV3) {
            // 解码 BBC 参数，执行 V3 闪贷
            (ptr, canFail, pool, recipient, amount0, amount1, data) =
                BBCDecoder.decodeFlashUniV3(ptr);
            success = pool.flash(recipient, amount0, amount1, data) || canFail;
        }
        else if (action == Action.TransferERC20) {
            // 解码 BBC 参数，执行 ERC20 转账
            (ptr, canFail, token, receiver, amount) =
                BBCDecoder.decodeTransferERC20(ptr);
            success = token.transfer(receiver, amount) || canFail;
        }
        // ... 其他 7 个 Action 分支（TransferFromERC20, DepositWETH 等）
    }

    revert Error.CallFailure();   // 循环因 success=false 退出 → revert
}
```

执行流程可以概括为四步：

1. **定位指令**：`findPtr()` 根据当前调用的入口点（直接调用 vs 回调），计算 calldata 中指令流的起始偏移
2. **读取操作码**：`nextAction()` 从当前指针位置读取 1 个字节，解释为 Action 枚举值
3. **解码参数**：调用 `BBCDecoder` 中对应的解码函数，从 calldata 中解析出该操作的所有参数
4. **执行操作**：调用协议交互层的函数（如 `pair.swap()`、`token.transfer()`），获取执行结果

`nextAction()` 的实现极其简洁——只做一件事：

```solidity
// PayloadPointer.sol
function nextAction(Ptr ptr) pure returns (Ptr, Action action) {
    assembly {
        action := shr(0xf8, calldataload(ptr))  // 读 32 字节，右移 248 位取最高字节
        ptr := add(ptr, 0x01)                    // 指针前进 1 字节
    }
    return (ptr, action);
}
```

`calldataload(ptr)` 从 calldata 的 `ptr` 位置读取 32 字节到栈上，`shr(0xf8, ...)` 右移 248 位（31 字节），只保留最高的 1 字节。这就是操作码——一个 0x00 到 0x0b 之间的值。

一个巧妙的边界处理：当指令流执行完毕，`calldataload` 读取超出 calldata 边界的位置时，EVM 自动填充零字节。零字节 = `0x00` = `Action.Halt`，触发 `stop()` 成功返回。这意味着 calldata 末尾不需要显式的 Halt 指令。

## Action 指令集：12 个操作码

Lotus Router 的指令集定义在 `Action.sol` 中，共 12 个操作码，分为四类：

```solidity
enum Action {
    Halt,                // 0x00 — 终止执行，成功返回
    SwapUniV2,           // 0x01 — Uniswap V2 swap
    SwapUniV3,           // 0x02 — Uniswap V3 swap（触发回调）
    FlashUniV3,          // 0x03 — Uniswap V3 闪贷（触发回调）
    TransferERC20,       // 0x04 — ERC20 transfer
    TransferFromERC20,   // 0x05 — ERC20 transferFrom
    TransferFromERC721,  // 0x06 — ERC721 transferFrom
    TransferERC6909,     // 0x07 — ERC6909 transfer
    TransferFromERC6909, // 0x08 — ERC6909 transferFrom
    DepositWETH,         // 0x09 — ETH → WETH
    WithdrawWETH,        // 0x0a — WETH → ETH
    DynCall              // 0x0b — 任意合约调用
}
```

| 类别 | 操作码 | 说明 |
|------|--------|------|
| 终止 | Halt (0x00) | 成功终止执行循环 |
| DEX 交互 | SwapUniV2 (0x01), SwapUniV3 (0x02), FlashUniV3 (0x03) | 支持 V2 swap、V3 swap 和 V3 闪贷 |
| 代币操作 | TransferERC20 (0x04~0x05), ERC721 (0x06), ERC6909 (0x07~0x08) | 覆盖三种代币标准 |
| ETH/WETH | DepositWETH (0x09), WithdrawWETH (0x0a) | ETH 与 WETH 互转 |
| 通用 | DynCall (0x0b) | 调用任意合约的任意函数 |

几个设计亮点值得关注：

**WETH 地址不硬编码**：`DepositWETH` 和 `WithdrawWETH` 的 WETH 地址都从 calldata 传入，而不是硬编码在合约中。这使得同一份合约字节码可以部署到任何 EVM 链——不同链的 WETH 地址不同，但合约代码不需要改变。AttackContract 采用了不同的策略：通过构造函数传入 WETH 地址，存储为 immutable 变量。这意味着源码相同，但每条链需要用不同的构造函数参数重新部署——链间字节码差异仅 5×20=100 字节（5 处 WETH 引用）。

**DynCall 的万能性**：`DynCall`（0x0b）可以调用任意合约的任意函数，携带任意 calldata 和 ETH value。这意味着即使指令集没有为某个协议提供专用操作码，也可以通过 `DynCall` 发起调用。它是 Lotus Router 可扩展性的关键——AttackContract 的 `RAW_CALL`（0x09）、`CALL_WITH_AMT`（0x0a）和 `CALL_WITH_CHECK`（0x0b）扮演类似角色，且分拆为三个变体以适配不同调用场景。

**DEX 操作携带 data 参数**：`SwapUniV2`、`SwapUniV3` 和 `FlashUniV3` 都包含一个 `data` 参数。这个参数不是普通数据——它携带的是**后续要执行的指令序列**。这正是递归回调模型的基础。

## 递归回调模型：最核心也最难理解的设计

递归回调是 Lotus Router 与 AttackContract 最根本的架构差异，也是理解 Lotus Router 的关键。

### 问题：V3 swap 的回调中需要什么？

回顾第 3 篇的 V3 swap 流程：你调用 `pool.swap()`，池子回调你的 `uniswapV3SwapCallback()`，你在回调中转账欠款。在我们写的简单示例中，回调只做一件事——`transfer`。

但如果你要做一个 A → B → C 的两跳 swap 呢？

- 第一跳：用 token A 换 token B（在 Pool AB 中）
- 第二跳：用 token B 换 token C（在 Pool BC 中）

问题来了：当你发起第二跳 swap 时（Pool BC 回调你要求支付 token B），你还没有 token B——它要等第一跳执行后才能获得。V3 的回调模式允许你先收到 token C，再在回调中想办法获取 token B 来支付。但"想办法"就是执行第一跳 swap——这又会产生另一个回调。

Lotus Router 的解决方案：**将未执行的指令作为 `data` 参数传入 swap 调用，在回调中通过 `findPtr()` 恢复指令指针，继续执行**。

### 两跳 swap 的实际执行顺序

假设 calldata 中编码了一个 A → B → C 的两跳 swap（2 次 swap 操作，涉及 3 种代币）。指令序列是：

```
[SwapUniV3(BC)] [SwapUniV3(AB)] [TransferERC20(A→PoolAB)] [TransferERC20(B→PoolBC)]
```

注意指令的编码顺序和你可能预期的不同——**最外层的 swap 排在最前面**。执行过程如下：

```
第 1 步：fallback() 读取第一条指令 SwapUniV3(BC)
         将 [SwapUniV3(AB)] [Transfer(A→AB)] [Transfer(B→BC)] 作为 data
         调用 PoolBC.swap(...)

第 2 步：PoolBC 将 token C 转给 Lotus Router
         PoolBC 回调 uniswapV3SwapCallback()

第 3 步：回调触发 fallback()
         findPtr() 从回调参数中定位到 data 中的指令
         读取 SwapUniV3(AB)
         将 [Transfer(A→AB)] [Transfer(B→BC)] 作为 data
         调用 PoolAB.swap(...)

第 4 步：PoolAB 将 token B 转给 Lotus Router
         PoolAB 回调 uniswapV3SwapCallback()

第 5 步：回调再次触发 fallback()
         findPtr() 定位到 data 中的指令
         执行 Transfer(A→AB)：将 token A 转给 PoolAB（偿还第二跳欠款）
         执行 Transfer(B→BC)：将 token B 转给 PoolBC（偿还第一跳欠款）
         读到 Halt（或 calldata 结束，自动为 0x00）→ stop()

第 6 步：所有回调返回，所有债务清偿
         PoolAB 和 PoolBC 各自验证余额 ✓
         交易成功完成
```

关键洞察：**执行顺序与编码顺序相反**。第一条编码的指令（SwapBC）最先发起但最后完成（等所有回调结束后 PoolBC 才验证余额）。这类似于函数调用栈——先进后出。

Lotus Router 的 README 中有一段精辟的总结："While it is possible to simplify encoding control flow by calling iteratively, recursion saves O(n) calls."——递归模型相比迭代模型节省了 O(n) 次外部调用，因为 token 转账可以在最内层的回调中"批量"完成。

### 与 AttackContract 的架构差异

AttackContract 采用完全不同的方案——**线性模型**：

- 闪贷回调中执行全部指令（借贷、swap、利润提取），指令按执行顺序编码
- swap 回调**不执行指令**，只负责转账欠款
- 指令流中有 `amount` 寄存器，可以在运行时查询余额并动态调整

| 特性 | Lotus Router（递归） | AttackContract（线性） |
|------|-------------------|--------------|
| 指令编码顺序 | 与执行顺序反向 | 与执行顺序一致 |
| swap 回调中 | 继续执行指令 | 仅转账欠款 |
| 多跳 swap | 嵌套回调实现 | 每跳独立执行 |
| 状态管理 | 无状态（所有值预计算） | 有 amount 寄存器 |
| calldata 复杂度 | 嵌套递增 | 固定线性 |
| 调试难度 | 高（嵌套调用栈） | 低（线性 trace） |

两种模型各有优劣。递归模型更省 gas（减少外部调用），但编码和调试更复杂。线性模型更直观，且 amount 寄存器让链下系统不需要预计算所有中间值——可以用 `BALANCE_OF` 在运行时查询。

## findPtr()：回调中恢复指令指针

递归回调模型的核心问题是：当 Uniswap V3 回调你的合约时，你怎么知道指令流在 calldata 中的什么位置？

答案是 `findPtr()`。它根据 `msg.sig`（当前调用的函数选择器）推导出指令流的起始偏移：

```solidity
// PayloadPointer.sol
function findPtr() pure returns (Ptr) {
    uint256 selector = uint256(uint32(msg.sig));

    if (selector == takeAction) {          // 0x19ff8034
        return Ptr.wrap(0x04);             // 直接调用：指令从第 5 字节开始
    }
    else if (selector == uniswapV2Call) {  // 0x10d1e85c
        return Ptr.wrap(0xa4);             // V2 回调：跳过 4+32×5 字节（selector+sender+amt0+amt1+offset+length）
    }
    else if (selector == uniswapV3SwapCallback) { // 0xfa461e33
        return Ptr.wrap(0x84);             // V3 swap 回调：跳过 4+32×4 字节（selector+a0Delta+a1Delta+offset+length）
    }
    else if (selector == uniswapV3FlashCallback) { // 0xe9cbafb0
        return Ptr.wrap(0x84);             // V3 flash 回调：同 V3 swap
    }
    else {
        revert Error.UnexpectedEntryPoint();
    }
}
```

不同偏移的原因是不同回调函数的 ABI 参数布局不同。以 `uniswapV3SwapCallback` 为例：

```
Calldata 布局：
[0x00-0x03]  函数选择器（4 字节）
[0x04-0x23]  int256 amount0Delta（32 字节）
[0x24-0x43]  int256 amount1Delta（32 字节）
[0x44-0x63]  bytes data 的 ABI offset（32 字节，值通常为 0x60）
[0x64-0x83]  bytes data 的长度（32 字节）
[0x84-...]   bytes data 的实际内容 ← 指令从这里开始
```

所以 `0x84` 正是 `data` 参数中实际字节数据的起始位置。`findPtr()` 告诉执行循环："跳过回调函数的固定参数，直接从 `data` 的内容开始读取指令。"

对于 `uniswapV2Call`，因为多了一个 `address sender` 参数（32 字节），所以偏移多了 0x20，变成 `0xa4`。

这个机制让 Lotus Router 的 `fallback()` 函数可以同时作为：
- 主入口（通过 `takeAction` 调用）
- V2 swap 回调（被 Uniswap V2 池调用）
- V3 swap 回调（被 Uniswap V3 池调用）
- V3 flash 回调（被 Uniswap V3 池调用）

同一套执行循环，四种入口，通过 `findPtr()` 统一路由。

## canFail：操作级容错

并非所有操作都必须成功。Lotus Router 为每个操作提供了一个 `canFail` 布尔标志：

```solidity
success = pair.swap(amount0Out, amount1Out, to, data) || canFail;
```

当 `canFail = true` 时，即使 `swap()` 调用失败（返回 false），`success` 仍然为 true，执行循环继续处理下一条指令。

这在多路径套利中非常有用：假设你想在三个 DEX 中尝试同一笔 swap，哪个池子有流动性就用哪个。你可以将前两个标记为 `canFail = true`，第三个标记为 `canFail = false`。如果第一个池子流动性不足导致 swap 失败，执行跳过它继续尝试下一个。

对比 AttackContract 的策略：AttackContract 对所有操作使用硬性的 `require(ok)` ——任何一步失败就立即 revert 整笔交易。这种"全有或全无"的策略在预言机套利场景下是合理的——如果某一步失败，后续步骤也不可能成功，不如早点回滚节省 gas。

AttackContract 另有一个 `CALL_WITH_CHECK`（0x0b）操作码提供条件验证——不是"允许失败"，而是"检查返回值是否满足预期"。两种设计哲学的差异：

| 机制 | Lotus Router canFail | AttackContract require + CALL_WITH_CHECK |
|------|---------------------|--------------------------------|
| 失败行为 | 跳过，继续执行 | 立即 revert |
| 适用场景 | 多路径探测 | 确定性攻击路径 |
| gas 浪费风险 | 失败的操作仍消耗 gas | 早期 revert 节省 gas |

## 协议交互层：内联汇编的 gas 极致优化

Lotus Router 的协议交互层（`ERC20.sol`、`WETH.sol`、`UniV3Pool.sol` 等）全部使用内联汇编实现，绕过 Solidity 编译器的安全检查以节省 gas。这些代码是学习 EVM 底层操作的优秀教材。

### ERC20 transfer：scratch space 复用

```solidity
// types/protocols/ERC20.sol — transfer 函数
function transfer(ERC20 token, address receiver, uint256 amount)
    returns (bool success)
{
    assembly ("memory-safe") {
        // 构造 transfer(address,uint256) 的 calldata
        mstore(0x00, transferSelector) // 0xa9059cbb << 224
        mstore(0x04, receiver)         // 接收者地址
        mstore(0x24, amount)           // 转账金额

        // 发起低级 call
        success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)

        // 兼容非标准 ERC20（如 USDT 不返回值）
        let successERC20 := or(
            iszero(returndatasize()),       // 无返回数据 → 视为成功
            eq(0x01, mload(0x00))           // 或返回值 == true
        )
        success := and(success, successERC20)

        // 清理：恢复被覆盖的内存
        mstore(0x24, 0x00)
    }
}
```

三个关键优化点：

**Scratch space 复用**：EVM 内存的 0x00-0x3f（64 字节）是 Solidity 的 scratch space，用于临时计算。Lotus Router 直接在这里构造 calldata（`mstore(0x00, ...)`），而不是通过 `mload(0x40)` 获取 free memory pointer 再分配新内存。节省了内存分配和指针管理的 gas。

**非标准 ERC20 兼容**：有些 ERC20 代币（如 USDT）的 `transfer` 函数不返回布尔值。`iszero(returndatasize())` 处理了这种情况——如果没有返回数据，视为成功。

**清理 0x24**：`mstore(0x24, amount)` 写入 32 字节到 0x24-0x43，溢出到 free memory pointer 所在的 0x40 位置（覆盖了 0x40-0x43 共 4 字节），需要用 `mstore(0x24, 0x00)` 清零恢复。

### WETH deposit：不调用 deposit()

```solidity
// types/protocols/WETH.sol — deposit 函数
function deposit(WETH weth, uint256 value) returns (bool success) {
    assembly ("memory-safe") {
        success := call(gas(), weth, value, 0x00, 0x00, 0x00, 0x00)
        //                            ↑ETH   ↑输入偏移 ↑输入长度
    }
}
```

这段代码做了一件反直觉的事：它**没有调用 WETH 合约的 `deposit()` 函数**。

`call` 的输入长度参数为 0x00（第 5 个参数），意味着发送空 calldata。当 WETH 合约收到一笔没有 calldata 的 ETH 转账时，会触发它的 `receive()` 函数。标准 WETH 实现中，`receive()` 与 `deposit()` 行为一致——都是接收 ETH 并 mint 等量的 WETH。

为什么要这样做？因为 Solidity 的 WETH 实现在处理入站调用时，会先检查 `calldatasize` 是否为零。如果为零，直接进入 `receive()`，跳过了选择器匹配的开销。虽然节省的 gas 微乎其微，但在 MEV 场景下，每一个 gas 都有价值。

### 内存管理的三种策略

Lotus Router 根据 calldata 大小选择不同的内存管理策略：

| 策略 | 适用场景 | 示例 | 特点 |
|------|---------|------|------|
| Scratch space 直写 | calldata 接近 64B | ERC20 transfer (68B，溢出 4B 到 FMP 区域) | 最快，但需要清理溢出部分 |
| Scratch space + FMP 备份 | calldata > 64B 且不太长 | ERC20 transferFrom (100B) | 先备份 `mload(0x40)`，末尾恢复 FMP + 清零 0x60 |
| FMP 位置写入 | calldata 较大且含动态数据 | UniV3Pool swap | 在 FMP 指向的内存位置构造，用 `calldatacopy` 复制 |

第三种策略在 V3 swap 和 flash 中使用，因为 `data` 参数的长度不确定：

```solidity
// types/protocols/UniV3Pool.sol — swap 函数（简化）
assembly ("memory-safe") {
    let fmp := mload(0x40)
    let dataLen := shr(0xe0, calldataload(data))  // 读取 data 的 4 字节长度

    mstore(add(fmp, 0x00), swapSelector)
    mstore(add(fmp, 0x04), recipient)
    mstore(add(fmp, 0x24), zeroForOne)
    mstore(add(fmp, 0x44), amountSpecified)
    mstore(add(fmp, 0x64), sqrtPriceLimitX96)
    mstore(add(fmp, 0x84), 0xa0)             // data 的 ABI offset
    mstore(add(fmp, 0xa4), dataLen)           // data 的长度
    calldatacopy(add(fmp, 0xc4), data, dataLen) // 复制 data 内容

    success := call(gas(), pool, 0x00, fmp, add(dataLen, 0xe4), 0x00, 0x00)
}
```

注意 `calldatacopy` 的使用——它直接从 calldata 复制数据到内存，比 Solidity 的 `bytes memory` 操作更高效，因为不涉及 ABI 解码和内存分配。

## 动手环节

### 任务 1：走一遍 "ERC20 transfer + V3 swap" 流程

假设你要在 Lotus Router 上执行以下操作序列：

1. 将 1000 USDC 从 Lotus Router 转给 Uniswap V3 Pool（偿还上一次 swap 的欠款）
2. 发起一笔 V3 swap（用 WETH 换 USDC）

**提示**：由于递归模型，指令编码顺序与你预期的执行顺序**相反**：

```
实际编码：[SwapUniV3(WETH→USDC)] [TransferERC20(USDC→Pool)] [Halt]
```

**逐步跟踪**：

1. `fallback()` 启动，`findPtr()` 返回 0x04
2. `nextAction()` 读取第 1 字节 → `0x02`（SwapUniV3）
3. `BBCDecoder.decodeSwapUniV3(ptr)` 解码参数：pool, recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, **data**
   - `data` 包含 `[TransferERC20(USDC→Pool)] [Halt]`
4. 调用 `pool.swap(..., data)` → V3 Pool 执行 swap，将 USDC 转给 Lotus Router
5. V3 Pool 回调 `uniswapV3SwapCallback(amount0Delta, amount1Delta, data)`
6. `fallback()` 再次触发，`findPtr()` 看到 `msg.sig == uniswapV3SwapCallback`，返回 0x84
7. `nextAction()` 读取 data 中的第 1 字节 → `0x04`（TransferERC20）
8. 解码参数，执行 `USDC.transfer(pool, 1000e6)` → 偿还欠款
9. `nextAction()` 读取下一字节 → `0x00`（Halt）→ `stop()` 成功返回
10. 回调结束，V3 Pool 验证余额 ✓

**练习**：打开 `reference/lotus-router-src/src/LotusRouter.sol`，对照上述流程，在源码中标注每一步对应的代码行号。

### 任务 2：手动构造一条 BBC 编码的 calldata

用 BBC 编码规则手动编码一个 `TransferERC20` 操作：将 1 ETH（`0x0de0b6b3a7640000`，8 字节）的 WETH 转给地址 `0xf39F...2266`。

**编码规则**：
- Action 字节：`0x04`（TransferERC20）
- canFail：`0x00`（不允许失败）
- token（WETH 地址，20 字节）：`[长度前缀 0x14] [地址 20 字节]`
- receiver（20 字节）：`[长度前缀 0x14] [地址 20 字节]`
- amount（8 字节）：`[长度前缀 0x08] [金额 8 字节]`

**手动编码结果**：

```
04                                        // Action = TransferERC20
00                                        // canFail = false
14                                        // token 长度 = 20 字节
C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2  // WETH (Ethereum 主网)
14                                        // receiver 长度 = 20 字节
f39Fd6e51aad88F6F4ce6aB8827279cffFb92266  // 接收地址
08                                        // amount 长度 = 8 字节
0de0b6b3a7640000                          // 1 ETH = 10^18
```

总长度：1 + 1 + 1 + 20 + 1 + 20 + 1 + 8 = **53 字节**

对比标准 ABI 编码的 `transfer(address,uint256)`：4（selector）+ 32 + 32 = **68 字节**

BBC 编码节省了 22%。对于包含更多零字节的参数（如小金额），压缩率会更高。

**进一步练习**：尝试编码一个 `SwapUniV2` 操作。参考 README 中的 288B vs 66B 量化对比——同一笔 V2 swap，ABI 编码 288 字节，BBC 编码仅 66 字节，压缩 77%。

## 小结

Lotus Router 是一个教科书级的 Calldata 驱动 VM 实现。它的 `fallback()` 主循环逐条读取 1 字节操作码、解码 BBC 参数、执行链上操作，形成一个完整的取指-解码-执行流水线。12 个 Action 操作码覆盖了 DEX swap、闪贷、代币转账和通用调用四类功能。

递归回调模型是 Lotus Router 最精妙的设计——通过将未执行的指令作为 `data` 参数传入 swap/flash 调用，在回调中通过 `findPtr()` 恢复指令指针继续执行。这种嵌套式执行让多跳 swap 可以在最内层回调中批量结算所有欠款，节省了外部调用次数。

协议交互层的内联汇编展示了 EVM 底层优化的最佳实践：scratch space 复用、FMP 备份恢复、非标准 ERC20 兼容处理、空 calldata 触发 WETH `receive()`。这些技巧在 AttackContract 中同样可以找到对应的实现。

**下一篇**：第 5 篇《Calldata 压缩编码——三套方案的工程权衡》，我们将深入比较 Lotus Router 的 BBC 长度前缀编码、AttackContract 的固定宽度编码和标准 ABI 编码，在字节级别展示三种方案的差异和工程取舍。
