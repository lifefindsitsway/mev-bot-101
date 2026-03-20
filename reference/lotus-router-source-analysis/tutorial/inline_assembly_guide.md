# Solidity 内联汇编工具书

> 本文是 Solidity 内联汇编（Yul）的实用工具书，面向需要阅读和理解 Lotus Router 源码的开发者。每个知识点明确标记 `[通用]`（可迁移到任何 assembly 代码）或 `[LR 专项]`（专为 Lotus Router 源码分析）。

---

## 第一部分：Yul 语言基础 `[通用]`

> **本节解决什么问题**：Yul 是 Solidity 内联汇编的语言，语法简洁但有独特的规则。本节覆盖变量、控制流、函数等基础，为后续阅读 LR 源码扫除语法障碍。

### assembly 块声明

```solidity
// 基本形式
assembly {
    // Yul 代码
}

// 带 memory-safe 注解
assembly ("memory-safe") {
    // Yul 代码
}
```

**`"memory-safe"` 的含义**：告诉 Solidity 优化器，此 assembly 块不会破坏 Solidity 的 memory 管理不变式（free memory pointer 和 zero slot）。优化器可以更激进地优化周围的 Solidity 代码。

**`[LR 专项]` BBCDecoder 为什么不标注 `"memory-safe"`？**

BBCDecoder（`BBCDecoder.sol`）的所有解码函数都使用不带注解的 `assembly { }`。原因是：BBCDecoder 只操作 calldata 和栈变量（通过 `calldataload` 和 `shr`），**完全不接触 memory**——既不读 `mload`，也不写 `mstore`。标注 `"memory-safe"` 虽然不会出错，但无实际意义，因为优化器已经知道这些函数不影响 memory。

对比之下，协议类型库（`ERC20.sol`、`UniV2Pair.sol`、`UniV3Pool.sol`、`Dyn.sol` 等）通过 `mstore`/`mload` 操控 memory，标注 `"memory-safe"` 是向编译器承诺不破坏 fmp 不变式。

注意 `BBCEncoder.sol` 中 `encodeDepositWETH`（`BBCEncoder.sol:542`）和 `encodeWithdrawWETH`（`BBCEncoder.sol:582`）两个函数同样未标注 `"memory-safe"`——它们虽然操作 memory，但不涉及 fmp 维护。

### 变量

```yul
let x := 42                // 声明 + 初始化
let y := calldataload(0)   // 声明 + 初始化为操作码返回值
x := add(x, 1)             // 赋值（无 let）
```

所有变量都是 256-bit 无符号整数。没有类型系统——`address`、`bool`、`uint256` 在 Yul 层面都是同一种值。

### 控制流

```yul
// if（无 else）
if condition {
    // ...
}

// switch/case/default
switch value
case 0 { /* ... */ }
case 1 { /* ... */ }
default { /* ... */ }

// for 循环
for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
    // body
}
```

注意：Yul 的 `if` **没有 `else`**。需要分支逻辑时用 `switch/case`。

### 函数

```yul
function f(a, b) -> result {
    result := add(a, b)
}

let sum := f(3, 4)   // 调用
```

Yul 函数支持多返回值：`function g(x) -> a, b { ... }`。

### 与 Solidity 交互

```solidity
uint256 myVar = 42;
assembly {
    let x := myVar            // 直接读取 Solidity 局部变量
    myVar := add(myVar, 1)    // 直接修改 Solidity 局部变量
}
```

Storage 变量需要 `.slot` 和 `.offset`：

```solidity
uint256 storageVar;
assembly {
    let s := storageVar.slot      // 获取存储槽号
    let val := sload(s)           // 读取存储
    sstore(s, add(val, 1))        // 写入存储
}
```

### 字面量

```yul
let a := 0x1234     // 十六进制
let b := 42         // 十进制
let c := true       // 布尔值 = 1
```

### 本节要点

1. `assembly ("memory-safe")` 是向优化器承诺不破坏 Solidity memory 不变式
2. BBCDecoder 不标注是因为它完全不接触 memory，只操作 calldata 和栈
3. Yul 变量都是 256-bit，无类型系统
4. Yul 的 `if` 没有 `else`，分支用 `switch/case`
5. Solidity 局部变量可直接在 assembly 中读写

---

## 第二部分：Memory 操作 `[通用]` + `[LR 专项]`

> **本节解决什么问题**：Memory 是 assembly 中最频繁操作的数据区域。理解 Solidity 的 memory 布局和两种写入策略，是读懂 LR 协议交互代码的关键。

### `[通用]` Memory 操作码

**mload(offset)** — 从 memory[offset] 读取 32 字节到栈：

```yul
let val := mload(0x40)   // 读取 free memory pointer
```

**mstore(offset, value)** — 将 32 字节 value 写入 memory[offset]：

```yul
mstore(0x00, 0xCAFEBABE)
// memory[0x00:0x1f] = 0x00000000000000000000000000000000000000000000000000000000CAFEBABE
// 注意: mstore 总是写 32 字节，value 左填充到 32 字节
```

**关键：mstore 总是写 32 字节。** 即使你只想写 4 字节的 selector，`mstore(0x00, selector)` 也会覆盖 memory[0x00:0x1f] 的全部 32 字节。

**mstore8(offset, value)** — 将 value 的最低 1 字节写入 memory[offset]：

```yul
mstore8(0x00, 0xFF)
// memory[0x00] = 0xFF（只写 1 字节）
```

### `[通用]` Solidity Memory 布局

```
偏移范围         用途                              说明
──────────────   ──────────────────────────────    ──────────────────
0x00 - 0x1f      Scratch space (slot 0)           Keccak256 临时空间
0x20 - 0x3f      Scratch space (slot 1)           Keccak256 临时空间
0x40 - 0x5f      Free memory pointer (fmp)        指向下一个可用的 memory 位置
0x60 - 0x7f      Zero slot                        永远为零（0x00），用于动态 memory 数组的初始值
0x80+            可用空间                          fmp 指向这里
```

**Free memory pointer (fmp)** 的工作方式：
- `mload(0x40)` 读取当前 fmp 值（如 0x80）
- 在该位置写入数据
- 更新 fmp：`mstore(0x40, add(fmp, allocSize))`

### `[LR 专项]` 两种 Memory 策略

Lotus Router 在协议交互库中使用两种不同的 memory 写入策略：

#### 策略 A — Scratch Space（`ERC20.sol:50-64`）

```solidity
// ERC20.sol:50-64 — transfer
assembly ("memory-safe") {
    mstore(0x00, transferSelector)       // 写入 0x00:0x1f
    mstore(0x04, receiver)               // 写入 0x04:0x23
    mstore(0x24, amount)                 // 写入 0x24:0x43 ★ 覆盖到 0x40-0x43
    success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)
    // ... 返回值校验 ...
    mstore(0x24, 0x00)                   // ★ 恢复：0x24-0x43 清零
}
```

**优点**：直接写入 0x00，省去了 fmp 分配的开销。

**风险**：`mstore(0x24, amount)` 写 32 字节到 0x24-0x43，覆盖了 memory[0x40:0x43]——即 free memory pointer 的**高 4 字节**。如果 `amount` 的高位字节非零，fmp 就被破坏了。

**恢复**：`mstore(0x24, 0x00)` 将 0x24-0x43 清零，把 fmp 的高 4 字节恢复为零。由于 fmp 通常是一个较小的值（如 0x80），高 4 字节本来就是零，所以清零就是正确的恢复。

#### transferFrom 的更复杂恢复（`ERC20.sol:113-133`）

```solidity
// ERC20.sol:113-133 — transferFrom
assembly ("memory-safe") {
    let fmp := mload(0x40)               // ★ 保存 fmp
    mstore(0x00, transferFromSelector)   // 0x00:0x1f
    mstore(0x04, sender)                 // 0x04:0x23
    mstore(0x24, receiver)               // 0x24:0x43
    mstore(0x44, amount)                 // 0x44:0x63 ★ 覆盖 fmp 全部 + zero slot 高 4B
    success := call(gas(), token, 0x00, 0x00, 0x64, 0x00, 0x20)
    // ... 返回值校验 ...
    mstore(0x40, fmp)                    // ★ 恢复 fmp
    mstore(0x60, 0x00)                   // ★ 恢复 zero slot
}
```

**为什么恢复更复杂？** `mstore(0x44, amount)` 写 32 字节到 0x44-0x63：
- 覆盖了 memory[0x44:0x5f] — fmp 的低 28 字节（memory[0x40:0x5f] 中的 0x44-0x5f 部分）
- 覆盖了 memory[0x60:0x63] — zero slot 的高 4 字节

加上前面 `mstore(0x24, receiver)` 覆盖了 memory[0x40:0x43]（fmp 的高 4 字节），整个 fmp slot（0x40-0x5f）和 zero slot 的高 4 字节都被破坏了。

所以需要两步恢复：
1. `mstore(0x40, fmp)` — 用之前保存的值恢复完整的 fmp
2. `mstore(0x60, 0x00)` — zero slot 恢复为零

#### 策略 B — fmp 分配（`UniV2Pair.sol:51-73`）

```solidity
// UniV2Pair.sol:51-73
assembly ("memory-safe") {
    let fmp := mload(0x40)               // 读 fmp
    // ... 所有 mstore 都基于 fmp 偏移 ...
    mstore(add(fmp, 0x00), swapSelector)
    mstore(add(fmp, 0x04), amount0Out)
    // ...
}
```

**优点**：安全——写入 fmp 以后的位置，不影响 scratch space、fmp 和 zero slot。

**代价**：每次 `add(fmp, offset)` 需要额外的 `ADD` 操作（3 gas），且可能触发 memory 扩展成本。

**LR 的选择标准**（取决于 calldata 总长度和是否有动态数据）：
- calldata ≤ 0x44（68 字节，2 个参数）→ scratch space + 部分恢复（ERC20.transfer：只需清零 fmp 高 4 字节）
- calldata = 0x64（100 字节，3 个参数）→ scratch space + 完整恢复 fmp 和 zero slot（ERC20.transferFrom、ERC6909.transfer、ERC721.transferFrom）
- 有动态数据（bytes 参数）→ fmp 分配（UniV2Pair.swap、UniV3Pool.swap/flash、Dyn.dynCall）

> 注意：`ERC721.transferFrom`（`ERC721.sol:52-67`）同样使用 scratch space 写入 0x64 字节，恢复了 fmp 但**未恢复 zero slot**（没有 `mstore(0x60, 0x00)`）。这与 ERC20.transferFrom 和 ERC6909.transfer 的行为不一致。可能的原因是 ERC721 的 `call` 使用 `retLength=0x00`（不读取返回值），后续没有 `mload(0x00)` 操作，作者判断 zero slot 的轻微污染不会影响后续执行。但严格来说，这与 `"memory-safe"` 标注的承诺存在张力。

### 本节要点

1. `mstore` 总是写 32 字节——在 scratch space 写入时必须考虑对 fmp 和 zero slot 的覆盖
2. Scratch space 策略省 memory，但调用后需恢复被覆盖的 fmp/zero slot
3. fmp 分配策略安全但有额外的 `ADD` 成本和可能的 memory 扩展
4. ERC20.transfer 只覆盖 fmp 高 4 字节，用 `mstore(0x24, 0x00)` 恢复；transferFrom 覆盖整个 fmp 和部分 zero slot，需要两步恢复
5. LR 根据参数数量选择策略——少参数用 scratch space，有动态数据用 fmp

---

## 第三部分：Calldata 操作 `[通用]` + `[LR 专项]`

> **本节解决什么问题**：Calldata 操作码是 BBC 解码的基础工具。本节简要回顾操作码语义（完整示例详见 `calldata_deep_dive.md` 第四部分），然后深入 LR 源码的 BBC 解码实现。

### `[通用]` Calldata 操作码速览

| 操作码 | 栈效果 | 语义 | Gas |
|--------|--------|------|-----|
| `calldataload(offset)` | [offset] → [value] | 从 calldata 读 32 字节到栈，不足右侧零填充 | 3 |
| `calldatacopy(dst, offset, size)` | [dst, offset, size] → [] | calldata → memory 复制 | 3 + 3×⌈size/32⌉ |
| `calldatasize()` | [] → [size] | 返回 calldata 总字节数 | 2 |

在 assembly 中获取 `msg.sig`：

```yul
let selector := shr(224, calldataload(0))
// calldataload(0) 读取 calldata 前 32 字节
// shr(224) 提取高 4 字节 = function selector
```

### `[LR 专项]` BBC 解码完整 Walkthrough

以 `BBCDecoder.decodeSwapUniV2`（`BBCDecoder.sol:71-113`）为案例，逐行解释完整的 BBC 解码过程。

#### 函数签名

```solidity
function decodeSwapUniV2(Ptr ptr) internal pure returns (
    Ptr nextPtr, bool canFail, UniV2Pair pair,
    uint256 amount0Out, uint256 amount1Out,
    address to, BytesCalldata data
)
```

输入一个 `Ptr`（calldata 偏移量），输出更新后的指针和所有解码字段。

#### 初始化

```solidity
// BBCDecoder.sol:71-73
assembly {
    let nextByteLen, nextBitShift
    nextPtr := ptr
```

声明两个局部变量用于三步解码模式，将 nextPtr 初始化为输入指针。

#### 字段 1：canFail（固定 1 字节）

```solidity
// BBCDecoder.sol:75-77
canFail := shr(u8Shr, calldataload(nextPtr))    // 读 1 字节
nextPtr := add(nextPtr, 0x01)                    // 指针推进 1
```

`u8Shr = 0xf8 = 248`。`shr(248, calldataload(ptr))` 提取 calldataload 结果的最高 1 字节。

#### 字段 2：pair（可变长度，三步模式）

```solidity
// BBCDecoder.sol:78-84
// 步骤 1: 读 byteLen
nextByteLen := shr(u8Shr, calldataload(nextPtr))    // 例: 20
// 步骤 2: 计算 bitShift
nextBitShift := sub(0x0100, mul(0x08, nextByteLen))  // 256 - 160 = 96
nextPtr := add(nextPtr, 0x01)                        // 跳过 byteLen

// 步骤 3: 提取值
pair := shr(nextBitShift, calldataload(nextPtr))     // 右移 96 位

nextPtr := add(nextPtr, nextByteLen)                  // 跳过 20 字节值
```

**指针推进的精确时序**：先读 byteLen，然后 `add(nextPtr, 0x01)` 跳过 byteLen 字节，此时 nextPtr 指向值的起始。`calldataload(nextPtr)` 从值起始读 32 字节，`shr` 提取高 N 字节。最后 `add(nextPtr, nextByteLen)` 跳过值本身。

#### 字段 3-5：amount0Out、amount1Out、to

结构与字段 2 完全相同——每个都是三步模式。代码模式完全复制（`BBCDecoder.sol:85-103`），只是赋值的目标变量不同。

#### 字段 6：data（动态数据，BytesCalldata）

```solidity
// BBCDecoder.sol:106-112
nextByteLen := shr(u32Shr, calldataload(nextPtr))    // 读 4 字节 uint32 长度
data := nextPtr                                       // ★ BytesCalldata = 当前偏移量
nextPtr := add(nextPtr, 0x04)                         // 跳过 uint32 length
nextPtr := add(nextPtr, nextByteLen)                   // 跳过 data body
```

`u32Shr = 0xe0 = 224`。`shr(224, calldataload(ptr))` 提取高 4 字节。

`data := nextPtr` 是关键——`data` 被赋值为当前 calldata 偏移量（指向 uint32 length 的起始位置）。这就是 `BytesCalldata` UDT 的语义：一个指向 calldata 中"length + data"结构的偏移量。

**零 memory 操作**。整个解码过程没有任何 `mstore` 或 `mload`——所有操作都在栈和 calldata 上完成。

#### signextend 处理 int256（`BBCDecoder.sol:177-178`）

在 `decodeSwapUniV3` 中，`amountSpecified` 是 `int256` 类型，解码后需要符号扩展：

```solidity
// BBCDecoder.sol:177-178
amountSpecified := shr(nextBitShift, calldataload(nextPtr))
amountSpecified := signextend(sub(nextByteLen, 0x01), amountSpecified)
```

`sub(nextByteLen, 0x01)` 计算 `signextend` 的 `b` 参数。如果 `nextByteLen = 8`，则 `b = 7`，表示将第 7 字节（从 0 开始）的最高位作为符号位扩展到所有更高字节。完整示例详见 `calldata_deep_dive.md` 第四部分（SIGNEXTEND）。

### 本节要点

1. BBC 解码在纯 calldata + 栈上完成，零 memory 操作
2. 三步模式（byteLen → bitShift → shr）在 BBCDecoder 中为每个可变长度字段重复使用
3. 动态数据字段只记录 calldata 偏移量（BytesCalldata），不复制数据
4. `int256` 字段在 shr 提取后需要 `signextend` 恢复符号位
5. 指针推进严格按 byteLen 字节数跳过，确保后续字段的正确定位

---

## 第四部分：算术与位操作 `[通用]` + `[LR 专项]`

> **本节解决什么问题**：位操作是 assembly 中最常用的工具，BBC 编解码和返回值校验都依赖它。本节覆盖算术、比较和位运算操作码，附带 LR 源码中的专项模式。

### `[通用]` 算术操作码

| 操作码 | 语义 | Gas |
|--------|------|-----|
| `add(a, b)` | a + b（模 2^256） | 3 |
| `sub(a, b)` | a - b（模 2^256） | 3 |
| `mul(a, b)` | a × b（模 2^256） | 5 |
| `div(a, b)` | a ÷ b（整数除法，b=0 时返回 0） | 5 |
| `mod(a, b)` | a % b（b=0 时返回 0） | 5 |

### `[通用]` 比较操作码

| 操作码 | 语义 | Gas |
|--------|------|-----|
| `lt(a, b)` | a < b ? 1 : 0（无符号） | 3 |
| `gt(a, b)` | a > b ? 1 : 0（无符号） | 3 |
| `eq(a, b)` | a == b ? 1 : 0 | 3 |
| `iszero(a)` | a == 0 ? 1 : 0 | 3 |

### `[通用]` 位运算操作码

| 操作码 | 语义 | Gas |
|--------|------|-----|
| `and(a, b)` | 按位与 | 3 |
| `or(a, b)` | 按位或 | 3 |
| `xor(a, b)` | 按位异或 | 3 |
| `not(a)` | 按位取反 | 3 |
| `shr(shift, value)` | 逻辑右移 shift 位 | 3 |
| `shl(shift, value)` | 逻辑左移 shift 位 | 3 |
| `sar(shift, value)` | 算术右移 shift 位（保留符号位） | 3 |
| `signextend(b, x)` | 将第 b 字节的最高位扩展到所有高位 | 5 |
| `byte(n, x)` | 提取 x 的第 n 字节（从高位 0 开始） | 3 |

**byte(n, x) 示例**：

```
x = 0xCAFEBABE DEADBEEF 00000000 00000000 00000000 00000000 00000000 00000000

byte(0, x) = 0xCA    ← 最高字节
byte(1, x) = 0xFE
byte(4, x) = 0xDE
byte(31, x) = 0x00   ← 最低字节
```

### `[LR 专项]` BBC 位移公式

BBC 编解码的核心位移公式：

```
bitShift = sub(0x0100, mul(0x08, byteLen))
         = 256 - 8 × byteLen
```

**解码（shr）**：`shr(bitShift, calldataload(ptr))` — 右移到低位

```
byteLen=20 (address):  bitShift = 256 - 160 = 96   → shr(96, ...)
byteLen=8  (1 ether):  bitShift = 256 - 64  = 192  → shr(192, ...)
byteLen=1  (小整数):   bitShift = 256 - 8   = 248  → shr(248, ...)
byteLen=32 (满值):     bitShift = 256 - 256 = 0    → shr(0, ...) = 原值
```

**编码（shl）**（`BBCEncoder.sol:69`）：`shl(bitShift, value)` — 左移到高位

```solidity
mstore(ptr, shl(sub(0x0100, mul(0x08, pairByteLen)), pair))
```

编码和解码是对称操作：`shl` 将值移到高位写入 memory/calldata，`shr` 将值移到低位供使用。

### `[LR 专项]` ERC20 返回值校验逻辑

ERC20 标准的一个臭名昭著的问题：不同代币的 `transfer`/`transferFrom` 返回值行为不一致。

```solidity
// ERC20.sol:59
let successERC20 := or(iszero(returndatasize()), eq(0x01, mload(0x00)))
```

**逻辑拆解**：

```
successERC20 = or(
    iszero(returndatasize()),     // 条件 A: 没有返回数据（如 USDT）
    eq(0x01, mload(0x00))         // 条件 B: 返回了 true (0x01)
)
```

| 代币行为 | returndatasize | mload(0x00) | 条件 A | 条件 B | 结果 |
|----------|---------------|-------------|--------|--------|------|
| 标准 ERC20（返回 true） | 32 | 0x01 | 0 | 1 | **1（成功）** |
| USDT（无返回值） | 0 | — | 1 | — | **1（成功）** |
| 失败（返回 false） | 32 | 0x00 | 0 | 0 | **0（失败）** |

完整的成功判定还需要 `call` 本身返回成功：

```solidity
// ERC20.sol:61
success := and(success, successERC20)
// success = call 没 revert AND (无返回值 OR 返回 true)
```

### 本节要点

1. BBC 位移公式 `256 - 8 × byteLen` 是编解码的核心——`shr` 解码（右移到低位），`shl` 编码（左移到高位）
2. `or(iszero(returndatasize()), eq(0x01, mload(0x00)))` 同时兼容标准 ERC20 和 USDT 的非标返回值
3. `byte(n, x)` 从高位第 n 字节提取，与 `shr(248-8n, x) & 0xFF` 等效
4. 位运算操作码统一 3 gas，`signextend` 是 5 gas

---

## 第五部分：外部调用与返回值 `[通用]` + `[LR 专项]`

> **本节解决什么问题**：外部调用是合约间交互的核心。本节覆盖 call/staticcall/delegatecall 的用法、returndata 缓冲区机制，以及 LR 中的四种调用模式。

### `[通用]` 调用操作码

```
call(gas, addr, value, argsOffset, argsLength, retOffset, retLength) → success
staticcall(gas, addr, argsOffset, argsLength, retOffset, retLength) → success
delegatecall(gas, addr, argsOffset, argsLength, retOffset, retLength) → success
```

| 操作码 | 参数数 | 特点 |
|--------|--------|------|
| `call` | 7 | 完整调用，可发送 ETH |
| `staticcall` | 6（无 value） | 只读调用，不能修改状态 |
| `delegatecall` | 6（无 value） | 在调用者上下文执行 |

详细参数说明见 `calldata_deep_dive.md` 第六部分。

### `[通用]` Returndata 缓冲区（EIP-211）

每次外部调用后，EVM 将返回数据存入一个独立的 **returndata 缓冲区**——它不是 memory 的一部分，而是一个由 EVM 维护的临时区域。

**关键行为**：
- 每次 `call`/`staticcall`/`delegatecall` 后，returndata 缓冲区被**覆盖**为本次调用的返回数据
- 即使 `call` 的 `retLength = 0`，returndata 仍然可用
- 访问方式：`returndatasize()` 返回长度，`returndatacopy(dst, offset, size)` 复制到 memory

**call 的 retOffset/retLength 参数**：在 call 返回后，EVM 自动将 returndata 的前 `retLength` 字节写入 `memory[retOffset : retOffset + retLength]`。这是一种快捷方式——等效于 `call` 后执行 `returndatacopy(retOffset, 0, retLength)`。

**ERC20.sol 的利用**：

```solidity
// ERC20.sol:57
success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)
//                                               ^^^^  ^^^^
//                                               retOffset=0x00  retLength=0x20
```

call 返回后，如果 token 返回了数据，前 32 字节被写入 memory[0x00:0x1f]。随后 `mload(0x00)` 读取这个值——如果是 `true`（0x01），表示 transfer 成功。

### `[通用]` 其他相关操作码

| 操作码 | 语义 | Gas |
|--------|------|-----|
| `gas()` | 返回当前剩余 gas | 2 |
| `stop()` | 成功终止执行，不返回数据 | 0 |
| `return(offset, size)` | 成功终止，返回 memory[offset:offset+size] | 0 |
| `revert(offset, size)` | 回滚终止，返回 memory[offset:offset+size] | 0 |
| `returndatasize()` | 返回最近一次外部调用的返回数据大小 | 2 |
| `returndatacopy(dst, offset, size)` | 将返回数据复制到 memory | 3 + 3×⌈size/32⌉ |

### `[LR 专项]` 四种调用模式

#### 模式 A — 带 bytes 参数的协议调用

```solidity
// UniV2Pair.sol:51-73, UniV3Pool.sol:57-81, UniV3Pool.sol:125-147
let fmp := mload(0x40)
// ... 在 memory 中构造 ABI 编码 ...
calldatacopy(add(fmp, 0xa4), data, dataLen)    // BytesCalldata → memory
success := call(gas(), pair, 0x00, fmp, add(dataLen, 0xc4), 0x00, 0x00)
```

特征：fmp 分配 + calldatacopy + 不读取返回值。这是最复杂的模式。

#### 模式 B — Scratch space + 非标 ERC-20 返回值校验

```solidity
// ERC20.sol:50-64 (transfer), ERC20.sol:113-133 (transferFrom)
mstore(0x00, transferSelector)
mstore(0x04, receiver)
mstore(0x24, amount)
success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)  // retLength=0x20
let successERC20 := or(iszero(returndatasize()), eq(0x01, mload(0x00)))
success := and(success, successERC20)
mstore(0x24, 0x00)  // 恢复
```

**为什么需要 `or(iszero(returndatasize()), ...)`？** USDT 等非标 ERC20 代币的 `transfer` 不返回任何数据。如果只检查 `eq(0x01, mload(0x00))`，USDT 的成功转账会被误判为失败（因为 `mload(0x00)` 读到的是 call 之前残留的 selector 数据，不是返回值）。

#### 模式 C — 无 calldata 纯 ETH 调用

```solidity
// WETH.sol:35-37 — deposit
success := call(gas(), weth, value, 0x00, 0x00, 0x00, 0x00)
//                           ^^^^^  ^^^^  ^^^^
//                           ETH    argsOffset=0  argsLength=0
```

WETH 合约的 `fallback()` 在 `calldatasize` 为零时短路 selector dispatcher 直接执行 deposit 逻辑（见 `WETH.sol:28-29` 注释）。利用这一点，LR 避免了发送 `deposit()` selector 的 4 字节 calldata gas。

#### 模式 D — Identity precompile memory 复制

```solidity
// BBCEncoder.sol:93, 159, 220, 650
pop(staticcall(gas(), 0x04, add(data, 0x20), dataByteLen, ptr, dataByteLen))
//                    ^^^^
//                    地址 0x04 = identity precompile
```

Identity precompile（地址 `0x04`）的功能极其简单：输入什么就返回什么。LR 利用它实现 **memory → memory 复制**——因为 EVM 在 Cancun 硬分叉（`MCOPY` 操作码）之前没有原生的 memory 复制指令。

```
staticcall(gas, 0x04, srcOffset, size, dstOffset, size)
= 将 memory[srcOffset : srcOffset+size] 复制到 memory[dstOffset : dstOffset+size]
```

用 `staticcall` 而非 `call` 是因为 identity precompile 不修改状态，`staticcall` 语义更精确。

### 本节要点

1. Returndata 缓冲区是独立于 memory 的临时区域，每次外部调用后被覆盖
2. `call` 的 `retOffset/retLength` 自动将 returndata 写入 memory，等效于 `returndatacopy`
3. 模式 B（ERC20 校验）用 `or(iszero(returndatasize()), eq(0x01, mload(0x00)))` 兼容 USDT 等非标代币
4. 模式 C（纯 ETH 调用）利用 WETH 的 `receive()` 省去 selector calldata
5. 模式 D 用 identity precompile（0x04）实现 memory → memory 复制（Cancun 前的 memcpy 变通方案）

---

## 第六部分：控制流 `[通用]` + `[LR 专项]`

> **本节解决什么问题**：控制流操作码控制程序的执行路径。本节覆盖 Yul 中的条件/循环/终止语义，以及 LR 中 assembly 控制流的使用模式。

### `[通用]` if 语句

```yul
if condition {
    // condition 非零时执行
    // 注意: 没有 else 分支
}
```

**Yul 的"真"**：任何非零值都是 true。只有 0 是 false。

### `[通用]` switch/case/default

```yul
switch value
case 0 {
    // value == 0
}
case 1 {
    // value == 1
}
default {
    // 其他
}
```

注意：`case` 值必须是字面量，不能是变量或表达式。

### `[通用]` for 循环

```yul
for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
    // body
}
```

等效 Solidity：`for (uint i = 0; i < 10; i++) { ... }`

### `[通用]` 终止操作码

| 操作码 | 效果 | 返回数据 | Gas 退回 |
|--------|------|----------|----------|
| `stop()` | 成功终止 | 无 | 剩余 gas |
| `return(offset, size)` | 成功终止 | memory[offset:offset+size] | 剩余 gas |
| `revert(offset, size)` | 回滚终止 | memory[offset:offset+size] | 剩余 gas |

**stop() vs return(0, 0)** 的区别：
- `stop()` — 不返回任何数据，`returndatasize() = 0`
- `return(0, 0)` — 返回长度为 0 的数据，`returndatasize() = 0`

在行为上两者等效（都成功终止、不返回数据），但 `stop()` 在字节码中只占 1 字节（操作码 `0x00`），而 `return(0, 0)` 需要 3 个操作码（`PUSH1 0x00, DUP1, RETURN`），共 4 字节。LR 选择 `stop()` 更紧凑。

### `[LR 专项]` Lotus Router 的控制流结构

LR 的执行循环在 **Solidity 层面**实现（`LotusRouter.sol:73-208`），assembly 只在叶子操作（解码、构造调用、终止）中使用。

```solidity
// LotusRouter.sol:73-79
while (success) {                          // Solidity while 循环
    (ptr, action) = ptr.nextAction();      // BBC 解码（内部用 assembly）

    if (action == Action.Halt) {
        assembly {
            stop()                         // ★ assembly 终止
        }
    } else if (action == Action.SwapUniV2) {
        // ... BBC 解码 + 外部调用（内部用 assembly）
    }
    // ...
}

revert Error.CallFailure();                // 循环退出 = 失败
```

**设计观察**：
- 循环和分派逻辑在 Solidity 层面——可读性和可维护性优先
- 性能关键路径（BBC 解码、ABI 构造、外部调用）在 assembly 层面
- `stop()` 是唯一的正常退出路径——成功执行到 `Action.Halt` 时直接终止
- `while` 循环退出意味着某次 `call` 返回 false 且 `canFail = false`——到达 `revert`

### 本节要点

1. Yul `if` 没有 `else`，分支用 `switch/case`
2. `stop()` 和 `return(0, 0)` 行为等效，但 `stop()` 字节码更紧凑
3. LR 的控制流分层：Solidity 做循环/分派，assembly 做解码/构造/调用/终止
4. `Action.Halt` → `stop()` 是唯一的正常退出路径，while 退出后执行 `revert`

---

## 第七部分：操作码速查表 `[通用]`

> **本节解决什么问题**：按功能分类列出 Lotus Router 中用到的所有 EVM 操作码，便于快速查阅。

| 分类 | 操作码 | 栈输入 | 栈输出 | Gas | 说明 |
|------|--------|--------|--------|-----|------|
| **算术** | `add(a, b)` | 2 | 1 | 3 | a + b (mod 2^256) |
| | `sub(a, b)` | 2 | 1 | 3 | a - b (mod 2^256) |
| | `mul(a, b)` | 2 | 1 | 5 | a × b (mod 2^256) |
| | `div(a, b)` | 2 | 1 | 5 | a ÷ b (b=0→0) |
| | `mod(a, b)` | 2 | 1 | 5 | a % b (b=0→0) |
| **比较** | `lt(a, b)` | 2 | 1 | 3 | a < b (无符号) |
| | `gt(a, b)` | 2 | 1 | 3 | a > b (无符号) |
| | `eq(a, b)` | 2 | 1 | 3 | a == b |
| | `iszero(a)` | 1 | 1 | 3 | a == 0 |
| **位运算** | `and(a, b)` | 2 | 1 | 3 | 按位与 |
| | `or(a, b)` | 2 | 1 | 3 | 按位或 |
| | `xor(a, b)` | 2 | 1 | 3 | 按位异或 |
| | `not(a)` | 1 | 1 | 3 | 按位取反 |
| | `shr(shift, val)` | 2 | 1 | 3 | 逻辑右移 |
| | `shl(shift, val)` | 2 | 1 | 3 | 逻辑左移 |
| | `sar(shift, val)` | 2 | 1 | 3 | 算术右移（保留符号） |
| | `signextend(b, x)` | 2 | 1 | 5 | 将第 b 字节的符号位扩展 |
| | `byte(n, x)` | 2 | 1 | 3 | 提取第 n 字节（从高位 0 开始） |
| **Memory** | `mload(offset)` | 1 | 1 | 3* | 读 32 字节 |
| | `mstore(offset, val)` | 2 | 0 | 3* | 写 32 字节 |
| | `mstore8(offset, val)` | 2 | 0 | 3* | 写 1 字节 |
| **Calldata** | `calldataload(offset)` | 1 | 1 | 3 | 读 32 字节（不足零填充） |
| | `calldatacopy(dst, offset, size)` | 3 | 0 | 3+3×⌈size/32⌉* | 复制到 memory |
| | `calldatasize()` | 0 | 1 | 2 | calldata 总字节数 |
| **外部调用** | `call(g,a,v,ao,al,ro,rl)` | 7 | 1 | 100+ | 带 ETH 的外部调用 |
| | `staticcall(g,a,ao,al,ro,rl)` | 6 | 1 | 100+ | 只读外部调用 |
| | `delegatecall(g,a,ao,al,ro,rl)` | 6 | 1 | 100+ | 委托调用 |
| **返回值** | `returndatasize()` | 0 | 1 | 2 | 返回数据大小 |
| | `returndatacopy(dst, offset, size)` | 3 | 0 | 3+3×⌈size/32⌉ | 复制返回数据 |
| **控制** | `stop()` | 0 | 0 | 0 | 成功终止 |
| | `return(offset, size)` | 2 | 0 | 0 | 成功终止+返回数据 |
| | `revert(offset, size)` | 2 | 0 | 0 | 回滚终止+返回数据 |
| **环境** | `gas()` | 0 | 1 | 2 | 当前剩余 gas |
| | `address()` | 0 | 1 | 2 | 当前合约地址 |
| | `caller()` | 0 | 1 | 2 | msg.sender |
| | `callvalue()` | 0 | 1 | 2 | msg.value |
| | `selfbalance()` | 0 | 1 | 5 | 当前合约 ETH 余额 |

> `*` 标注的操作码还可能产生 memory 扩展成本

### 本节要点

1. 位运算和比较操作统一 3 gas，signextend 是 5 gas
2. Memory 操作的基础 gas 是 3，但可能有扩展成本
3. 外部调用的 gas 成本复杂（warm/cold access + value transfer + new account），基础 100 gas（warm）
4. `stop()` 和 `return(0,0)` 都是 0 gas 终止操作码

---

## 第八部分：Lotus Router Assembly 全景走读 `[LR 专项]`

> **本节解决什么问题**：综合前七部分的所有知识，以 `ERC20.transferFrom`（`ERC20.sol:113-133`）为案例，逐行走读一个完整的 assembly block——从 fmp 保存到 memory 恢复。

### 源码

```solidity
// ERC20.sol:107-134 (完整函数), assembly 块: 113-133
function transferFrom(
    ERC20 token, address sender, address receiver, uint256 amount
) returns (bool success) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)                       // 行 114

        mstore(0x00, transferFromSelector)            // 行 116

        mstore(0x04, sender)                          // 行 118

        mstore(0x24, receiver)                        // 行 120

        mstore(0x44, amount)                          // 行 122

        success := call(gas(), token, 0x00,           // 行 124
                        0x00, 0x64, 0x00, 0x20)

        let successERC20 := or(                       // 行 126
            iszero(returndatasize()),
            eq(0x01, mload(0x00)))

        success := and(success, successERC20)         // 行 128

        mstore(0x40, fmp)                             // 行 130

        mstore(0x60, 0x00)                            // 行 132
    }
}
```

### 第 1 行：`let fmp := mload(0x40)` — fmp 保存

```
操作: 读取 memory[0x40:0x5f] → fmp
目的: 保存 free memory pointer 的当前值，用于后续恢复
```

为什么需要保存？因为后续的 `mstore(0x24, ...)` 和 `mstore(0x44, ...)` 会覆盖 memory[0x40:0x5f] 区域。

### 第 2 行：`mstore(0x00, transferFromSelector)` — selector 写入

```
transferFromSelector = 0x23b872dd00000000000000000000000000000000000000000000000000000000

操作: memory[0x00:0x1f] = 0x23b872dd00...00
效果: selector 在高 4 字节，低 28 字节为零
```

Memory 状态：

```
0x00: 23b872dd 00000000 00000000 00000000 00000000 00000000 00000000 00000000
      ^^^^^^^^ selector
```

### 第 3 行：`mstore(0x04, sender)` — 第一个参数

```
操作: memory[0x04:0x23] = sender（左填充到 32 字节）
覆盖: 0x04-0x1f 的内容（之前是 selector 写入的零字节）
```

Memory 状态：

```
0x00: 23b872dd 00000000 00000000 0000000000000000 00000000 <sender_high_bytes>
      ^^^^^^^^ selector                                     ← mstore(0x04) 从这里开始写
0x04:          00000000 00000000 00000000 00000000 <sender_low_20_bytes>......
```

### 第 4 行：`mstore(0x24, receiver)` — 第二个参数

```
操作: memory[0x24:0x43] = receiver（左填充到 32 字节）
覆盖: 0x40-0x43 ← fmp 的高 4 字节被覆盖!
```

### 第 5 行：`mstore(0x44, amount)` — 第三个参数

```
操作: memory[0x44:0x63] = amount（32 字节）
覆盖: 0x44-0x5f ← fmp 的低 28 字节被覆盖!
覆盖: 0x60-0x63 ← zero slot 的高 4 字节被覆盖!
```

至此，memory[0x00:0x63]（100 字节）的完整布局：

```
偏移     内容                                                      说明
──────   ──────────────────────────────────────────────────────    ──────────────
0x00     23b872dd                                                  selector (4B)
0x04     00..00 <sender 20B>                                       参数 1: from
0x24     00..00 <receiver 20B>                                     参数 2: to
0x44     <amount 32B>                                              参数 3: amount
```

被覆盖的区域：
- memory[0x40:0x43]（fmp 高 4 字节）← 由 receiver 的最低 4 字节覆盖
- memory[0x44:0x5f]（fmp 低 28 字节）← 由 amount 的高 28 字节覆盖
- memory[0x60:0x63]（zero slot 高 4 字节）← 由 amount 的低 4 字节覆盖

### 第 6 行：`call(gas(), token, 0x00, 0x00, 0x64, 0x00, 0x20)` — 外部调用

```
参数拆解:
  gas      = gas()     全部剩余 gas
  addr     = token     ERC20 合约地址
  value    = 0x00      不发送 ETH
  argsOffset = 0x00    从 memory[0x00] 开始
  argsLength = 0x64    100 字节 = 4(selector) + 32×3(参数)
  retOffset  = 0x00    返回值写入 memory[0x00]
  retLength  = 0x20    期望 32 字节返回值

效果:
  - 向 token 合约发送 transferFrom(sender, receiver, amount) 调用
  - 如果 token 返回数据，前 32 字节写入 memory[0x00:0x1f]
  - success = 1（成功）或 0（revert）
```

### 第 7 行：返回值校验

```solidity
let successERC20 := or(iszero(returndatasize()), eq(0x01, mload(0x00)))
```

```
执行流程:
1. returndatasize()     → 返回数据的字节数
2. iszero(...)          → 如果返回数据为空则为 1（USDT 场景）
3. mload(0x00)          → 读 memory[0x00:0x1f]（call 写入的返回值）
4. eq(0x01, ...)        → 返回值是否为 true (0x01)
5. or(step2, step4)     → 任一条件满足即为成功
```

### 第 8 行：合并判定

```solidity
success := and(success, successERC20)
```

最终 success = `call 没有 revert` AND (`无返回值` OR `返回 true`)。

### 第 9 行：`mstore(0x40, fmp)` — 恢复 fmp

```
操作: memory[0x40:0x5f] = fmp（之前保存的值）
效果: free memory pointer 恢复到调用前的状态
```

**为什么必要？** 如果不恢复，后续 Solidity 代码调用 `mload(0x40)` 读到的将是 `amount` 覆盖的垃圾值。`new bytes(...)`、`abi.encode(...)` 等 Solidity 操作依赖 fmp 分配 memory——fmp 损坏会导致 memory 布局混乱。

### 第 10 行：`mstore(0x60, 0x00)` — 恢复 zero slot

```
操作: memory[0x60:0x7f] = 0
效果: zero slot 恢复为全零
```

**为什么必要？** Solidity 使用 memory[0x60:0x7f]（zero slot）作为动态 memory 数组的初始长度值（0x00）。`mstore(0x44, amount)` 的 32 字节写入覆盖了 0x60-0x63 区域。如果 `amount` 的低 4 字节非零，zero slot 就被污染了。

### 不恢复 zero slot 会怎样？

假设 `amount = 1 ether = 0x0DE0B6B3A7640000`。

`mstore(0x44, 0x0DE0B6B3A7640000)` 将 32 字节写入 0x44-0x63：
- memory[0x60] = 0xA7
- memory[0x61] = 0x64
- memory[0x62] = 0x00
- memory[0x63] = 0x00

如果不恢复 zero slot，后续 Solidity 代码创建 `new bytes(0)` 时，编译器可能读取 memory[0x60] 作为初始填充值——得到非零的垃圾数据，导致行为异常。

### 执行时序总结

```
① mload(0x40) → 保存 fmp
② mstore(0x00-0x44) → 构造 ABI calldata（覆盖 fmp 和 zero slot）
③ call → 执行外部调用
④ 返回值校验 → 判断成功/失败
⑤ mstore(0x40, fmp) → 恢复 fmp
⑥ mstore(0x60, 0x00) → 恢复 zero slot
```

这个"保存 → 覆盖 → 使用 → 恢复"的模式在 Lotus Router 的 scratch space 策略中反复出现。核心约束是：**assembly 块必须维护 Solidity 的 memory 不变式**——这正是 `"memory-safe"` 注解的承诺。

### 本节要点

1. Scratch space 写入从 0x00 开始，100 字节（0x64）的 transferFrom calldata 覆盖 fmp 和 zero slot
2. `call` 的 retOffset=0x00 让返回值直接覆盖 scratch space，省去 `returndatacopy`
3. `or(iszero(returndatasize()), eq(0x01, mload(0x00)))` 是 ERC20 非标兼容的惯用模式
4. 恢复 fmp 和 zero slot 是强制要求——否则后续 Solidity memory 分配会失败
5. "保存 → 覆盖 → 使用 → 恢复"是 LR scratch space 策略的核心模式
