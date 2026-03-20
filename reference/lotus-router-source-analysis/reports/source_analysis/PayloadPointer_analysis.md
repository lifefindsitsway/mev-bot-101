# PayloadPointer.sol 源码分析

> 源文件：`lotus-router/src/types/PayloadPointer.sol`（75 行）

## 1. 文件定位：Lotus Router 的"读头"

PayloadPointer 是 Lotus Router 指令流解析的起点。整个 Lotus Router 的核心设计可以概括为：**用 calldata 承载一串紧凑编码的指令，通过一个循环逐条读取并执行**。PayloadPointer 负责的就是"确定从哪里开始读"和"读出下一条指令的操作码"这两件事。

在整体架构中的位置：

```
外部调用 calldata
    │
    ▼
findPtr()          ← 确定 payload 起始偏移量（PayloadPointer.sol）
    │
    ▼
┌─────────────────────────────────────────────┐
│  while (success) {                          │  LotusRouter.sol fallback()
│      (ptr, action) = ptr.nextAction();      │  ← 提取 1 字节操作码
│      ...                                    │
│      (ptr, ...) = BBCDecoder.decode*(ptr);  │  ← 解码变长参数
│      success = protocol.execute(...);       │  ← 执行协议操作
│  }                                          │
└─────────────────────────────────────────────┘
```

## 2. 核心数据结构

```solidity
type Ptr is uint256;
```

`Ptr` 是一个 Solidity **用户自定义类型（UDT）**，底层是 `uint256`，语义是 **calldata 中的字节偏移量**。它起到类似"文件指针"或"游标"的作用——指向 calldata 中当前待读取的位置。

通过 `using { nextAction } for Ptr global;`，`nextAction` 被绑定为 `Ptr` 的成员函数，使得主循环可以写出 `ptr.nextAction()` 这样的链式调用。

## 3. 四个入口选择器

```solidity
uint256 constant takeAction           = 0x19ff8034;  // takeAction()
uint256 constant uniswapV2Call        = 0x10d1e85c;  // uniswapV2Call(address,uint256,uint256,bytes)
uint256 constant uniswapV3SwapCallback = 0xfa461e33; // uniswapV3SwapCallback(int256,int256,bytes)
uint256 constant uniswapV3FlashCallback = 0xe9cbafb0; // uniswapV3FlashCallback(uint256,uint256,bytes)
```

这四个常量是 Lotus Router 支持的全部入口点的函数选择器。由于 LotusRouter 合约只有 `fallback()` 和 `receive()`，**任何带 calldata 的调用都会进入 fallback**。`findPtr()` 通过 `msg.sig` 判断调用者的意图，然后返回 payload 在 calldata 中的起始偏移。

### 选择器验证

```bash
$ cast sig "takeAction()"
0x19ff8034   ✓

$ cast sig "uniswapV2Call(address,uint256,uint256,bytes)"
0x10d1e85c   ✓

$ cast sig "uniswapV3SwapCallback(int256,int256,bytes)"
0xfa461e33   ✓

$ cast sig "uniswapV3FlashCallback(uint256,uint256,bytes)"
0xe9cbafb0   ✓
```

> **注意**：源码注释中（第 28 行）提到了 `callLotusRouter()` 这个名字，但实际使用的选择器对应的函数签名是 `takeAction()`（`0x19ff8034`）。这是一处注释与实现的命名不一致，`callLotusRouter()` 的选择器实际上是 `0xe7d751b5`。

## 4. `findPtr()` 详解——偏移量是怎么算出来的

`findPtr()` 是理解 PayloadPointer 的关键。它返回的偏移量不是随意选取的，而是由各入口点的 **ABI 编码结构** 严格决定的。

### 4.1 直接调用：`takeAction()` → offset `0x04`

这是最简单的情况。调用者直接用 `takeAction()` 的选择器构造 calldata：

```
calldata 布局：
┌──────────┬────────────────────────────────────┐
│ 0x00-03  │ selector: 0x19ff8034               │
├──────────┼────────────────────────────────────┤
│ 0x04 ... │ BBC 编码的指令流 payload            │
└──────────┴────────────────────────────────────┘
```

选择器占 4 字节，payload 紧随其后，所以偏移量是 `0x04`。

注意 `takeAction()` 的函数签名没有参数——payload 并不是通过 ABI 编码的 `bytes` 参数传入的，而是直接**裸拼接**在选择器后面。这样做绕过了 Solidity ABI 编码对 `bytes` 类型添加的 offset + length 前缀（额外消耗 64 字节 calldata = 至少 64 × 4 = 256 gas），是一种刻意的 gas 优化。

### 4.2 Uniswap V2 回调：`uniswapV2Call(address,uint256,uint256,bytes)` → offset `0xa4`

当 Lotus Router 调用 UniV2Pair.swap() 并传入非空 callback data 时，Pair 合约会回调 `uniswapV2Call`。此时 calldata 的布局由 Uniswap V2 的 ABI 编码决定：

```
calldata 布局（标准 ABI 编码）：
┌──────────┬─────────────────────────────────────────────────┐
│ 0x00-03  │ selector: 0x10d1e85c                           │
├──────────┼─────────────────────────────────────────────────┤
│ 0x04-23  │ address sender     （32 字节，左填充零）         │
│ 0x24-43  │ uint256 amount0    （32 字节）                  │
│ 0x44-63  │ uint256 amount1    （32 字节）                  │
│ 0x64-83  │ bytes data offset  （值 = 0x80，相对于 0x04）    │
├──────────┼─────────────────────────────────────────────────┤
│ 0x84-a3  │ bytes data length  （32 字节）                  │
│ 0xa4 ... │ bytes data content ← payload 从这里开始         │
└──────────┴─────────────────────────────────────────────────┘
```

推导过程：
- selector 占 4 字节 → 参数区从 `0x04` 开始
- 3 个静态参数（address + uint256 × 2）各占 32 字节 → `3 × 32 = 96 = 0x60`
- 第 4 个参数是动态类型 `bytes`，先存一个 offset 指针（32 字节）→ 累计 `4 × 32 = 128 = 0x80`
- offset 值 `0x80` 指向（从 `0x04` 起）`bytes` 的 length 字段 → length 位于 `0x04 + 0x80 = 0x84`
- length 占 32 字节 → 实际 data 内容从 `0x84 + 0x20 = 0xa4` 开始

**因此 `Ptr.wrap(0xa4)`。**

### 4.3 Uniswap V3 回调：`uniswapV3SwapCallback` / `uniswapV3FlashCallback` → offset `0x84`

V3 的两个回调签名分别是：
- `uniswapV3SwapCallback(int256, int256, bytes)`
- `uniswapV3FlashCallback(uint256, uint256, bytes)`

两者结构相同——2 个静态参数 + 1 个动态 `bytes`：

```
calldata 布局：
┌──────────┬──────────────────────────────────────────────────┐
│ 0x00-03  │ selector                                        │
├──────────┼──────────────────────────────────────────────────┤
│ 0x04-23  │ int256/uint256 delta0/fee0  （32 字节）          │
│ 0x24-43  │ int256/uint256 delta1/fee1  （32 字节）          │
│ 0x44-63  │ bytes data offset（值 = 0x60，相对于 0x04）      │
├──────────┼──────────────────────────────────────────────────┤
│ 0x64-83  │ bytes data length  （32 字节）                   │
│ 0x84 ... │ bytes data content ← payload 从这里开始          │
└──────────┴──────────────────────────────────────────────────┘
```

推导：`selector(4) + 2×32(静态) + 32(offset) = 100 = 0x64` → length 在 `0x64`，data 在 `0x64 + 0x20 = 0x84`。

**因此 `Ptr.wrap(0x84)`。**

### 4.4 偏移量总结

| 入口 | 选择器 | 静态参数 | payload 偏移 | 来源 |
|------|--------|----------|-------------|------|
| `takeAction()` | `0x19ff8034` | 无 | `0x04` | 裸拼接，无 ABI 开销 |
| `uniswapV2Call(...)` | `0x10d1e85c` | 3 个 × 32B | `0xa4` | ABI 编码的 `bytes` 参数 |
| `uniswapV3SwapCallback(...)` | `0xfa461e33` | 2 个 × 32B | `0x84` | ABI 编码的 `bytes` 参数 |
| `uniswapV3FlashCallback(...)` | `0xe9cbafb0` | 2 个 × 32B | `0x84` | ABI 编码的 `bytes` 参数 |

### 4.5 `takeAction` 的使用方式

`takeAction` 在 `PayloadPointer.sol` 第 11 行定义的**不是函数**，而是一个选择器常量（`uint256 constant takeAction = 0x19ff8034`）。`0x19ff8034` 是函数签名 `takeAction()` 的 4 字节选择器。LotusRouter 合约没有名为 `takeAction` 的 Solidity 函数——这个选择器仅用于让 `findPtr()` 识别"这是一次直接调用"，从而将 payload 起始偏移设为 `0x04`。

调用方式见测试辅助函数（`LotusRouter.t.sol` 第 17-21 行）：

```solidity
function takeAction(LotusRouter lotus, bytes memory data) returns (bool success) {
    // 将选择器 0x19ff8034 和 BBC 编码的指令流用 encodePacked 裸拼接
    bytes memory payload = abi.encodePacked(uint32(0x19ff8034), data);
    // 用低级 call 发送（不走 ABI 编码）
    (success,) = address(lotus).call(payload);
}
```

核心要点：使用 `abi.encodePacked`（裸拼接），不用 `abi.encodeWithSelector`。这样 BBC 编码的指令流直接紧跟在 4 字节选择器后面，中间没有 ABI 的 offset/length 开销。

### 4.6 链上交易实例：Sepolia 两条 DynCall 指令

以 Sepolia 链上真实交易 [`0xfa7c1148...`](https://sepolia.etherscan.io/tx/0xfa7c1148959fa690d78feef8e8257c152471739deaf87c29ef0806556483a75c) 为例。该交易由 `BytesCalldataDemo.s.sol` 脚本生成，包含两条 `DynCall` 指令，调用部署在 `0xc1B0...070D` 的 Echo 合约。

**calldata 构造**（`BytesCalldataDemo.s.sol` 第 54-78 行）：

```solidity
// 指令 1: DynCall(echo, 0, 0xCAFEBABE)
bytes memory instr1 = abi.encodePacked(
    uint8(0x0b),        // Action.DynCall (操作码)
    uint8(0x00),        // canFail = false
    uint8(0x14),        // target 的 byteLen = 20
    address(echo),      // target 地址 (20 字节，无 ABI 填充)
    uint8(0x00),        // value 的 byteLen = 0 (ETH value = 0)
    uint32(4),          // 动态数据长度前缀 = 4 字节
    hex"CAFEBABE"       // 动态数据内容
);
// 指令 2 结构相同，数据为 "Hello" (5 字节)

// 完整 calldata = 选择器 + 指令1 + 指令2
bytes memory fullCalldata = abi.encodePacked(TAKE_ACTION, instr1, instr2);
```

**链上 calldata 逐字节对照**（共 69 字节）：

```
偏移   字节                                       含义
─────  ─────────────────────────────────────────  ─────────────────────────────
0x00   19ff8034                                   ← takeAction 选择器
       ┌─── 指令 1: DynCall(Echo, 0, 0xCAFEBABE) ─────────┐
0x04   0b                                         Action.DynCall (opcode 11)
0x05   00                                         canFail = false
0x06   14                                         target byteLen = 20
0x07   c1b083caad204572f0f25ce26c4f5364fd47070d   target = Echo 地址
0x1b   00                                         value byteLen = 0 → value = 0
0x1c   00000004                                   动态数据长度 = 4
0x20   cafebabe                                   动态数据 = 0xCAFEBABE
       └───────────────────────────────────────────────────┘
       ┌─── 指令 2: DynCall(Echo, 0, "Hello") ────────────┐
0x24   0b                                         Action.DynCall
0x25   00                                         canFail = false
0x26   14                                         target byteLen = 20
0x27   c1b083caad204572f0f25ce26c4f5364fd47070d   target = Echo 地址
0x3b   00                                         value byteLen = 0
0x3c   00000005                                   动态数据长度 = 5
0x40   48656c6c6f                                 动态数据 = "Hello"
       └───────────────────────────────────────────────────┘
0x45   (calldata 结束)                            → calldataload 读到 0 → Halt
```

**fallback 执行流**：

```
address(router).call(fullCalldata)
       │
       ▼
LotusRouter.fallback()
       │
       ├─ (1) findPtr(): msg.sig == 0x19ff8034 == takeAction → Ptr(0x04)
       │
       ├─ (2) nextAction(): calldata[0x04] = 0x0b → Action.DynCall, ptr = 0x05
       │
       ├─ (3) BBCDecoder.decodeDynCall(ptr=0x05):
       │       canFail  = calldata[0x05] = 0x00 (false)
       │       target   = calldata[0x07..0x1a] = Echo 地址 (byteLen=0x14)
       │       value    = 0 (byteLen=0x00)
       │       data     = BytesCalldata(0x1c)  ← 仅记录偏移量
       │       nextPtr  = 0x24
       │
       ├─ (4) dynCall(echo, 0, BytesCalldata(0x1c)):
       │       dataLen = shr(0xe0, calldataload(0x1c)) = 4
       │       calldatacopy(memory, 0x20, 4) → memory = [CAFEBABE]
       │       call(echo) → Echo emit Called(data=0xcafebabe) ✓
       │
       ├─ (5) nextAction(): calldata[0x24] = 0x0b → Action.DynCall, ptr = 0x25
       │
       ├─ (6) decodeDynCall(ptr=0x25): data = BytesCalldata(0x3c), nextPtr = 0x45
       │
       ├─ (7) dynCall(echo, 0, BytesCalldata(0x3c)):
       │       calldatacopy(memory, 0x40, 5) → memory = [48656c6c6f]
       │       call(echo) → Echo emit Called(data="Hello") ✓
       │
       ├─ (8) nextAction(): calldata[0x45] → 超出末尾，calldataload 返回 0
       │       shr(0xf8, 0) = 0x00 = Action.Halt
       │
       └─ (9) stop() → 交易成功终止
```

这个实例展示了 `takeAction` 选择器的完整工作机制：它告诉 `findPtr()` "指令流从偏移 `0x04` 开始"，使得 BBC 编码的指令流直接紧跟在 4 字节选择器之后，calldata 开销最低。脚本作者有意利用了 calldata 耗尽时 `calldataload` 零填充产生隐式 `Halt` 的行为（`BytesCalldataDemo.s.sol` 第 52 行注释明确标注了这一设计意图）。

## 5. `nextAction()` 详解——1 字节操作码提取

```solidity
function nextAction(Ptr ptr) pure returns (Ptr, Action action) {
    assembly {
        action := shr(0xf8, calldataload(ptr))
        ptr := add(ptr, 0x01)
    }
    return (ptr, action);
}
```

### 逐行拆解

**`calldataload(ptr)`**：从 calldata 的 `ptr` 偏移处加载 32 字节到栈上。EVM 的 `CALLDATALOAD` 总是读取 32 字节，即使我们只需要 1 字节。

**`shr(0xf8, ...)`**：右移 248 位（`0xf8 = 248`）。32 字节 = 256 位，右移 248 位后只剩最高的 8 位（1 字节），其余全部清零。这就提取出了 ptr 位置的第一个字节。

**`ptr := add(ptr, 0x01)`**：指针前进 1 字节，指向下一个待读取位置。

### 示例

假设 calldata 在 `ptr=0x04` 处的 32 字节是：

```
0x 01 00 14 ab cd ef ... (后续字节)
   ^^
   这是 ptr 指向的第一个字节
```

- `calldataload(0x04)` = `0x010014abcdef...000000`（256-bit 值）
- `shr(0xf8, ...)` = `0x01`
- 这个 `0x01` 对应 `Action.SwapUniV2`（Action 枚举从 0 开始，`Halt=0, SwapUniV2=1, ...`）
- 返回 `ptr = 0x05`，指向参数区的起始位置

### 返回值的双重语义

`nextAction` 同时返回**新指针**和**操作码**。这种"消费一个 token 并推进游标"的模式，与编译器前端的 lexer / tokenizer 完全同构。每次调用消耗 1 字节，返回的 `ptr` 直接交给 BBCDecoder 继续解码该指令的参数。

## 6. 与 BBCDecoder 的协作关系

`nextAction` 读出 1 字节操作码后，`ptr` 指向该指令的参数区。接下来由 `BBCDecoder.decode*()` 接手：

```
nextAction 消耗 1 字节:
  ┌──┬─────────────────────────────────┐
  │01│ 00 14 ab cd ... (参数)   │ 02 ...│
  └──┴─────────────────────────────────┘
   ^   ^                         ^
   │   │                         │
   │   └── ptr 交给 BBCDecoder    └── nextPtr 返回给 nextAction
   └── action = SwapUniV2
```

BBCDecoder 中每个 decode 函数接收 `Ptr ptr`，逐字段消费参数（采用 BBC 编码，见下文），最后返回 `Ptr nextPtr`，指向下一条指令的操作码位置。这样 `nextAction` 和 `decode*` 交替执行，形成一个完整的**指令流解析循环**。

### BBC 编码中参数的读取模式

BBCDecoder 对参数的读取分三种情况（参见 `BBCDecoder.sol` 第 17-30 行注释）：

**≤ 8 位的静态参数**（如 `canFail`、`zeroForOne`）：原地编码

```
[1 字节 value]
```

直接读取 1 字节即为参数值，无长度前缀。对应代码模式：

```yul
canFail := shr(0xf8, calldataload(nextPtr))
nextPtr := add(nextPtr, 0x01)
```

**9-256 位的静态参数**（地址、金额等）：长度前缀编码

```
[1 字节 byteLen] [byteLen 字节的实际值]
```

读取流程：
1. 读 1 字节得到 `byteLen`（比如 `0x14` = 20，表示这是一个 20 字节的地址）
2. 计算 `bitShift = 256 - 8 × byteLen`（用于右移对齐）
3. 读 32 字节并右移 `bitShift` 位，提取出实际值
4. 指针前进 `byteLen` 字节

**动态参数**（`bytes` 类型数据）：4 字节长度前缀

```
[4 字节 dataLen] [dataLen 字节的实际数据]
```

此时 BBCDecoder 将**当前 ptr 位置**直接包装为 `BytesCalldata` 类型返回（不做数据拷贝），指针跳过 `4 + dataLen` 字节。后续由协议处理函数用 `calldatacopy` 按需读取。

## 7. 递归回调机制——同一份 payload 的嵌套执行

这是 PayloadPointer 设计中最精妙的部分。考虑一个典型的 MEV 三明治攻击场景：

1. Searcher 调用 `takeAction()` → 发起 V2 swap，callback data 包含后续指令
2. V2 Pair 回调 `uniswapV2Call()` → `findPtr()` 返回 `0xa4`，从 callback data 中继续解析指令
3. 在回调中可能再发起 V3 swap，V3 Pool 回调 `uniswapV3SwapCallback()` → `findPtr()` 又返回 `0x84`

```
takeAction() calldata:
┌──────────┬───────┬──────────────────────────────────────────────┐
│ selector │ instr │ SwapV2 params ... │ data = [嵌套指令流]       │
└──────────┴───────┴──────────────────────────────────────────────┘
                                          │
                                          ▼ Pair 回调
                                   uniswapV2Call() calldata:
                                   ┌──────────┬─────────────┬─────────────────┐
                                   │ selector │ ABI params  │ data = [指令流]  │
                                   └──────────┴─────────────┴────┬────────────┘
                                                                 │
                                                                 ▼ 0xa4 处开始解析
```

**关键洞察**：`findPtr()` 不关心"谁调用了我"或"这是第几层嵌套"，它只看 `msg.sig`——当前这次调用的函数选择器。这使得同一个 `fallback()` 可以在任意嵌套深度正确定位 payload，实现了**无状态的递归指令执行**。合约不需要任何 storage 变量来追踪执行状态。

## 8. 疑难点分析

### 8.1 `msg.sig` 被强制转换为 `uint256` 的原因

```solidity
uint256 selector = uint256(uint32(msg.sig));
```

`msg.sig` 的类型是 `bytes4`。这里使用了双重转换 `bytes4 → uint32 → uint256`，原因有二：

1. **Solidity 类型系统要求**：Solidity 0.8.x 不允许 `bytes4` 直接转 `uint256`，必须经过 `uint32` 作为中间类型
2. **确保右对齐**：`bytes4 → uint32` 将 4 字节重新解释为一个整数值，再 `uint32 → uint256` 零扩展到 256 位，结果是 `0x0000...19ff8034`（低位对齐）。这与顶部定义的 `uint256` 常量（如 `0x19ff8034`）在数值上一致。如果走 `bytes32` 路径（`uint256(bytes32(msg.sig))`），得到的会是 `0x19ff8034000...000`（高位对齐），与常量不匹配

### 8.2 `calldataload` 的越界行为

`calldataload(ptr)` 在 `ptr + 32 > calldatasize` 时不会 revert，而是**自动用零填充**不足的部分（这是 EVM 规范定义的行为，不是 Lotus Router 的设计选择）。这带来两个后果：

- 如果 payload 编码错误（比如截断了一条指令的参数），`calldataload` 会默默读到零值而不报错，可能导致静默的逻辑错误
- 理论上，calldata 在指令流末尾恰好耗尽时，`calldataload` 读到全零 → `shr(0xf8, 0) = 0x00 = Action.Halt` → 执行 `stop()`，相当于隐式终止。但没有证据表明 off-chain 编码器依赖这一行为——编码器大概率总是显式编码一个 `0x00`（Halt）字节

合约不做 calldata 长度的边界检查，这与 MEV 场景的信任模型一致：calldata 由 searcher 自己的 off-chain 系统构造，不需要防御外部输入。

### 8.3 `takeAction()` 无参数签名的 gas 考量

`takeAction()` 没有参数，但实际上通过 calldata 传递了任意长度的 payload。这绕过了 Solidity 标准 ABI 对 `bytes` 参数的编码开销：

| 方案 | calldata 布局 | 额外开销 |
|------|--------------|---------|
| `takeAction(bytes calldata data)` | selector + offset(32B) + length(32B) + data | 64 字节 |
| `takeAction()` 裸拼接 | selector + data | 0 字节 |

这 64 字节的 gas 成本（每个非零字节 16 gas，零字节 4 gas）：
- offset 字段（`0x0000...0020`）：31 个零字节 + 1 个非零字节 = `31×4 + 1×16 = 140 gas`
- length 字段：取决于 payload 长度，假设 payload 100 字节（`0x0000...0064`），同样约 140 gas
- 合计约 **280 gas 的节省**

在 MEV 场景中，每笔交易的利润空间可能只有几美元，数百 gas 的差距在高频执行中会累积成显著成本。

### 8.4 为什么不用 `switch` 而用 `if-else`

`findPtr()` 用的是 Solidity 层面的 `if-else if` 而不是 Yul 的 `switch`。原因很直接：`findPtr()` 不在 `assembly` 块中——它是一个纯 Solidity 的自由函数，而 `switch` 是 Yul 关键字，只能在 `assembly { }` 块内使用。在 Solidity 层面，`if-else if` 是唯一的选择。

### 8.5 `pure` 修饰符的正确性

`findPtr()` 和 `nextAction()` 都标记为 `pure`，这看起来奇怪——它们读取了 `msg.sig` 和 calldata，这算不算"读取状态"？

在 Solidity 的语义中，`msg.sig` 和 `calldataload` 访问的是**交易输入数据**，不是链上状态（storage）或区块环境变量（block.timestamp 等）。它们属于"纯计算"范畴——给定相同的输入 calldata，输出永远相同。因此 `pure` 是正确的。

### 8.6 自由函数（free function）而非 library

`findPtr()` 和 `nextAction()` 定义为**自由函数**（file-level function），不属于任何 contract 或 library。自由函数在 Solidity 0.7.1 引入，而 `using ... for ... global` 语法在 Solidity 0.8.13 引入。

选择自由函数而非 library 的关键原因是**语法需求**：
- 只有自由函数才能通过 `using { nextAction } for Ptr global;` 绑定到 UDT 上，使 `ptr.nextAction()` 的链式调用成为可能。library 的 internal 函数无法做到这一点
- 编译为 `internal` 调用，直接内联到调用处（注意：library 的 `internal` 函数同样会被内联，两者在编译层面没有本质区别）
- 代码组织更清晰——类型定义（`Ptr`）和操作函数（`nextAction`）在同一个文件中

### 8.7 Action 枚举的值域

Action 枚举定义了 12 个值（`Halt=0` 到 `DynCall=11`）。`nextAction` 提取 1 字节可以表示 0-255 的范围，但 LotusRouter.sol 的 fallback 中，如果 action 值不匹配任何已知的 Action，会走到最后的 `else` 分支设置 `success = false`，然后循环退出并 revert。

这意味着**未知操作码会导致整个交易回滚**，不会被静默跳过。

## 9. 与 AttackContract 的对比

在 AttackContract 的逆向分析中，攻击合约也采用了 calldata 驱动的指令引擎模式（12 个 opcode，0x00-0x0b），但入口路由的实现有显著差异：

| 特性 | Lotus Router（PayloadPointer） | AttackContract |
|------|-------------------------------|----------------|
| 操作码数量 | 12 个（Halt=0 到 DynCall=11） | 12 个（0x00-0x0b） |
| 入口点设计 | 4 个选择器，`findPtr()` 统一路由 | 45 个 dispatch selectors，按回调类型分派到多个 handler 函数（`_handleUintCb`、`_handleIntCb` 等） |
| 参数编码 | BBC 长度前缀编码（BigBrainChad 方案） | 自定义紧凑编码 |
| 回调种类 | 3 种（V2 callback + V3 swap/flash callback） | 6+ 种（V2/V3 flash、V3 swap、Morpho、Balancer、Aave V3 等） |
| 代码组织 | 自由函数 + UDT + library，关注点分离 | 逆向重建，800+ 行单文件 |

Lotus Router 的 PayloadPointer 设计更加模块化——入口点识别（`findPtr`）、操作码提取（`nextAction`）、参数解码（`BBCDecoder`）各自独立为不同文件。AttackContract 面向更复杂的多协议攻击场景，支持的回调种类远多于 Lotus Router，通过 45 个 selector 路由到不同的内部 handler 函数。

## 10. 总结

PayloadPointer.sol 只有 75 行代码，但它在 Lotus Router 架构中扮演着**指令解析入口**的关键角色：

1. **`Ptr` 类型**：将 `uint256` 的语义从"数字"提升为"calldata 游标"，通过 UDT 实现类型安全
2. **`findPtr()`**：根据函数选择器确定指令流的起始偏移，抽象掉 ABI 编码差异，使主循环对入口点透明
3. **`nextAction()`**：用一次 `calldataload` + `shr` 提取 1 字节操作码并推进游标，是整个指令循环的驱动力
4. **递归无状态**：依赖 `msg.sig` 而非 storage 来定位 payload，天然支持回调嵌套
5. **Gas 极致优化**：`takeAction()` 无参数签名省去 ABI 编码开销，`calldataload` 是 EVM 中最廉价的数据读取操作之一（3 gas）
