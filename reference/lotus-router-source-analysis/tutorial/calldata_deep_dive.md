# Calldata 与 ABI 编码完整工具书

> 本文是一份自包含的 EVM Calldata 工具书，覆盖从数据区域基础到 BBC 紧凑编码的完整知识链。所有十六进制示例均可手算验证，所有源码引用均锚定 Lotus Router 代码库。

---

## 第一部分：EVM 数据区域速览

> **本节解决什么问题**：EVM 有四个数据区域，各自有不同的生命周期、访问方式和 gas 成本。理解它们的定位差异，是后续深入 calldata 操作的前提。

（更详细的讲解详见博客《EVM 基础原理（二）：数据区域与合约执行》）

### 四大数据区域对比

| 维度 | 栈（Stack） | 内存（Memory） | 存储（Storage） | Calldata |
|------|-------------|----------------|-----------------|----------|
| 生命周期 | 当前 call frame（LIFO 访问） | 当前 call frame | 永久（跨交易） | 当前 call frame |
| 可写性 | 是（PUSH/POP/DUP/SWAP） | 是（MSTORE/MSTORE8） | 是（SSTORE） | **只读** |
| 寻址方式 | 隐式（栈顶操作） | 字节偏移（线性） | 256-bit 槽键 | 字节偏移（线性） |
| 大小限制 | 1024 个 256-bit 元素 | 理论无限（gas 约束） | 理论无限（gas 约束） | 由交易发起者提供 |
| 典型 gas 成本 | 2-3 gas/操作 | 3 gas + 扩展成本 | 2100-20000 gas | 4/16 gas 每字节 |
| 专用操作码 | PUSH/POP/DUP/SWAP | MLOAD/MSTORE/MSTORE8 | SLOAD/SSTORE | CALLDATALOAD/CALLDATACOPY/CALLDATASIZE |

### Calldata 作为独立数据区域的特殊性

Calldata 在四个数据区域中具有独特的地位：

**1. 只读且由交易发起者提供**

Calldata 是交易的 `input` 字段（外部交易）或 `CALL` 操作码的 `argsOffset/argsLength` 参数（内部调用）。一旦进入 call frame，合约代码无法修改它——EVM 没有提供任何写入 calldata 的操作码。

**2. 独立寻址空间 + 专用操作码**

Calldata 有自己的地址空间，从偏移 0 开始。三个专用操作码直接操作这个空间：
- `CALLDATALOAD(offset)` — 从 calldata 读取 32 字节到栈
- `CALLDATACOPY(destOffset, offset, size)` — 从 calldata 复制任意长度到 memory
- `CALLDATASIZE` — 返回 calldata 总字节数

这些操作码与 memory 操作码（MLOAD/MSTORE）完全独立——它们访问的是不同的地址空间。

**3. 每次外部调用创建新的 calldata 上下文**

当合约 A 通过 `CALL` 调用合约 B 时，B 看到的 `msg.data`（calldata）是 A 在 memory 中构造的调用数据，而不是 A 自己的 calldata。每个 call frame 拥有独立的 calldata——这正是 EVM 的 call frame 隔离机制。

**4. Gas 定价独立于 memory/storage**

Calldata 的 gas 成本遵循 EIP-2028（Istanbul 硬分叉）：

| 字节类型 | Gas 成本/字节 |
|----------|---------------|
| 零字节（0x00） | 4 gas |
| 非零字节 | 16 gas |

这个定价直接影响合约的调用成本——传入更多的零填充意味着更多的 gas 消耗。这也是 BBC 紧凑编码的核心动机：减少 calldata 中的零字节。

### 本节要点

1. EVM 有四个数据区域：栈、内存、存储、calldata，各自有独立的寻址空间和访问操作码
2. Calldata 是**只读**的，由调用者提供，合约不能修改
3. 每次外部调用（CALL/STATICCALL/DELEGATECALL）创建独立的 calldata 上下文
4. Calldata 的 gas 定价为零字节 4 gas、非零字节 16 gas（EIP-2028），这是 BBC 编码优化的经济学基础

---

## 第二部分：Function Selector 机制

> **本节解决什么问题**：Solidity 用 calldata 的前 4 字节（function selector）来决定执行哪个函数。理解 selector 的计算方式和 dispatch 机制，才能理解 Lotus Router 为何绕过它。

（更详细的讲解详见博客《EVM 基础原理（三）：ABI 编码与底层调用》）

### Selector 计算

Function selector 是函数签名的 Keccak-256 哈希的前 4 字节：

```
selector = keccak256("functionName(paramType1,paramType2,...)")[0:4]
```

用 Foundry 的 `cast sig` 命令可以直接计算：

```bash
$ cast sig "transfer(address,uint256)"
0xa9059cbb

$ cast sig "swap(uint256,uint256,address,bytes)"
0x022c0d9f

$ cast sig "takeAction()"
0x19ff8034
```

### 标准 Dispatch 流程

Solidity 编译器生成的 dispatch 逻辑（伪代码）：

```
1. 从 calldata[0:4] 读取 selector
2. if selector == 0xa9059cbb → 跳转到 transfer 函数
3. if selector == 0x23b872dd → 跳转到 transferFrom 函数
4. ...
5. if 没有匹配 → 执行 fallback() 或 revert
```

### Lotus Router 的 fallback() 入口设计

Lotus Router 完全绕过了 Solidity 的标准 ABI 编码方案。它利用 `fallback()` 函数作为**唯一的执行入口**（`LotusRouter.sol:68`）：

```solidity
// LotusRouter.sol:68
fallback() external payable {
    Ptr ptr = findPtr();
    // ...
}
```

`fallback()` 在以下条件下触发：
- 调用的 calldata 中的 selector 不匹配合约中任何已声明的函数
- 或合约没有 `receive()` 函数且调用携带 ETH value

Lotus Router 没有声明任何标准的 public/external 函数（除了 `receive()`），所以**所有带 calldata 的调用**都会进入 `fallback()`。

但 LR 并没有完全忽略 selector——它用 `findPtr()` 函数（`PayloadPointer.sol:34-48`）做自己的路由：

```solidity
// PayloadPointer.sol:34-48
function findPtr() pure returns (Ptr) {
    uint256 selector = uint256(uint32(msg.sig));

    if (selector == takeAction) {          // 0x19ff8034 → 直接调用
        return Ptr.wrap(0x04);
    } else if (selector == uniswapV2Call) { // 0x10d1e85c → V2 回调
        return Ptr.wrap(0xa4);
    } else if (selector == uniswapV3SwapCallback) { // 0xfa461e33
        return Ptr.wrap(0x84);
    } else if (selector == uniswapV3FlashCallback) { // 0xe9cbafb0
        return Ptr.wrap(0x84);
    } else {
        revert Error.UnexpectedEntryPoint();
    }
}
```

设计意图：
- `takeAction()` 是主入口——calldata 的有效负载从 selector 之后的第 4 字节开始（`Ptr.wrap(0x04)`）
- V2/V3 回调是被动入口——DEX 合约在 swap/flash 执行过程中回调 LR，有效负载的位置由 ABI 编码的 `bytes data` 参数决定
- 另有 `receive() external payable { }`（`LotusRouter.sol:217`）接收纯 ETH 转账，不执行任何逻辑

### 本节要点

1. Function selector = `keccak256(签名)` 的前 4 字节，用于路由调用到正确的函数
2. `fallback()` 在 selector 不匹配任何已声明函数时触发
3. Lotus Router 用 `fallback()` 作唯一执行入口，用自定义的 `findPtr()` 根据 selector 确定 BBC 有效负载在 calldata 中的起始位置
4. 直接调用（`takeAction`）和回调（V2/V3 callback）的有效负载起始位置不同，`findPtr()` 统一处理了这个差异

---

## 第三部分：ABI 编码规范完整详解

> **本节解决什么问题**：ABI 编码是 Solidity 合约间通信的标准协议。完整理解它的 head-tail 结构和填充规则，是后续理解 BBC 编码"省在哪里"的必要前提。

（更详细的讲解详见博客《Solidity 合约间调用（二）：底层调用与 calldata 详解》）

### 静态类型编码

静态类型（`uint256`、`address`、`bool`、`int256` 等）的编码规则简单：**始终填充为 32 字节**。

**左填充与右填充**：
- 无符号整数（`uint`）、`address`、`bool`：左填充 **`0x00`**（零扩展）
- 有符号整数（`int`）：左填充**符号位**——非负值填充 `0x00`，负值填充 `0xFF`（二进制补码的符号扩展）
- 固定字节类型（`bytes1` 到 `bytes32`）：**右填充** `0x00`（低位补零）

> 注意 `bytes1` ~ `bytes32` 与 `bytes` 的区别：前者是**静态类型**（固定大小字节数组），编译时大小已知，ABI 编码中直接右填充到 32 字节；后者是**动态类型**（动态大小字节数组），编译时大小未知，使用 offset → length → data 的 head-tail 结构编码。`string` 在 ABI 编码层面与 `bytes` 完全相同。

**为什么同为静态类型，填充方向不同？** 因为两类值的"有效方向"相反：

- **整数是数值**，有效位从低位向高位增长（右→左）。右对齐（左填充）使最低有效位始终在 256-bit 字的固定位置，EVM 算术操作码（`ADD`、`MUL`、`LT` 等）直接作用于右对齐的值，无需额外移位。类型扩展时自然一致——无符号整数高位零扩展，有符号整数高位符号扩展，值不变：

```
uint8(0xFF) → uint256 = 零扩展，值 255：
0x 00000000 00000000 00000000 00000000 00000000 00000000 00000000 000000FF
   ←── 高位补 0x00 ────────────────────────────────────────────→ 值在右端

int8(-1)（底层字节 0xFF）→ int256 = 符号扩展，值 -1（注意：和上面完全不同！）：
0x FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF
   ←── 高位补 0xFF（符号位为 1）────────────────────────────────→ 值在右端

int8(1)（底层字节 0x01）→ int256 = 符号扩展，值 1（符号位为 0，看起来和零扩展一样）：
0x 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000001
   ←── 高位补 0x00（符号位为 0）────────────────────────────────→ 值在右端
```

如果对 `int8(-1)`（即 `0xFF`）错用零扩展，会得到 `0x00...00FF` = 255，语义被彻底破坏。这个区分在 Lotus Router 中有直接体现：`BBCDecoder.sol` 第 178 行对 `int256 amountSpecified` 使用 `signextend` 操作码，就是因为 BBC 编码将有符号整数压缩为短字节后，必须在解码时恢复符号扩展，否则负数会被错误解读为正数。

- **字节序列是有序数据**，有效内容从第一个字节向后延伸（左→右）。左对齐（右填充）使第一个有效字节始终在最高位，`BYTE(n, x)` 操作码从左到右按索引提取字节时，索引 0 直接对应序列的第一个字节。类型扩展时同理：`bytes3(0xABCDEF)` → `bytes32` = 低位零扩展，字节序不变

```
bytes3(0xABCDEF) 编码为 32 字节：
0x ABCDEF00 00000000 00000000 00000000 00000000 00000000 00000000 00000000
   值在左端 ←── 低位补零（右填充）──────────────────────────────────────→
```

一句话总结：**两种填充方式都确保了有效内容在类型宽度扩展时保持位置不变，与 EVM 操作码的语义一致。**

**完整示例：`transfer(address,uint256)` 的逐字节 calldata**

调用 `transfer(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 1000000)` 时的完整 calldata：

```
偏移     内容                                                              说明
──────   ──────────────────────────────────────────────────────────────────  ─────────────
0x00     a9059cbb                                                          selector
0x04     000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48  address（左填充 12 字节零）
0x24     00000000000000000000000000000000000000000000000000000000000f4240  uint256 = 1,000,000
```

总计：4 + 32 + 32 = **68 字节**。

注意 address 的 12 字节零填充——这 12 个零字节虽然不携带信息，但每个仍消耗 4 gas（EIP-2028）。`transfer` 调用中，仅 address 填充就消耗了 48 gas。

### 动态类型编码（head-tail 结构）

包含动态类型（`bytes`、`string`、动态数组）的函数调用使用 **head-tail** 结构：

- **Head 区域**：每个参数占 32 字节。静态参数直接写入值；动态参数写入一个**偏移量（offset）**，指向 tail 区域中数据的起始位置
- **Tail 区域**：紧跟 head 之后，存放动态参数的实际数据（length + data）

**关键规则**：offset 是**相对于参数区域起始位置**（即 selector 之后）计算的，不是相对于 calldata 起始位置。

#### 完整示例 1：`foo(uint256, bytes, address)`

调用 `foo(42, 0xCAFEBABE, 0x000000000000000000000000000000000000bEEF)`：

**参数分析**：
- 参数 0（`uint256`）：静态 → 值直接在 head
- 参数 1（`bytes`）：动态 → head 中放 offset
- 参数 2（`address`）：静态 → 值直接在 head

**Head 区域大小**：3 个参数 × 32 字节 = 96 字节 = 0x60

**offset 推导**：bytes 参数的数据从 tail 区域的第一个位置开始，即偏移 0x60（参数区域起始 + 3 × 32）。

```
偏移     内容                                                              区域    说明
──────   ──────────────────────────────────────────────────────────────────  ──────  ─────────────
                                                                           HEAD
0x04     000000000000000000000000000000000000000000000000000000000000002a    │      uint256 = 42
0x24     0000000000000000000000000000000000000000000000000000000000000060    │      bytes offset = 0x60 ★
0x44     000000000000000000000000000000000000000000000000000000000000beef    │      address
                                                                           TAIL
0x64     0000000000000000000000000000000000000000000000000000000000000004    │      bytes length = 4
0x84     cafebabe00000000000000000000000000000000000000000000000000000000    │      bytes data（右填充）
```

**offset = 0x60 的推导过程**：
1. Head 区域有 3 个参数，共 3 × 32 = 96 字节
2. bytes 的 tail 数据紧跟 head 之后
3. 从参数区域起始到 tail 起始的距离 = 96 = 0x60
4. 所以 offset = 0x60

总计：4（selector） + 5 × 32 = **164 字节**。

#### 完整示例 2：`bar(bytes, string)` — 多个动态参数

调用 `bar(0xDEAD, "Hello")`：

**参数分析**：两个参数都是动态类型。

**Head 区域大小**：2 × 32 = 64 字节 = 0x40

```
偏移     内容                                                              区域    说明
──────   ──────────────────────────────────────────────────────────────────  ──────  ─────────────
                                                                           HEAD
0x04     0000000000000000000000000000000000000000000000000000000000000040    │      bytes offset = 0x40 ★
0x24     0000000000000000000000000000000000000000000000000000000000000080    │      string offset = 0x80 ★
                                                                           TAIL (bytes)
0x44     0000000000000000000000000000000000000000000000000000000000000002    │      bytes length = 2
0x64     dead000000000000000000000000000000000000000000000000000000000000    │      bytes data（右填充）
                                                                           TAIL (string)
0x84     0000000000000000000000000000000000000000000000000000000000000005    │      string length = 5
0xa4     48656c6c6f000000000000000000000000000000000000000000000000000000    │      string data（右填充）
```

**两个 offset 的推导**：
- bytes offset = 0x40：head 之后的第一个位置（2 × 32 = 64 = 0x40）
- string offset = 0x80：bytes 的 tail 占用 2 × 32 = 64 字节（length + padded data），所以 string 的 tail 从 0x40 + 0x40 = 0x80 开始

总计：4 + 6 × 32 = **196 字节**。

### 优点与代价

| 维度 | 描述 |
|------|------|
| **优点：O(1) 随机访问** | 每个参数在 head 区域都有固定位置（offset `4 + N × 32`）。静态参数的值直接在此读取；动态参数在此读取 offset 后一步跳转到 tail。不需要顺序解析 |
| **代价 1：大量零填充** | address 浪费 12 字节，bool 浪费 31 字节，小整数浪费 24-31 字节 |
| **代价 2：offset 间接寻址** | 每个动态参数需要额外 32 字节存放 offset，然后再 32 字节存放 length |
| **代价 3：对齐 padding** | 动态数据的 tail 必须右填充到 32 字节边界 |

这些"代价"在常规合约调用中几乎可以忽略。但在 MEV 场景下——每笔交易都在和时间赛跑，每一点 gas 都影响竞争力——这些冗余字节的成本变得不可接受。这就是 BBC 编码的动机：**用解码时的额外计算换取 calldata 的极致压缩**。

### 本节要点

1. 静态类型一律填充为 32 字节，整数左填充、字节右填充
2. 动态类型使用 head-tail 结构：head 中放 offset，tail 中放 length + data
3. offset 是**相对于参数区域起始**（selector 之后）计算的
4. ABI 编码的核心优点是 O(1) 随机访问，代价是大量零填充和 offset 间接寻址
5. BBC 编码的动机：用运行时解码计算换取 calldata 字节数的压缩

---

## 第四部分：Calldata 操作码详解

> **本节解决什么问题**：在 assembly 中手工操控 calldata 需要直接使用 EVM 操作码。本节逐一详解每个相关操作码的语义、栈行为和边界情况，配合具体数值的 256-bit 全展开示例。

### 1. CALLDATASIZE

返回当前 call frame 的 calldata 总字节数。

| 属性 | 值 |
|------|-----|
| 栈输入 | 0 |
| 栈输出 | 1（calldata 的字节长度） |
| Gas | 2 |

```
调用 transfer(address,uint256) 时：
calldata = [a9059cbb][32B address][32B amount] = 68 字节

CALLDATASIZE → 栈顶 = 0x44 (68)
```

在 Lotus Router 中，`CALLDATASIZE` 没有被直接使用——BBC 解码依靠 `calldataload` 超出范围时返回零的行为实现隐式终止（`Action.Halt`）。

### 2. CALLDATALOAD(offset)

从 calldata 的指定偏移处读取 32 字节到栈顶。

| 属性 | 值 |
|------|-----|
| 栈输入 | 1（offset） |
| 栈输出 | 1（32 字节值） |
| Gas | 3 |

**关键行为：不足 32 字节时，右侧零填充。** 如果从 offset 开始到 calldata 末尾不足 32 字节，缺失的字节用 0x00 填充。offset 完全超出 calldata 范围时，返回全零。

**最小示例**：calldata = `0xCAFEBABEDEADBEEF`（8 字节）

**calldataload(0)** — 从偏移 0 读取，有 8 字节可用，剩余 24 字节零填充：

```
calldata:   CA FE BA BE DE AD BE EF (8 字节)

calldataload(0):

CAFEBABE DEADBEEF 00000000 00000000 00000000 00000000 00000000 00000000
^^^^^^^^ ^^^^^^^^
实际数据            右侧 24 字节零填充
```

**calldataload(4)** — 从偏移 4 读取，有 4 字节可用，剩余 28 字节零填充：

```
calldataload(4):

DEADBEEF 00000000 00000000 00000000 00000000 00000000 00000000 00000000
^^^^^^^^
偏移 4 起的 4 字节    右侧 28 字节零填充
```

**calldataload(6)** — 从偏移 6 读取，有 2 字节可用，剩余 30 字节零填充：

```
calldataload(6):

BEEF0000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
^^^^
偏移 6 起的 2 字节    右侧 30 字节零填充
```

**calldataload(8)** — 偏移 8 已超出 calldata（只有 8 字节，索引 0-7），返回全零：

```
calldataload(8):

00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
全零 — calldata 已耗尽
```

**Lotus Router 利用了这个零填充行为**：当 calldata 解析完毕后，下一次 `calldataload` 返回 0，`shr(0xf8, 0) = 0 = Action.Halt`（枚举值 0），执行循环正常终止。无需显式编码终止标记。

### 3. CALLDATACOPY(destOffset, offset, size)

从 calldata 复制指定长度的字节到 memory。

| 属性 | 值 |
|------|-----|
| 栈输入 | 3（destOffset, offset, size） |
| 栈输出 | 0 |
| Gas | 3 + 3 × ⌈size/32⌉ + memory 扩展成本 |

**与 CALLDATALOAD 的区别**：

| 维度 | CALLDATALOAD | CALLDATACOPY |
|------|-------------|-------------|
| 目标 | 栈 | Memory |
| 大小 | 固定 32 字节 | 任意 size |
| 用途 | 读取单个值 | 批量复制数据 |

**Gas 公式拆解**：
- 基础成本：3 gas（G_verylow）
- 复制成本：3 gas × ⌈size / 32⌉（G_copy × 字数）
- Memory 扩展成本：如果目标区域超出当前 memory 高水位线

**示例**：从 calldata[0x3f] 复制 5 字节到 memory[fmp+0xa4]

```
执行前 memory[fmp+0xa4 : fmp+0xa9]:  00 00 00 00 00

calldatacopy(fmp+0xa4, 0x3f, 5)

执行后 memory[fmp+0xa4 : fmp+0xa9]:  48 65 6c 6c 6f  ← "Hello"

gas = 3 + 3 × ⌈5/32⌉ = 3 + 3 × 1 = 6 gas（不含 memory 扩展）
```

在 Lotus Router 中，`calldatacopy` 是 `BytesCalldata` lazy copy 模式的最终执行点——动态数据只在外部调用前才从 calldata 复制到 memory（见 `UniV2Pair.sol:70`、`UniV3Pool.sol:78`、`Dyn.sol:14`）。

### 4. SHR / SHL — 位移裁剪

位移操作码用于从 32 字节的 `calldataload` 结果中提取特定长度的值。

**SHR(shift, value)** — 逻辑右移：

| 属性 | 值 |
|------|-----|
| 栈输入 | 2（shift 位数, value） |
| 栈输出 | 1（结果） |
| Gas | 3 |

**SHL(shift, value)** — 逻辑左移：

| 属性 | 值 |
|------|-----|
| 栈输入 | 2（shift 位数, value） |
| 栈输出 | 1（结果） |
| Gas | 3 |

#### 示例 1：shr(224, ...) 提取高 4 字节

256-bit 全展开演示——从 calldataload 结果中提取函数 selector：

```
移位前: A9059CBB 00000000 00000000 00000000 00000000 00000000 00000000 00000000
        ^^^^^^^^ 高 4 字节 = selector

shr(224) 后: 00000000 00000000 00000000 00000000 00000000 00000000 00000000 A9059CBB
                                                                          ^^^^^^^^ 结果

224 = 256 - 32 = 256 - (4 字节 × 8 bit)
```

这正是 BBC 解码器中 `u32Shr = 0xe0`（224）常量的用途——提取 4 字节的 `uint32` 长度前缀（`BBCDecoder.sol:39`）。

#### 示例 2：shr(248, ...) 提取高 1 字节

256-bit 全展开演示——提取 1 字节的 Action 枚举或 byteLen 前缀：

```
移位前: 0B000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
        ^^ 高 1 字节 = 0x0B = 11 = Action.DynCall

shr(248) 后: 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000000B
                                                                                ^^ 结果

248 = 256 - 8 = 256 - (1 字节 × 8 bit)
```

这是 BBC 解码器中 `u8Shr = 0xf8`（248）常量的用途（`BBCDecoder.sol:38`）。

#### 示例 3：BBC 解码三步模式 — 提取 20 字节地址

这是 BBC 解码的核心模式，以提取一个 20 字节的 address 为例：

**第一步：读取 byteLen**

```solidity
nextByteLen := shr(u8Shr, calldataload(nextPtr))  // 读取 1 字节 = 0x14 = 20
```

```
calldataload(nextPtr):

14C1B083 CAAD2045 72F0F25C E26C4F53 64FD4707 0D000000 00000000 00000000
^^ byteLen = 0x14 = 20

shr(248):

00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000014
                                                                    ^^ 结果 = 20
```

**第二步：计算 bitShift**

```solidity
nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
             // = 256 - (8 × 20) = 256 - 160 = 96 = 0x60
```

公式含义：一个 256-bit 槽中，20 字节占据高 160 bit，需要右移 96 bit 才能将值移到低位。

**第三步：shr 提取地址**

```solidity
nextPtr := add(nextPtr, 0x01)   // 跳过 byteLen 字节
// 现在 nextPtr 指向地址数据的起始位置

pair := shr(nextBitShift, calldataload(nextPtr))
```

```
calldataload(nextPtr):  // 从地址数据起始位置读 32 字节

C1B083CA AD204572 F0F25CE2 6C4F5364 FD47070D [后续 calldata 内容，12 字节]
^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^
                20 字节地址数据

shr(96) 后:

00000000 00000000 00000000 C1B083CA AD204572 F0F25CE2 6C4F5364 FD47070D
                           ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^
                                    提取出的 20 字节地址（低 160 bit）
```

**三步模式总结**：`byteLen` → `bitShift = 256 - 8 × byteLen` → `shr(bitShift, calldataload(...))`

这个模式在 `BBCDecoder.sol` 中反复出现：每个可变长度静态字段的解码都是这三步（如 `BBCDecoder.sol:78-82` 解码 pair 地址、`BBCDecoder.sol:85-89` 解码 amount0Out）。

### 5. SIGNEXTEND(b, x)

有符号整数的符号扩展（Sign Extension）操作码。

| 属性 | 值 |
|------|-----|
| 栈输入 | 2（b, x） |
| 栈输出 | 1（符号扩展后的值） |
| Gas | 5 |

**语义**：将 `x` 视为一个 `(b+1)` 字节的有符号整数，将第 `b` 字节（从低位 0 开始计）的最高位（符号位）扩展到所有更高的位。

**为什么 BBC 编码需要 SIGNEXTEND？**

BBC 编码按紧凑字节存储值。对于 `int256` 类型（如 Uniswap V3 的 `amountSpecified`），一个负数如 `-1 ether` 在 256-bit 表示中是：

```
0xFFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF F21F494C 589C0000
```

BBC 编码可能只存储最低 8 个有效字节。`shr` 提取后得到的是一个无符号值，需要 `signextend` 恢复符号。

**示例：8 字节负数经 signextend(7, x) 扩展为 32 字节**

假设 BBC 编码存储了 8 字节值 `0xF21F494C589C0000`（-1 ether 的低 8 字节），`shr` 提取后：

```
shr 提取后的值 x:

00000000 00000000 00000000 00000000 00000000 00000000 F21F494C 589C0000
                                                      ^^^^^^^^ ^^^^^^^^
                                                      8 字节数据（最高位 F = 1111, 符号位 = 1）

signextend(7, x):    // b = 7, 即 (7+1) = 8 字节
                     // 第 7 字节的最高位(bit 63)是 1 → 扩展为全 1

FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFF F21F494C 589C0000
^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^
              符号位扩展到所有高位字节
```

在 `BBCDecoder.sol:177-178` 中的实际用法：

```solidity
amountSpecified := shr(nextBitShift, calldataload(nextPtr))
amountSpecified := signextend(sub(nextByteLen, 0x01), amountSpecified)
//                             ^^^^^^^^^^^^^^^^^^^^^^^^
//                             b = byteLen - 1（第 b 字节 = 最高有效字节）
```

`sub(nextByteLen, 0x01)` 的含义：如果 byteLen=8，则 b=7，表示"将第 7 字节（从 0 开始）的符号位扩展"——即将 8 字节有符号整数扩展到 32 字节。

### 本节要点

1. `CALLDATALOAD(offset)` 总是返回 32 字节，不足部分右侧零填充，超出范围返回全零
2. `CALLDATACOPY(dest, offset, size)` 将任意长度的 calldata 复制到 memory，gas = 3 + 3 × ⌈size/32⌉ + memory 扩展
3. `SHR(shift, value)` 右移提取高位字节——BBC 解码的核心操作。`u8Shr=248` 提取 1 字节，`u32Shr=224` 提取 4 字节
4. BBC 三步解码模式：读 byteLen → 计算 bitShift = 256 - 8 × byteLen → `shr(bitShift, calldataload(ptr))`
5. `SIGNEXTEND(b, x)` 将紧凑字节恢复为完整的有符号 256-bit 值，`b = byteLen - 1`

---

## 第五部分：在 Memory 中手工构造 ABI 编码调用

> **本节解决什么问题**：Lotus Router 在 assembly 中手工构造 ABI 编码的外部调用——从 calldata 中解码出紧凑的 BBC 数据，在 memory 中重新组装为标准 ABI 格式，然后通过 `call` 操作码发送给目标合约。本节用三个递进场景展示这个过程。

### 场景 1：纯静态参数 — ERC20.transfer(address, uint256)

> 源码：`ERC20.sol:49-64`

这是最简单的情况——只有两个静态参数，不涉及动态数据。

**策略：Scratch Space**

Solidity 保留 memory[0x00:0x3f] 作为 scratch space（哈希临时空间）。ERC20.transfer 直接在这里构造调用数据，不通过 free memory pointer 分配——节省了 memory 扩展成本。

```solidity
// ERC20.sol:49-64
function transfer(ERC20 token, address receiver, uint256 amount) returns (bool success) {
    assembly ("memory-safe") {
        mstore(0x00, transferSelector)  // 步骤 1
        mstore(0x04, receiver)          // 步骤 2
        mstore(0x24, amount)            // 步骤 3
        success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)  // 步骤 4
        let successERC20 := or(iszero(returndatasize()), eq(0x01, mload(0x00)))  // 步骤 5
        success := and(success, successERC20)  // 步骤 6
        mstore(0x24, 0x00)              // 步骤 7: 恢复
    }
}
```

**call 执行前的 Memory 布局**（0x00 起始）：

```
偏移     写入操作               内容                    说明
──────   ────────────────────   ─────────────────────   ──────────────────
0x00     mstore(0x00, sel)      a9059cbb 00..00         selector（32B 中仅高 4B 有效）
0x04     mstore(0x04, rcv)      00..00 <receiver>       address（32B 左填充，覆盖 0x04-0x23）
0x24     mstore(0x24, amt)      00..00 <amount>         uint256（32B，覆盖 0x24-0x43）
```

注意 `mstore` 总是写 32 字节。`mstore(0x04, receiver)` 覆盖了 memory[0x04:0x23]，其中 0x04-0x1f 是 selector 写入的低位零字节，被 address 的左填充零字节覆盖——结果不变。

**call 参数**：`call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)`
- `argsOffset = 0x00`：从 memory[0x00] 开始
- `argsLength = 0x44`：68 字节 = 4（selector）+ 32 + 32
- `retOffset = 0x00`：返回值写回 memory[0x00]
- `retLength = 0x20`：期望最多 32 字节返回值

**恢复操作**：`mstore(0x24, 0x00)` 将 memory[0x24:0x43] 清零。为什么？因为 `mstore(0x24, amount)` 写了 32 字节到 0x24-0x43，其中 0x40-0x43 覆盖了 free memory pointer 的高 4 字节。`mstore(0x24, 0x00)` 恢复这些字节为零，确保 fmp 不被破坏。

### 场景 2：4 参数 + bytes — UniV2Pair.swap(uint256, uint256, address, bytes)

> 源码：`UniV2Pair.sol:51-73`

增加了动态参数 `bytes data`，需要构造完整的 ABI head-tail 结构。

**策略：fmp 分配**

```solidity
// UniV2Pair.sol:51-73
function swap(
    UniV2Pair pair, uint256 amount0Out, uint256 amount1Out,
    address to, BytesCalldata data
) returns (bool success) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)                                    // ① 读取 fmp

        let dataLen := shr(0xe0, calldataload(data))              // ② BytesCalldata 长度
        data := add(data, 0x04)                                   // ③ 跳过 uint32 长度前缀

        mstore(add(fmp, 0x00), swapSelector)                      // ④ selector
        mstore(add(fmp, 0x04), amount0Out)                        // ⑤ 参数 1
        mstore(add(fmp, 0x24), amount1Out)                        // ⑥ 参数 2
        mstore(add(fmp, 0x44), to)                                // ⑦ 参数 3
        mstore(add(fmp, 0x64), 0x80)                              // ⑧ bytes offset ★
        mstore(add(fmp, 0x84), dataLen)                           // ⑨ bytes length
        calldatacopy(add(fmp, 0xa4), data, dataLen)               // ⑩ bytes data

        success := call(gas(), pair, 0x00, fmp, add(dataLen, 0xc4), 0x00, 0x00)  // ⑪
    }
}
```

**call 执行前的 Memory 布局**（fmp 起始，假设 dataLen = 5）：

```
偏移         写入操作                    内容                          说明
──────────   ────────────────────────   ──────────────────────────    ──────────────
fmp+0x00     mstore(fmp+0x00, sel)      022c0d9f 00..00              swap selector
fmp+0x04     mstore(fmp+0x04, a0)       00..00 <amount0Out>          参数 1（32B）
fmp+0x24     mstore(fmp+0x24, a1)       00..00 <amount1Out>          参数 2（32B）
fmp+0x44     mstore(fmp+0x44, to)       00..00 <to>                  参数 3（32B）
fmp+0x64     mstore(fmp+0x64, 0x80)     00..00 00000080              bytes offset ★
fmp+0x84     mstore(fmp+0x84, len)      00..00 00000005              bytes length
fmp+0xa4     calldatacopy               48 65 6c 6c 6f               bytes data
fmp+0xa9     (未写入)                    00 00 00 ... (padding)       ABI 尾部零区域
```

**offset = 0x80 的推导**：

从 selector 之后开始的参数区域有 4 个 ABI 参数槽位：
- 槽 0（fmp+0x04）：amount0Out
- 槽 1（fmp+0x24）：amount1Out
- 槽 2（fmp+0x44）：to
- 槽 3（fmp+0x64）：bytes offset

Head 区域大小 = 4 × 32 = 128 = 0x80。bytes 的 tail 数据从参数区域起始 + 0x80 处开始——所以 offset = 0x80。

**call size = add(dataLen, 0xc4) 的推导**：

ABI 编码的严格最小长度：
```
  0x04  selector
+ 0x80  head (4 × 32B)
+ 0x20  bytes length
+ dataLen  bytes data
= 0xa4 + dataLen
```

但代码使用 `0xc4 + dataLen = 0xa4 + 0x20 + dataLen`。额外的 0x20 字节是什么？

这是一个**设计选择**：在 bytes data 之后额外传送 32 字节的内存内容（通常为零），充当 ABI 尾部零填充。ABI 规范要求动态数据右填充到 32 字节边界，如果在运行时计算精确的 padding 长度（`sub(0x20, mod(dataLen, 0x20))`），需要额外的除法和条件判断。代码选择了更简单的方案：**始终多传 32 字节零填充，避免运行时 padding 计算。** 接收合约会忽略尾部多余的零字节。

### 场景 3：5 参数 + bytes — UniV3Pool.swap(address, bool, int256, uint160, bytes)

> 源码：`UniV3Pool.sol:57-81`

比场景 2 多一个静态参数。

```solidity
// UniV3Pool.sol:57-81
function swap(
    UniV3Pool pool, address recipient, bool zeroForOne,
    int256 amountSpecified, uint160 sqrtPriceLimitX96, BytesCalldata data
) returns (bool success) {
    assembly ("memory-safe") {
        let fmp := mload(0x40)

        let dataLen := shr(0xe0, calldataload(data))
        data := add(data, 0x04)

        mstore(add(fmp, 0x00), swapSelector)            // 0x128acb08
        mstore(add(fmp, 0x04), recipient)                // 参数 1
        mstore(add(fmp, 0x24), zeroForOne)               // 参数 2
        mstore(add(fmp, 0x44), amountSpecified)          // 参数 3
        mstore(add(fmp, 0x64), sqrtPriceLimitX96)        // 参数 4
        mstore(add(fmp, 0x84), 0xa0)                     // bytes offset ★
        mstore(add(fmp, 0xa4), dataLen)                  // bytes length
        calldatacopy(add(fmp, 0xc4), data, dataLen)      // bytes data

        success := call(gas(), pool, 0x00, fmp, add(dataLen, 0xe4), 0x00, 0x00)
    }
}
```

**call 执行前的 Memory 布局**：

```
偏移         内容                    说明
──────────   ──────────────────────  ──────────────
fmp+0x00     128acb08 00..00        swap selector
fmp+0x04     00..00 <recipient>     参数 1: address
fmp+0x24     00..00 <zeroForOne>    参数 2: bool (0 或 1)
fmp+0x44     <amountSpecified>      参数 3: int256（可能为负数）
fmp+0x64     00..00 <sqrtPrice>     参数 4: uint160
fmp+0x84     00..00 000000a0        bytes offset = 0xa0 ★
fmp+0xa4     00..00 <dataLen>       bytes length
fmp+0xc4     [data bytes]           bytes data
fmp+0xc4+N   00..00                 ABI 尾部零区域
```

**对比场景 2**：

| 维度 | 场景 2（UniV2 swap） | 场景 3（UniV3 swap） |
|------|---------------------|---------------------|
| 静态参数数 | 3（amount0Out, amount1Out, to） | 4（recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96） |
| head 槽数 | 4（3 个静态 + 1 个 offset） | 5（4 个静态 + 1 个 offset） |
| bytes offset | 0x80（4 × 32） | 0xa0（5 × 32） |
| call size | `add(dataLen, 0xc4)` | `add(dataLen, 0xe4)` |
| ABI 严格最小 | 0xa4 + dataLen | 0xc4 + dataLen |
| 额外 padding | 0x20 | 0x20 |

规律：**offset = 参数槽数 × 0x20**，**call size = 0x04 + (参数槽数 + 1) × 0x20 + 0x20 + dataLen**（额外 0x20 为统一 padding）。

### 本节要点

1. ERC20.transfer 使用 scratch space（memory[0x00]）构造调用，调用后需恢复被覆盖的 fmp 高位字节
2. UniV2Pair.swap 使用 fmp 分配，bytes 的 ABI offset = head 槽数 × 32 = 4 × 32 = 0x80
3. UniV3Pool.swap 比 V2 多一个静态参数，offset = 5 × 32 = 0xa0
4. 三个协议交互函数都在 call size 中额外加 0x20 作为统一的 ABI 尾部零填充，避免运行时计算 padding
5. `calldatacopy` 是 `BytesCalldata` lazy copy 的最终执行点——动态数据在此从 calldata 直接复制到 memory 中的 ABI 布局位置

---

## 第六部分：call 操作码的 7 个参数

> **本节解决什么问题**：`call` 是 EVM 中发起外部调用的核心操作码，有 7 个参数。理解每个参数的含义和常见用法模式，是读懂 Lotus Router 协议交互代码的基础。

（基础概念详见博客《EVM 基础原理（三）：ABI 编码与底层调用》，本节聚焦 assembly 用法模式）

### 参数详解

```
call(gas, addr, value, argsOffset, argsLength, retOffset, retLength)
```

| # | 参数 | 说明 |
|---|------|------|
| 1 | `gas` | 分配给子调用的 gas 量。通常用 `gas()` 传入当前剩余 gas |
| 2 | `addr` | 目标合约地址 |
| 3 | `value` | 随调用发送的 ETH（wei）。不发送 ETH 时为 0 |
| 4 | `argsOffset` | memory 中调用数据（selector + 参数）的起始偏移 |
| 5 | `argsLength` | 调用数据的字节长度 |
| 6 | `retOffset` | memory 中存放返回数据的起始偏移 |
| 7 | `retLength` | 期望读取的返回数据字节数 |

**返回值**：栈顶压入 1（成功）或 0（revert/失败）。

**retOffset/retLength 的行为**：
- 如果子调用返回了数据，EVM 将前 `retLength` 字节写入 memory[retOffset : retOffset + retLength]
- 即使 `retLength = 0`，返回数据仍然可以通过 `returndatasize()` 和 `returndatacopy()` 访问（EIP-211 returndata 缓冲区）
- 如果实际返回数据少于 `retLength`，只写入实际长度，剩余部分不变

### Lotus Router 中的 call 模式

#### 模式 A：带 bytes 参数的协议调用（无返回值）

```solidity
// UniV2Pair.sol:72
success := call(gas(), pair, 0x00, fmp, add(dataLen, 0xc4), 0x00, 0x00)
//              ^^^^   ^^^^  ^^^^  ^^^  ^^^^^^^^^^^^^^^^^^  ^^^^  ^^^^
//              全gas  地址   0ETH  从fmp开始  数据长度       不读取返回值
```

特征：`retOffset=0x00, retLength=0x00`——不读取返回值。V2 swap 的成功/失败完全由 `call` 本身的返回码决定。

同样的模式见于：`UniV3Pool.sol:80`（V3 swap）、`UniV3Pool.sol:146`（V3 flash）、`Dyn.sol:16`（dynCall）。

#### 模式 B：scratch space + 返回值校验

```solidity
// ERC20.sol:57-61
success := call(gas(), token, 0x00, 0x00, 0x44, 0x00, 0x20)
//                                  ^^^^  ^^^^  ^^^^  ^^^^
//                                  从0x00开始   返回值写入memory[0x00:0x1f]

let successERC20 := or(iszero(returndatasize()), eq(0x01, mload(0x00)))
success := and(success, successERC20)
```

特征：
- `argsOffset=0x00`：从 scratch space 读取调用数据
- `retOffset=0x00, retLength=0x20`：返回值覆盖写入 memory[0x00:0x1f]
- 返回值校验使用 `or(iszero(returndatasize()), eq(0x01, mload(0x00)))`

返回值校验逻辑详解见文档二（`inline_assembly_guide.md`）第四部分。

同样的模式见于：`ERC20.sol:124-128`（transferFrom）。

#### 模式 C：无 calldata 纯 ETH 调用

```solidity
// WETH.sol:35-37
success := call(gas(), weth, value, 0x00, 0x00, 0x00, 0x00)
//                           ^^^^^  ^^^^  ^^^^
//                           ETH值  无calldata（argsLength=0）
```

特征：`argsLength=0x00`——不发送任何 calldata。这利用了 WETH 合约的 `fallback()` 函数：当 `calldatasize` 为零时，WETH 的 selector dispatcher 短路直接执行 deposit 逻辑（见 `WETH.sol:28-29` 注释）。比显式调用 `deposit()` 节省 4 字节 selector 的 calldata gas。

#### 模式 D：带 calldata 的 ETH 零值调用（scratch space）

```solidity
// WETH.sol:62-67
mstore(0x00, withdrawSelector)           // 0x2e1a7d4d
mstore(0x04, value)
success := call(gas(), weth, 0x00, 0x00, 0x24, 0x00, 0x00)
//                           ^^^^  ^^^^  ^^^^
//                           0ETH  从0x00开始  36字节(4+32)
```

特征：使用 scratch space 构造标准 ABI 调用（selector + 1 个参数），不读取返回值。

### staticcall 与 delegatecall

| 操作码 | 参数数 | 与 call 的区别 |
|--------|--------|---------------|
| `staticcall` | 6（无 value） | 不能修改状态、不能发送 ETH |
| `delegatecall` | 6（无 value） | 在调用者的上下文中执行（msg.sender/msg.value 保持不变） |

Lotus Router 源码中，BBCEncoder 使用 `staticcall` 调用 identity precompile（地址 `0x04`）进行 memory → memory 复制（`BBCEncoder.sol:93`）——这是 EVM 在 Cancun（MCOPY）之前没有原生 memcpy 的变通方案。

### 本节要点

1. `call` 有 7 个参数：gas、addr、value、argsOffset、argsLength、retOffset、retLength
2. LR 中有四种 call 模式：带 bytes 无返回值（V2/V3 swap）、scratch space + 返回值校验（ERC20）、纯 ETH 无 calldata（WETH deposit）、scratch space 标准调用（WETH withdraw）
3. `retOffset/retLength=0` 不读取返回值，但 returndata 缓冲区仍可通过 `returndatasize()`/`returndatacopy()` 访问
4. WETH deposit 利用 `receive()` 省去 selector，是最简的 call 模式

---

## 第七部分：BBC 编码规格与 Gas 优化原理

> **本节解决什么问题**：BBC（BigBrainChad）编码是 Lotus Router 用来替代标准 ABI 编码的紧凑 calldata 格式。本节作为可反复查阅的**规格表**，完整定义三种编码模式，并量化 gas 节省。

### BBC 编码概览

BBC 编码的核心思想：**按值的实际字节长度存储，而非填充到 32 字节**。

| 编码模式 | 适用场景 | 格式 | 示例 |
|----------|----------|------|------|
| 固定 1 字节 | 类型宽度 ≤ 8 bit（bool、Action 枚举） | `[1B value]` | canFail: `00` |
| 可变长度静态值 | 类型宽度 > 8 bit（address、uint256、int256） | `[1B byteLen][N bytes value]` | address: `14` + 20B |
| 动态字节数据 | `bytes` | `[4B uint32 length][N bytes data]` | 5 字节数据: `00000005` + 5B |

### 模式 1：固定 1 字节字段

适用于值范围不超过 1 字节（0-255）的字段。

**编码**：值直接占 1 字节，无前缀。

```
字段     编码          说明
──────   ──────────    ──────
canFail  00            false = 0x00
canFail  01            true = 0x01
Action   0b            DynCall = 11 = 0x0b
```

**解码**（`BBCDecoder.sol:75`）：

```solidity
canFail := shr(u8Shr, calldataload(nextPtr))
// u8Shr = 0xf8 = 248
// shr(248, calldataload(ptr)) 提取高 1 字节
// 指针推进 1 字节
nextPtr := add(nextPtr, 0x01)
```

**与 ABI 的对比**：ABI 中 `bool` 占 32 字节（31 字节零 + 1 字节值），BBC 只需 1 字节。节省 31 字节。

### 模式 2：可变长度静态值

适用于类型宽度大于 8 bit 的静态值（address = 160 bit、uint256 = 256 bit、int256 = 256 bit 等）。

**编码**：1 字节 `byteLen` 前缀 + N 字节紧凑值。

**编码示例**（address）：

```
ABI 编码:
000000000000000000000000 A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
12 字节零填充               20 字节地址
→ 总计 32 字节

BBC 编码:
14 A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
byteLen=20   20 字节地址
→ 总计 21 字节
```

**编码示例**（uint256 = 0，零值特殊处理）：

```
ABI 编码:
0000000000000000000000000000000000000000000000000000000000000000
→ 32 字节全零

BBC 编码:
00
^^ byteLen=0 → 值为 0，无后续数据
→ 总计 1 字节
```

**byteLen = 0 的特殊语义**：当 `byteLen = 0` 时，值为 0。解码器不读取后续数据，指针不推进。这是零值优化的关键——ABI 中零值消耗 32 × 4 = 128 gas 的零字节，BBC 只消耗 1 × 4 = 4 gas。

**编码示例**（uint256 = 1 ether = 0x0DE0B6B3A7640000）：

```
ABI 编码:
0000000000000000000000000000000000000000000000000DE0B6B3A7640000
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^
24 字节零填充                                     8 字节值
→ 32 字节

BBC 编码:
08 0DE0B6B3A7640000
^^ ^^^^^^^^^^^^^^^^
byteLen=8   8 字节值
→ 9 字节
```

**解码**（三步模式，`BBCDecoder.sol:78-82`）：

```solidity
// 步骤 1: 读 byteLen
nextByteLen := shr(u8Shr, calldataload(nextPtr))    // 例: 20
nextPtr := add(nextPtr, 0x01)                        // 跳过 byteLen

// 步骤 2: 计算位移量
nextBitShift := sub(0x0100, mul(0x08, nextByteLen))  // 256 - 8×20 = 96

// 步骤 3: 提取值
pair := shr(nextBitShift, calldataload(nextPtr))     // 右移 96 位
nextPtr := add(nextPtr, nextByteLen)                  // 跳过 N 字节值
```

**对称的编码操作**（`BBCEncoder.sol:69`）：

```solidity
mstore(ptr, shl(sub(0x0100, mul(0x08, pairByteLen)), pair))
//          ^^^ 左移到高位，写入 memory
ptr := add(ptr, pairByteLen)
```

编码和解码使用相同的位移公式 `sub(0x0100, mul(0x08, byteLen))`，只是方向相反：编码用 `shl`（左移到高位存储），解码用 `shr`（右移到低位使用）。

**有符号整数的 byteLen 计算**

`int256` 类型需要特殊处理符号位。`BBCEncoder.sol:678-691` 的 `byteLen(int256)` 实现：

```solidity
function byteLen(int256 word) internal pure returns (uint8) {
    uint256 adjusted;
    if (word < 0) {
        adjusted = uint256(-word);   // 取绝对值
    } else {
        adjusted = uint256(word);
    }
    if (byteLen(adjusted) == 32) return 32;
    else return byteLen(adjusted << 1);  // 左移 1 位为符号位预留空间
}
```

`adjusted << 1` 的作用：为符号位预留 1 bit 空间。例如 `-1 ether` 的绝对值是 `0x0DE0B6B3A7640000`（8 字节），左移 1 位后仍为 8 字节，所以 byteLen = 8。解码时通过 `signextend(7, value)` 恢复符号。

### 模式 3：动态字节数据

适用于 `bytes` 类型的动态数据。

**编码**：4 字节 `uint32` 长度前缀 + N 字节原始数据，无 padding。

```
ABI 编码 (5 字节 "Hello"):
0000000000000000000000000000000000000000000000000000000000000005  ← length (32B)
48656c6c6f000000000000000000000000000000000000000000000000000000  ← data (右填充到 32B)
→ 64 字节

BBC 编码:
00000005 48656c6c6f
^^^^^^^^ ^^^^^^^^^^
uint32     5 字节数据，无填充
→ 9 字节
```

**解码**（`BBCDecoder.sol:106-112`）：

```solidity
nextByteLen := shr(u32Shr, calldataload(nextPtr))  // 读 4 字节 uint32 长度
data := nextPtr                                      // BytesCalldata = 当前偏移量
nextPtr := add(nextPtr, 0x04)                        // 跳过 length
nextPtr := add(nextPtr, nextByteLen)                  // 跳过 data body
```

注意 `data := nextPtr` 只记录了一个 `uint32` 偏移量——这就是 `BytesCalldata` 的 lazy copy 语义：解码阶段零 memory 操作，消费端才通过 `calldatacopy` 复制数据。

### Gas 优化计算

#### 逐字段对比

| 字段类型 | ABI 字节数 | BBC 字节数 | ABI gas | BBC gas | 节省 |
|----------|------------|------------|---------|---------|------|
| address（20B 非零） | 32 | 21（1+20） | 368 | 336 | 32 gas |
| uint256 = 0 | 32 | 1 | 128 | 4 | 124 gas |
| uint256 = 1 ether | 32 | 9（1+8） | 200 | 120 | 80 gas |
| bool = true | 32 | 1 | 140 | 16 | 124 gas |
| bytes（5B） | 96（32 offset + 32 length + 32 padded data） | 9（4+5） | 408 | 84 | 324 gas |

> gas 计算：零字节 4 gas/B，非零字节 16 gas/B
>
> 1 ether = `0x0DE0B6B3A7640000`，8 字节中 6 字节非零、2 字节零（`A7 64` 后跟 `00 00`）。ABI gas = (24+2)×4 + 6×16 = 200。BBC gas = 1×16(byteLen) + 6×16 + 2×4 = 120

#### 完整 swap 调用对比

以 UniV2 `swap(1 ether, 0, to_address, empty_bytes)` 为例：

**标准 ABI 编码**（直接调用 V2 pair）：

```
selector  (4B)  : 022c0d9f                          →  4 × 16 = 64 gas
amount0Out(32B) : 00..00 0DE0B6B3A7640000           → 26×4 + 6×16 = 200 gas
amount1Out(32B) : 00..00 00000000                   → 32×4 = 128 gas
to        (32B) : 00..00 <20B address>              → 12×4 + 20×16 = 368 gas
offset    (32B) : 00..00 00000080                   → 31×4 + 1×16 = 140 gas
length    (32B) : 00..00 00000000                   → 32×4 = 128 gas
─────────────────────────────────────────────────────────────────────────
合计: 164 字节                                          1028 gas
```

> amount0Out 的 8 字节值 `0D E0 B6 B3 A7 64 00 00` 中有 2 个零字节（末尾），故非零 6 字节、零 26 字节

**BBC 编码**（通过 LR 的 `takeAction`）：

```
selector     (4B) : 19ff8034                        →  4 × 16 = 64 gas
Action       (1B) : 01                              →  1 × 16 = 16 gas
canFail      (1B) : 00                              →  1 × 4  = 4 gas
pair byteLen (1B) : 14                              →  1 × 16 = 16 gas
pair        (20B) : <address>                       → 20 × 16 = 320 gas
a0Out byteLen(1B) : 08                              →  1 × 16 = 16 gas
a0Out        (8B) : 0DE0B6B3A7640000                →  6×16 + 2×4 = 104 gas
a1Out byteLen(1B) : 00                              →  1 × 4  = 4 gas
to byteLen   (1B) : 14                              →  1 × 16 = 16 gas
to          (20B) : <address>                       → 20 × 16 = 320 gas
data length  (4B) : 00000000                        →  4 × 4  = 16 gas
─────────────────────────────────────────────────────────────────────────
合计: 62 字节                                            896 gas
```

| 维度 | ABI | BBC | 节省 |
|------|-----|-----|------|
| Calldata 字节数 | 164 | 62 | **62%** |
| Calldata gas | 1028 | 896 | **~13%** |

字节数节省（62%）远大于 gas 节省（~13%），原因是 ABI 中被消除的主要是零填充字节，而零字节单价低（4 gas/B）。BBC 的 gas 节省集中在消除 offset 和 length 字段的非零字节。

#### L2 环境下的放大效应

在 L2（如 Base、Arbitrum、Optimism）上，交易成本的主要组成部分是 L1 data fee——即把交易数据提交到 L1 进行数据可用性验证的成本。EIP-4844（Cancun 硬分叉）后，L2 逐步转向 blob 提交，具体的 L1 fee 计算公式因链而异（如 OP Stack 的 Ecotone 升级引入了基于 blob base fee 的新公式）。但核心逻辑不变：**calldata 越短，L1 data fee 越低**。

在这个环境下：
- ABI 的 164 字节 vs BBC 的 62 字节 → 数据体积减少 **62%**，直接降低 L1 data fee
- 这不是微优化——对于高频 MEV bot，每笔交易节省几十字节 calldata，累积效果显著

#### BBC 的临界条件

BBC 并非总是优于 ABI：

| 场景 | BBC 表现 | 原因 |
|------|---------|------|
| 值占满 32 字节（如 keccak256 哈希） | **多 1 字节** | byteLen 前缀无法抵消——1+32 > 32 |
| 少量参数 + 大动态数据 | 优势减小 | 固定参数的压缩被大数据体稀释 |
| 大量零值参数 | **大幅节省** | 每个零值从 32B 压缩到 1B |
| 多个 address 参数 | 稳定节省 | 每个 address 省 11 字节 |

实际上，MEV 交易中 32 字节全满的值极少出现——大部分参数是 address（20B）、中等大小的 uint（4-16B）和 bool（1B），BBC 几乎总是有优势。

### 本节要点

1. BBC 三种编码模式：固定 1 字节（bool/枚举）、byteLen + 紧凑值（address/uint/int）、uint32 长度 + 原始数据（bytes）
2. `byteLen = 0` 表示零值——ABI 的 32 字节零从 128 gas 压缩到 4 gas
3. 有符号整数需要 `byteLen(adjusted << 1)` 为符号位预留空间，解码时用 `signextend` 恢复
4. L1 上 BBC 节省约 13% calldata gas；L2 上因 L1 data fee 与数据体积正相关，字节数压缩 62% 带来显著成本降低
5. 当值占满 32 字节时，BBC 反而多 1 字节——但这在 MEV 交易中极少发生

---

## 第八部分：综合实战——还原 BytesCalldata 链上演示

> **本节解决什么问题**：用前七部分的所有知识，完整追踪一笔真实 Sepolia 测试网交易的执行过程——从 69 字节原始 calldata 到最终的外部调用，逐操作码串联所有知识点。

### 交易信息

- **TX Hash**: `0xfa7c1148959fa690d78feef8e8257c152471739deaf87c29ef0806556483a75c`
- **链**: Sepolia 测试网
- **目标合约**: LotusRouter (`0xA228997434E295D6e50B77a6E052c461D9AcaE99`)
- **交易设计**: 一笔交易包含 2 条 `DynCall` 指令，各携带不同的 `BytesCalldata`

### 原始 Calldata（69 字节）

```
19ff8034 0b0014c1b083caad204572f0f25ce26c4f5364fd47070d0000000004cafebabe
         0b0014c1b083caad204572f0f25ce26c4f5364fd47070d000000000548656c6c6f
```

### 第一步：Selector 路由（第二部分知识）

```
calldata[0x00:0x03] = 19ff8034 → msg.sig = 0x19ff8034
```

`findPtr()`（`PayloadPointer.sol:34-48`）匹配 `takeAction`，返回 `Ptr.wrap(0x04)`。

- **知识点**：selector = keccak256("takeAction()") 的前 4 字节
- **验证**：`cast sig "takeAction()"` → `0x19ff8034`

### 第二步：读取第一条 Action（第四部分 — CALLDATALOAD + SHR）

```solidity
// PayloadPointer.sol:67-71
action := shr(0xf8, calldataload(ptr))  // ptr = 0x04
ptr := add(ptr, 0x01)                   // ptr → 0x05
```

256-bit 展开：

```
calldataload(0x04):

0B0014C1 B083CAAD 204572F0 F25CE26C 4F5364FD 47070D00 00000004 CAFEBABE
^^ Action 字节

shr(248):

00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000000B
                                                                    ^^
                                                                    = 11 = Action.DynCall
```

- **知识点**：`shr(0xf8, ...)` 提取高 1 字节（第四部分 SHR 示例 2）

### 第三步：BBC 解码指令 1（第七部分 — 三种编码模式）

进入 `BBCDecoder.decodeDynCall`（`BBCDecoder.sol:688-723`），从 `ptr = 0x05` 开始：

#### 3a. canFail（固定 1 字节模式）

```
calldata[0x05] = 00 → canFail = false
ptr → 0x06
```

#### 3b. target（可变长度静态值模式）

```
calldata[0x06] = 14 → byteLen = 20
bitShift = 256 - 8 × 20 = 96

calldata[0x07:0x1a] = c1b083caad204572f0f25ce26c4f5364fd47070d (20 字节)
```

256-bit 展开：

```
calldataload(0x07):

C1B083CA AD204572 F0F25CE2 6C4F5364 FD47070D 00000000 04CAFEBA BE0B0014
^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^
             20 字节目标地址                  [后续 calldata 内容]

shr(96):

00000000 00000000 00000000 C1B083CA AD204572 F0F25CE2 6C4F5364 FD47070D
                           ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^
                                    target = Echo 合约地址
```

```
ptr → 0x1b (0x07 + 20)
```

- **知识点**：三步解码模式（第四部分 SHR 示例 3、第七部分模式 2）

#### 3c. value（零值优化）

```
calldata[0x1b] = 00 → byteLen = 0 → value = 0
ptr → 0x1c
```

- **知识点**：`byteLen = 0` 表示零值（第七部分模式 2 零值特殊处理）

#### 3d. data（动态字节数据模式）

```
calldata[0x1c:0x1f] = 00000004 → dataLen = 4

data := 0x1c   ← BytesCalldata₁（仅记录偏移量，零 memory 操作）

ptr → 0x20 (0x1c + 4)     ← 跳过 uint32 length
ptr → 0x24 (0x20 + 4)     ← 跳过 4 字节 data body
```

- **知识点**：`BytesCalldata` 是 lazy pointer（第七部分模式 3）

### 第四步：dynCall 消费 BytesCalldata₁（第五部分 + 第六部分）

`dynCall`（`Dyn.sol:6-18`）消费 `BytesCalldata data = 0x1c`：

```solidity
let fmp := mload(0x40)                          // 读 fmp

let dataLen := shr(0xe0, calldataload(data))     // calldataload(0x1c)
// calldataload(0x1c) 的高 4 字节 = 00000004
// shr(224, 0x00000004...) = 4

data := add(data, 0x04)                          // data → 0x20

calldatacopy(fmp, data, dataLen)                 // 从 calldata[0x20] 复制 4 字节到 memory[fmp]
// memory[fmp:fmp+4] = CAFEBABE

success := call(gas(), target, value, fmp, dataLen, 0x00, 0x00)
// call(gas(), Echo, 0, fmp, 4, 0, 0)
// → 发送 0xCAFEBABE 给 Echo
```

Memory 布局（call 前）：

```
偏移     内容          说明
──────   ──────────    ──────
fmp      CAFEBABE      calldatacopy 的产物
```

Echo 合约收到 `msg.data = 0xcafebabe`，emit `Called(LotusRouter, 0, 0xcafebabe)` ✓

- **知识点**：calldatacopy 将 calldata 数据复制到 memory（第四部分操作码 3）；call 7 参数的"无返回值"模式（第六部分模式 A）

### 第五步：读取第二条 Action + BBC 解码指令 2

`ptr = 0x24`，流程与步骤 2-3 完全相同：

```
calldata[0x24] = 0B → Action.DynCall
ptr → 0x25

canFail = 00 (false),  ptr → 0x26
target byteLen = 14 (20),  ptr → 0x27
target = c1b083caad204572f0f25ce26c4f5364fd47070d (Echo),  ptr → 0x3b
value byteLen = 00 → value = 0,  ptr → 0x3c
data length = 00000005 → dataLen = 5
BytesCalldata₂ = 0x3c,  ptr → 0x45
```

### 第六步：dynCall 消费 BytesCalldata₂

```solidity
let dataLen := shr(0xe0, calldataload(0x3c))    // = 5
data := add(0x3c, 0x04)                          // = 0x40
calldatacopy(fmp, 0x40, 5)                       // memory[fmp:fmp+5] = 48656c6c6f = "Hello"
success := call(gas(), Echo, 0, fmp, 5, 0, 0)
```

Echo 收到 `msg.data = 0x48656c6c6f`（= ASCII "Hello"），emit `Called(LotusRouter, 0, 0x48656c6c6f)` ✓

### 第七步：隐式 Halt（calldata 耗尽）

```
ptr = 0x45 = calldata 末尾（总长 69 = 0x45 字节）

calldataload(0x45) → 全零（超出 calldata 范围，右侧零填充）
shr(0xf8, 0) = 0 = Action.Halt
```

LotusRouter 执行 `stop()`，交易成功终止。

- **知识点**：calldataload 超出范围返回全零（第四部分操作码 2 的边界行为）

### Gas 效率总结

```
69 字节 BBC calldata → 2 次 DynCall → 2 次 Echo 调用
等效 ABI:            → 2 次独立的 dynCall(address,uint256,bytes)
                        = 2 × (4 + 3×32 + 32 + 32 + data) ≈ 328 字节
```

| 维度 | BBC (本交易) | 等效标准 ABI |
|------|-------------|-------------|
| Calldata 大小 | 69 字节 | ~328 字节 |
| 压缩率 | **~79% 节省** | 基准 |
| 数据复制次数 | 1 次/指令 (calldatacopy) | 2 次/指令 (ABI decode + re-encode) |
| Gas Used | 30,801 | — |

### 知识点串联地图

```
第二部分  selector 路由        → findPtr() 确定 BBC payload 起始位置
第四部分  CALLDATALOAD + SHR   → 逐字节读取 Action 和 BBC 字段
第七部分  BBC 三种模式          → 固定1B / byteLen+值 / uint32+data
第四部分  SIGNEXTEND           → (本例未用到，V3 swap 场景需要)
第五部分  Memory 构造          → calldatacopy 将 BytesCalldata 数据写入 memory
第六部分  call 7 参数          → call(gas(), target, value, fmp, len, 0, 0)
第四部分  零填充边界行为        → calldata 耗尽 → calldataload 返回 0 → Action.Halt
第三部分  ABI 编码             → (对比基准：同样的操作需要 ~328 字节)
```

### 本节要点

1. 69 字节 BBC calldata 包含了完整的 2 条 DynCall 指令 + 隐式 Halt，等效 ABI 需要 ~328 字节
2. `BytesCalldata` 的完整生命周期：BBCDecoder 产出 uint32 偏移量 → LotusRouter 透传 → 消费端 calldatacopy → call
3. 隐式 Halt 是零成本的终止机制——利用 calldataload 超出范围返回零的 EVM 行为
4. 全部 8 个部分的知识点在一笔真实交易中得到串联验证
