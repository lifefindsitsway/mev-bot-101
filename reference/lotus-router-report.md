# Lotus Router 源码研究报告

## 1. 项目概况

Lotus Router 是由匿名开发者 jtriley2p 编写的开源 MEV 交易路由合约，采用 AGPL-3.0 许可证发布。项目的核心定位是一个**嵌入式虚拟机**，将 DeFi 协议交互（主要是 AMM swap）编码为紧凑的指令序列，通过 calldata 传入合约后逐条解码执行。合约本身不收取任何费用、不可升级、无权限控制，是一个纯粹的执行层组件。

项目使用 Solidity 0.8.28 编写，编译配置为 `via_ir = true`，optimizer_runs 设为 `0xffffffff`（最大值，倾向于优化运行时 gas 而非部署成本）。这个编译配置本身就暗示了合约的用途——MEV 场景下每笔交易的 gas 成本远比一次性的部署成本重要。

项目发布后不久，jtriley2p 的前雇主对其发起了版权投诉（DMCA），声称代码涉及商业机密。GitHub 仓库被删除后，源码通过 IPFS 继续传播（CID: `bafkreif2ffb2kghamkdjp5pcgrsxu26hx42w3imujcq6zeqacwzsg5pbla`）。README 中收录的宣言——"We grow tired of building the same software again and again"——直接回应了 MEV 行业中路由合约技术被 NDA 和字节码混淆器保护的现状。

---

## 2. 架构总览

### 2.1 系统分层

Lotus Router 的代码组织清晰地分为四个层次：

第一层是**入口调度层**（`LotusRouter.sol`），一个 218 行的合约，包含 `fallback()` 和 `receive()` 两个函数。`fallback()` 是唯一的执行入口，内部是一个 `while(success)` 循环，根据解码出的 Action 枚举值分派到对应的处理逻辑。`receive()` 为空函数，仅用于接收 ETH。

第二层是**编解码层**（`BBCDecoder.sol` + `BBCEncoder.sol`），实现了一套受 bigbrainchad.eth 启发的自定义 calldata 压缩编码方案（下文简称 BBC 编码）。解码器约 725 行纯内联汇编，编码器约 693 行混合汇编。

第三层是**协议交互层**（`src/types/protocols/` 目录下 7 个文件），每个文件封装了一种协议的底层调用逻辑（ERC20、ERC721、ERC6909、UniV2Pair、UniV3Pool、WETH、Dyn）。全部使用内联汇编实现，手动管理内存布局。

第四层是**类型系统**（`Action.sol`、`BytesCalldata.sol`、`PayloadPointer.sol`、`Error.sol`），定义了 Action 枚举、calldata 指针类型、payload 指针和错误类型。

### 2.2 执行流程

一笔 Lotus Router 交易的完整执行路径如下：

外部调用到达合约后，由于使用 `fallback()` 而非命名函数作为入口，Solidity 的 ABI 编码机制被完全绕过。`findPtr()` 函数根据 `msg.sig`（4 字节函数选择器）确定 calldata 中指令流的起始偏移：如果是直接调用（`takeAction` 选择器 `0x19ff8034`），指令从 offset 0x04 开始；如果是 Uniswap V2 回调（`uniswapV2Call`），指令从 offset 0xa4 开始（跳过 `address sender`、`uint256 amount0`、`uint256 amount1` 三个 ABI 参数后进入 `bytes data` 的数据部分）；如果是 V3 swap 或 flash 回调，指令从 offset 0x84 开始（跳过两个 `int256`/`uint256` 参数后进入 `bytes data`）。

获得指令指针后，`while(success)` 循环开始工作。每轮循环读取 1 字节 action（通过 `calldataload` + `shr(0xf8)` 提取最高字节），然后根据 action 值调用 `BBCDecoder` 中对应的解码函数，解码出该操作的所有参数，最后调用协议交互层的执行函数。执行函数返回 `bool success`，与 `canFail` 标志进行 `||` 运算——如果操作失败但 `canFail` 为 true，循环继续；否则 `success` 变为 false，循环终止，合约 revert 并抛出 `Error.CallFailure()`。

当 action 为 `0x00`（Halt）时，合约执行 `assembly { stop() }` 直接终止——不是 revert，而是成功返回。这意味着 calldata 末尾超出部分被 `calldataload` 读取时自动填充为 0，正好等于 `Action.Halt`，所以不需要显式的结束标记。

---

## 3. 指令集详解

### 3.1 Action 枚举（12 个操作码）

Lotus Router 定义了 12 个 action（0x00-0x0b），可以分为四类：

**终止指令**：`Halt`（0x00）——停止执行，成功返回。

**DEX 交互**：`SwapUniV2`（0x01）、`SwapUniV3`（0x02）、`FlashUniV3`（0x03）。V2 swap 直接调用 `pair.swap(amount0Out, amount1Out, to, data)`；V3 swap 调用 `pool.swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data)`；V3 flash 调用 `pool.flash(recipient, amount0, amount1, data)`。三者都携带 `data` 参数——这是实现递归回调的关键。

**代币操作**：`TransferERC20`（0x04）、`TransferFromERC20`（0x05）、`TransferFromERC721`（0x06）、`TransferERC6909`（0x07）、`TransferFromERC6909`（0x08）。覆盖了 ERC20 的 `transfer`/`transferFrom`、ERC721 的 `transferFrom`、以及 ERC6909（Uniswap V4 使用的多代币标准）的 `transfer`/`transferFrom`。

**ETH/WETH 操作**：`DepositWETH`（0x09）、`WithdrawWETH`（0x0a）。注意 WETH 地址不是硬编码的——它作为参数从 calldata 传入，这使得合约可以在任何 EVM 链上部署而无需修改。

**通用调用**：`DynCall`（0x0b）——调用任意合约的任意函数，携带任意 calldata 和 ETH value。这是 Lotus Router 可扩展性的核心——任何不在上述操作中的协议交互，都可以通过 `DynCall` 实现。

### 3.2 与 AttackContract 操作码对比

> **命名说明**：逆向分析初期，Base 链部署（`0x42Ecd332`）被称为 "MevBot"，跨链部署（`0xA98E339f`）被称为 "AttackEngine"。经字节码同一性验证后确认两者为同一份源码的不同部署，统一称为 **AttackContract**。

Lotus Router 的 12 个 action 在编号范围上与 AttackContract 的 12 个 opcode（0x00-0x0b）完全相同，但语义映射存在有趣的差异：

| 编号 | Lotus Router | AttackContract | 关键差异 |
|------|-------------|----------------|---------|
| 0x00 | Halt（终止） | V2_SWAP / V2_FLASH | LR 用 0x00 做终止标记；AC 用 0x00 做 V2 swap |
| 0x01 | SwapUniV2 | V3_SWAP / V3_FLASH | LR 将 V2 swap 和 V3 flash 分为独立 action；AC 将 V3 swap 和 flash 合并为同一 opcode（flag=0/1 区分） |
| 0x02 | SwapUniV3 | FLASH_LOAN_INITIATE | 完全不同：LR 是 V3 swap，AC 是发起闪电贷（Balancer/AaveV3/EulerV2） |
| 0x03 | FlashUniV3 | WETH_DEPOSIT | 完全不同：LR 是 V3 flash，AC 是 WETH 存入 |
| 0x04 | TransferERC20 | WETH_WITHDRAW | LR 是 ERC20 转账；AC 是 WETH 提取 |
| 0x05 | TransferFromERC20 | REGISTER_COPY | LR 是 transferFrom；AC 是寄存器拷贝（amount = secondaryRegister） |
| 0x06 | TransferFromERC721 | SET_OR_MIN | LR 是 NFT 转移；AC 是条件设置金额（flag=0 无条件设置，flag=1 取 min） |
| 0x07 | TransferERC6909 | BALANCE_OF | LR 是 ERC6909 转账；AC 是查余额到 amount 寄存器 |
| 0x08 | TransferFromERC6909 | SUB_BALANCE | LR 是 ERC6909 transferFrom；AC 是从 amount 寄存器减去指定 token 余额 |
| 0x09 | DepositWETH | RAW_CALL | LR 的 WETH 操作在这里；AC 的通用调用在这里 |
| 0x0a | WithdrawWETH | CALL_WITH_AMT | 类似 |
| 0x0b | DynCall | CALL_WITH_CHECK | 两者都是"通用"调用，但 AC 的版本还包含返回值校验 |

最根本的架构差异是 **AttackContract 有 `amount` 寄存器而 Lotus Router 没有**。AttackContract 用 4 个操作码（REGISTER_COPY 0x05、SET_OR_MIN 0x06、BALANCE_OF 0x07、SUB_BALANCE 0x08）来管理一个跨指令共享的金额变量，使得"先查余额再全部 swap"这样的动态操作成为可能。Lotus Router 要求调用者在链下预计算所有精确值，不支持运行时的金额查询和动态调整。

---

## 4. BBC 编码方案

### 4.1 设计原理

BBC 编码（BigBrainChad 编码）的核心思想是消除 ABI 编码中的前导零填充。标准 Solidity ABI 将所有值填充到 32 字节对齐，一个 20 字节的 address 会浪费 12 字节前导零（48 gas，因为零字节 4 gas/字节）。BBC 编码用 1 字节长度前缀标明实际值的字节长度，然后只存储去除前导零后的紧凑值。

编码规则分为三类。对于 8 位及以下的静态类型（如 `bool`），直接编码为 1 字节，不需要长度前缀。对于 9-256 位的静态类型（如 `address`、`uint256`），前缀 1 字节 `byte_len_u8` 标明实际长度，后跟紧凑值。对于动态类型（如 `bytes`），前缀 4 字节 `byte_len_u32` 标明长度，后跟原始数据。

### 4.2 压缩效果量化

README 中给出了一个具体的对比示例——一笔 Uniswap V2 swap 调用。标准 ABI 编码需要 288 字节，BBC 编码仅需 66 字节，压缩率达到 77%（节省 222 字节）。

以 ERC20 `transfer(address, uint256)` 为例做更细致的拆解：标准 ABI 需要 4（selector）+ 32（address）+ 32（amount）= 68 字节。BBC 编码需要 1（action）+ 1（canFail）+ 1（token_len）+ 20（token）+ 1（receiver_len）+ 20（receiver）+ 1（amount_len）+ N（amount）= 45 + N 字节（N 取决于 amount 的实际大小）。当 amount 为 1 ETH（8 字节）时，BBC 编码为 53 字节，节省 22%。当 amount 很小（如 1 wei = 1 字节）时，BBC 编码为 46 字节，节省 32%。

### 4.3 解码实现细节

`BBCDecoder` 中的解码模式高度统一。以 `decodeSwapUniV3` 为例，解码一个长度前缀字段的核心三行汇编是：

```solidity
nextByteLen := shr(u8Shr, calldataload(nextPtr))        // 读取 1 字节长度
nextBitShift := sub(0x0100, mul(0x08, nextByteLen))      // 计算位移量 = 256 - 8*len
nextPtr := add(nextPtr, 0x01)                             // 跳过长度字节
pool := shr(nextBitShift, calldataload(nextPtr))          // 读取 32 字节并右移
```

`calldataload(nextPtr)` 总是从 calldata 的 `nextPtr` 位置读取 32 字节到栈顶。由于实际值可能只占前几个字节（比如 address 占 20 字节），需要右移 `(32 - len) * 8` 位来将值对齐到低位。公式 `sub(0x0100, mul(0x08, nextByteLen))` 中，`0x0100` 是十进制 256，`mul(0x08, nextByteLen)` 是 `8 * len`，相减得到右移量。

有符号整数（`int256 amountSpecified`）的解码额外需要一步 `signextend`：

```solidity
amountSpecified := shr(nextBitShift, calldataload(nextPtr))
amountSpecified := signextend(sub(nextByteLen, 0x01), amountSpecified)
```

`signextend(b, x)` 将 `x` 的第 `b` 字节的最高位视为符号位，向高位扩展。例如，一个 2 字节的负数 `0xFF01` 被 `signextend(1, 0xFF01)` 扩展为 `0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF01`。

### 4.4 编码器的 `byteLen` 实现

`BBCEncoder` 中的 `byteLen` 函数负责计算一个值去除前导零后的实际字节长度。`uint256` 版本从高位向低位逐字节检查，找到第一个非零字节就返回。`address` 版本类似，但上限是 20 字节。`int256` 版本有特殊处理：先取绝对值转为 `uint256`，如果绝对值占满 32 字节则直接返回 32（避免符号位丢失），否则将绝对值左移 1 位后再计算长度——这等价于为符号位预留一个 bit 的空间。

---

## 5. 递归回调模型

### 5.1 核心机制

Lotus Router 处理 Uniswap V3 多跳 swap 的方式与 AttackContract 有本质不同。AttackContract 采用线性模型：闪贷回调接收嵌套指令并执行，swap 回调仅做欠款转账。Lotus Router 采用递归模型：当执行 V3 swap 时，将"当前指令指针之后的所有指令"打包为 `data` 参数传给 Uniswap V3 的 `swap()` 调用，然后在 `uniswapV3SwapCallback` 回调中，`findPtr()` 从回调参数中定位到这些指令，继续从 `fallback()` 的 `while(success)` 循环处理。

这意味着 A→B→C 的三跳 swap 实际执行顺序是反向的。外层调用先发起 B→C swap，V3 池在回调中要求支付 token B。回调中 Lotus Router 发起 A→B swap，V3 池在回调中要求支付 token A。最内层的回调执行两步 transfer：将 token A 转给 MarketAB（偿还第二笔 swap），将 token B 转给 MarketBC（偿还第一笔 swap）。

### 5.2 `findPtr` 的偏移计算

`findPtr()` 根据不同入口点返回不同的 calldata 偏移，原因在于各回调函数的 ABI 编码布局不同。

对于 `uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)`，ABI 编码后 calldata 布局为：4 字节 selector + 32 字节 amount0Delta + 32 字节 amount1Delta + 32 字节 data offset + 32 字节 data length + data bytes。其中 data 的内容（即 Lotus Router 的指令）从 offset `4 + 32 + 32 + 32 + 32 = 132 = 0x84` 开始。但实际上 `0x84` 处存储的是 data 的长度（uint32 格式），data 的实际字节从 `0x84 + 4 = 0x88` 开始。不过 Lotus Router 的 `BBCDecoder` 从 `data` 指针（即 `0x84`）开始解码时，会先读取 4 字节作为 `data_byte_len_u32`，然后再读取实际数据——所以 `0x84` 是正确的起始位置。

对于 `uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data)`，多了一个 `address` 参数（32 字节 ABI 编码），所以 data 从 `0x84 + 0x20 = 0xa4` 开始。

### 5.3 递归 vs 线性的工程权衡

递归模型的优势在于减少外部调用次数。在 A→B→C 路径中，线性模型需要单独发起 3 次 `pool.swap()` 调用（每次都是外部调用），而递归模型在回调链中嵌套执行，省去了一些重复的函数调度开销。README 中明确指出："While it is possible to simplify encoding control flow by calling iteratively, recursion saves O(n) calls."

但递归模型也有明显劣势。调试困难——执行流在多个 call context 之间跳转，trace 日志非常复杂。calldata 体积会随嵌套深度线性增长——每一层嵌套都要将后续指令完整复制到 `data` 参数中。gas 消耗也随嵌套深度增加，因为每层回调的 calldata 都包含了所有后续指令的完整拷贝。

---

## 6. 协议交互层的内联汇编

### 6.1 内存管理策略

Lotus Router 的协议交互函数全部使用 `assembly ("memory-safe")` 标注的内联汇编实现，手动管理 EVM 内存布局。代码中展示了三种不同的内存管理策略，取决于所需 calldata 的大小。

**策略一：scratch space 复用**。当 calldata 不超过 64 字节时（如 ERC20 `transfer` 的 68 字节 = selector + address + uint256），直接写入内存的 0x00-0x44 区域。这个区域是 Solidity 保留的"scratch space"，正常用于 keccak256 哈希计算，可以自由覆写。但 0x40-0x44 与空闲内存指针（free memory pointer，存储在 0x40-0x60）有 4 字节重叠，所以函数末尾需要用 `mstore(0x24, 0x00)` 将 0x24-0x44 区域清零，恢复空闲指针的高位字节。

**策略二：scratch space + FMP 备份**。当 calldata 超过 64 字节但不太长时（如 ERC20 `transferFrom` 的 100 字节），会完全覆盖空闲内存指针和零槽（zero slot，0x60-0x80）。此时先用 `let fmp := mload(0x40)` 备份空闲指针，函数末尾用 `mstore(0x40, fmp)` 和 `mstore(0x60, 0x00)` 恢复两个关键区域。

**策略三：FMP 位置写入**。当 calldata 较大或包含动态数据时（如 UniV3 `swap`、UniV2 `swap`），将数据写入空闲内存指针指向的位置（`fmp`），并用 `calldatacopy` 将动态数据从 calldata 复制到内存。这种策略不更新空闲指针——意味着后续 Solidity 代码可能会覆写这些数据，但在 Lotus Router 的上下文中这不是问题，因为数据在 `call` 执行后就不再需要。

### 6.2 ERC20 兼容性处理

ERC20 标准的实现在以太坊上存在广泛的不一致性。有些代币在 `transfer` 失败时 revert，有些返回 false，有些成功时不返回任何数据（如 USDT），有些返回 true。Lotus Router 的 `transfer` 函数用以下逻辑处理这些情况：

```solidity
success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)
let successERC20 := or(iszero(returndatasize()), eq(0x01, mload(0x00)))
success := and(success, successERC20)
```

`call` 返回 false 表示执行 revert。`returndatasize()` 为 0 表示没有返回数据（如 USDT 成功情况）。`mload(0x00)` 读取返回数据的前 32 字节，等于 1 表示返回了 true。最终 `success` 为这两个条件的逻辑与。

值得注意的是，如果目标地址是 EOA（没有代码），`call` 也会返回 true 且 `returndatasize` 为 0——Lotus Router 会将这视为成功。这在某些安全敏感的场景中可能是风险点，但 README 中的 "Work In Progress, Do Not Use Yet" 标注暗示这些边缘情况尚未完全处理。更严格的实现（如 Solady 的 SafeTransferLib）会用 `extcodesize` 检查目标地址是否有代码。

### 6.3 WETH 的 deposit 优化

`WETH.deposit` 的实现有一个有趣的细节——它不调用 WETH 的 `deposit()` 函数，而是直接发送 ETH（calldata 长度为 0）：

```solidity
success := call(gas(), weth, value, 0x00, 0x00, 0x00, 0x00)
```

README 中解释了原因："using the fallback function with no calldata is marginally cheaper than using the `deposit()` function, as Solidity short circuits the selector dispatcher in WETH if the `calldatasize` is zero." 标准 WETH 合约的 `receive()` 函数与 `deposit()` 功能相同，但跳过了 selector 匹配的开销。

---

## 7. canFail 容错机制

每个操作都有一个 `canFail` 布尔标志，编码在操作参数的第一个字节。当 `canFail` 为 true 时，即使操作的底层 `call` 返回 false（执行失败），`while` 循环仍然继续处理下一条指令。这通过 `success = result || canFail` 的逻辑实现。

这个机制在 MEV 场景中非常实用。一个常见的用例是多路径套利：尝试在池 A 做 swap，如果失败（如流动性不足），跳过并尝试池 B。只要有一个池成功就能完成套利。另一个用例是"尽力而为"的代币归集——尝试从多个池子收集代币，某些池子可能已经被清空，但不影响整体流程。

但 `canFail` 也引入了一个微妙的风险。如果一个关键操作（如闪贷归还）被错误地标记为 `canFail = true`，归还失败后执行会继续而非 revert，最终可能导致整个交易因为闪贷池的检查而 revert——但此时已经消耗了大量 gas。正确使用 `canFail` 需要调用者对每一步操作的必要性有清晰的判断。

对比 AttackContract 的设计：AttackContract 的 `RAW_CALL`（0x09）使用硬性的 `require(ok)` ——任何调用失败都立即 revert 整个交易。但 AttackContract 也有 `CALL_WITH_CHECK`（0x0b）提供条件验证——不是"允许失败"，而是"验证返回值是否满足特定条件"。两种设计反映了不同的错误处理哲学：Lotus Router 的 `canFail` 是"操作级容错"（跳过失败的操作），AttackContract 的 `CALL_WITH_CHECK` 是"条件级验证"（检查结果是否在预期范围内）。

---

## 8. 安全考量

### 8.1 缺失的安全层

Lotus Router 是一个纯粹的执行层组件，**故意不包含任何安全机制**。没有 `onlyOwner` 访问控制、没有反重放保护、没有利润保证检查、没有矿工贿赂机制。这与 AttackContract 的设计形成了鲜明对比——后者在 `approve()` 包装器中内置了 5 层安全机制（反重放、利润保证、WETH 自动转换、coinbase 贿赂、硬编码收款地址）。

这个设计选择是有意为之的。Lotus Router 将自己定位为"可组合的底层组件"，安全逻辑应该由上层系统（链下 Bot 代码或外层合约）负责。在 MEV 实践中，典型的部署方式是将 Lotus Router 包裹在一个带有安全检查的外层合约中，或者由链下系统在构造 calldata 前完成所有模拟和验证。

### 8.2 无重入保护

README 中明确指出合约没有重入锁。解释的理由是路由合约在正常使用中不持有资金——资金在调用时转入，调用结束后全部转出。但这个假设在某些边缘场景中可能不成立，例如 `DynCall` 调用的目标合约可能在回调中重新进入 Lotus Router。

### 8.3 ERC6909 的零槽清理不一致

代码注释中承认了一个已知问题："在 Lotus Router 内并没有完全遵循 0x60-0x80 的清理规则，比如在 ERC6909 内的 transferFrom 就没有实现 0x60-0x80 的清理规则。" 实际查看代码确认，`ERC6909.transferFrom` 将数据写入空闲内存指针位置（`fmp`），避开了 scratch space 和 zero slot，所以不需要清理。但 `ERC6909.transfer` 写入 0x00-0x64 区域后只恢复了 `0x40`（FMP）和 `0x60`（zero slot），这与文档注释一致。这个不一致性不是 bug，但可能在未来修改代码时引入问题。

---

## 9. 与 AttackContract 的系统对比

> **注**：经字节码同一性验证，Base 链 `0x42Ecd332`（早期称 "MevBot"）与几乎所有主要 EVM 链上的 `0xA98E339f`（早期称 "AttackEngine"）为同一份源码的参数化部署（仅 WETH 地址和 IPFS 元数据不同），统一称为 AttackContract。本项目从中选取了 13 条链的攻击交易进行逆向分析。以下对比基于逆向重建的完整 AttackContract.sol（800+ 行，141/141 replay PASS）。

| 维度 | Lotus Router | AttackContract |
|------|-------------|----------------|
| **定位** | 开源教学/通用组件 | 跨链生产攻击引擎（部署于几乎所有主要 EVM 链，逆向分析选取 13 条链） |
| **源码** | 开源 Solidity | 逆向重建（800+ 行，141/141 replay PASS） |
| **编译器** | Solidity 0.8.28, via_ir | Solidity 0.8.15, 非 via_ir |
| **操作码数** | 12（0x00-0x0b） | 12（0x00-0x0b） |
| **金额管理** | 无内部状态 | `amount` 寄存器 + 4 个读写操作码（0x05-0x08） |
| **编码方案** | BBC 长度前缀（动态位移） | 固定宽度（20B 地址 / 32B uint） |
| **回调模型** | 递归（calldata 嵌套传递） | 线性（闪贷回调执行指令，swap 回调仅转账） |
| **回调分派** | `findPtr()` 按 selector 跳转 | 按参数数据类型分派（`_handleUintCb` / `_handleIntCb`） |
| **Selector 数** | 4（takeAction + 3 回调） | 45（42 函数 + 3 额外 dispatch 入口；Polygon +1） |
| **DEX 覆盖** | Uniswap V2/V3 | UniV2/V3, Balancer, iZiSwap, PancakeV3, Algebra, Solidly 等 18+ |
| **借贷支持** | 无 | Moonwell, Morpho Blue, AAVE V2/V3, Euler V2 |
| **利润提取** | 无 | 完整（PROFIT_RECEIVER + builder tip） |
| **运维** | 无 | 0x725f071c ops 函数（批量 gas 分发 + 子 EOA 管理） |
| **容错机制** | `canFail`（操作级跳过） | `require(ok)`（硬失败）+ `CALL_WITH_CHECK`（条件验证） |
| **安全层** | 无 | 反重放 + 利润保证 + coinbase 贿赂 + 硬编码收款 |
| **WETH 地址** | calldata 传入（跨链友好） | immutable（每链不同，构造函数传入） |
| **重入保护** | 无 | 无（利润检查间接保护） |
| **Storage** | 无 | 无（仅 immutable WETH） |
| **许可证** | AGPL-3.0 | 无（逆向重建） |
| **已知获利** | N/A | ~$4.63M（14 个部署合计） |

---

## 10. 测试覆盖

项目包含 2 个测试文件、8 个 mock 合约，gas snapshot 显示共 86 个测试用例全部通过。测试覆盖了以下维度：

`BBCDecoder.t.sol` 测试了所有 11 种解码函数的确定性用例和模糊测试（fuzz test），确保编码和解码的往返一致性。模糊测试验证了在随机参数下编码→解码→断言等价的正确性。

`LotusRouter.t.sol` 测试了所有 12 种 action 的单步执行、多步链式执行、递归回调（V2/V3）、canFail 容错、以及各种失败场景（throws）。Mock 合约模拟了 Uniswap V2 pair、V3 pool、各种 ERC 标准代币和 WETH，提供了控制可控的测试环境。

一个值得注意的测试是 `testWETHSendIsCheaperThanDeposit`——它验证了通过 fallback（无 calldata）发送 ETH 比调用 `deposit()` 函数更省 gas 的优化假设。

---

## 11. 对教程的价值评估

Lotus Router 对《MEV Bot 开发 101》系列教程的价值主要体现在三个层面。

第一，它是一个**完整的、可编译的、有测试的** MEV 路由合约参考实现。与 AttackContract 的逆向重建代码相比，Lotus Router 的每个函数都有详细的注释、清晰的命名和完整的测试。这使得它成为"正向阅读"的理想教学材料。

第二，它的 BBC 编码方案与 AttackContract 的固定宽度编码形成了**完美的对比组**。两种方案解决同一个问题（压缩 calldata 以节省 gas），但设计取舍完全相反——BBC 牺牲解码复杂度换取极致压缩，AttackContract 牺牲 calldata 体积换取极致解码简洁。README 中的 288 字节 vs 66 字节的量化对比为教程第 5 篇提供了现成的教学素材。

第三，它的**递归回调模型**与 AttackContract 的**线性执行模型**代表了 MEV 路由合约设计空间的两个极端。递归模型更灵活但更复杂，线性模型更可预测但需要闪贷提供足够初始资金。这个对比是教程第 7 篇（指令引擎深度解析）的核心教学内容。

同时需要指出 Lotus Router 的局限性：缺少 `amount` 寄存器意味着它无法处理运行时的金额查询和动态调整，这在预言机套利等 AttackContract 的典型场景中是必需的。教程第 10 篇（构建你自己的 MEV Router）的改造方向之一正是为 Lotus Router 添加这个能力。
