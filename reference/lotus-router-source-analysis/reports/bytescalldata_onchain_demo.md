# BytesCalldata 链上演示 — Sepolia 交易逐字节分析

> 本文通过一笔真实的 Sepolia 测试网交易，追踪两个 `BytesCalldata` 实例从 BBC 编码 → lazy pointer → `calldatacopy` → 外部调用的完整生命周期。所有数据可在 Etherscan 上独立验证。

---

## 部署信息

| 合约 | 地址 | Etherscan |
|------|------|-----------|
| LotusRouter | `0xA228997434E295D6e50B77a6E052c461D9AcaE99` | [已验证源码](https://sepolia.etherscan.io/address/0xa228997434e295d6e50b77a6e052c461d9acae99#code) |
| Echo | `0xc1B083caad204572f0f25ce26c4f5364Fd47070D` | [已验证源码](https://sepolia.etherscan.io/address/0xc1b083caad204572f0f25ce26c4f5364fd47070d#code) |

Echo 合约极简：任何调用都原样 `emit Called(caller, value, data)`，用于捕获 LotusRouter 经由 `BytesCalldata` 传递的数据。

```solidity
contract Echo {
    event Called(address indexed caller, uint256 value, bytes data);
    fallback() external payable { emit Called(msg.sender, msg.value, msg.data); }
    receive() external payable { emit Called(msg.sender, msg.value, ""); }
}
```

---

## 演示交易

**TX Hash**: [`0xfa7c1148959fa690d78feef8e8257c152471739deaf87c29ef0806556483a75c`](https://sepolia.etherscan.io/tx/0xfa7c1148959fa690d78feef8e8257c152471739deaf87c29ef0806556483a75c)

**交易设计**：一笔交易包含两条 `DynCall` 指令，各自携带不同的 `BytesCalldata` 数据。指令执行完毕后，calldata 耗尽，`calldataload` 返回 0，等于 `Action.Halt`，交易成功终止。

---

## 1. Calldata 逐字节解析

交易 input 共 69 字节，完整十六进制：

```
19ff8034 0b0014c1b083caad204572f0f25ce26c4f5364fd47070d0000000004cafebabe
         0b0014c1b083caad204572f0f25ce26c4f5364fd47070d000000000548656c6c6f
```

逐字段拆解：

```
偏移   字节                                       含义
─────  ─────────────────────────────────────────  ─────────────────────────────────
0x00   19ff8034                                   selector: takeAction()
                                                  findPtr() → Ptr.wrap(0x04)
       ┌──── 指令 1: DynCall(Echo, 0, 0xCAFEBABE) ────┐
0x04   0b                                         Action.DynCall (opcode 11)
0x05   00                                         canFail = false
0x06   14                                         target byteLen = 20
0x07   c1b083caad204572f0f25ce26c4f5364fd47070d   target = Echo 合约地址
0x1b   00                                         value byteLen = 0 → value = 0
0x1c   00000004                                   ★ BytesCalldata₁ 长度前缀 (uint32)
0x20   cafebabe                                   ★ BytesCalldata₁ 数据体 (4 bytes)
       └────────────────────────────────────────────────┘

       ┌──── 指令 2: DynCall(Echo, 0, "Hello") ────────┐
0x24   0b                                         Action.DynCall (opcode 11)
0x25   00                                         canFail = false
0x26   14                                         target byteLen = 20
0x27   c1b083caad204572f0f25ce26c4f5364fd47070d   target = Echo 合约地址
0x3b   00                                         value byteLen = 0 → value = 0
0x3c   00000005                                   ★ BytesCalldata₂ 长度前缀 (uint32)
0x40   48656c6c6f                                 ★ BytesCalldata₂ 数据体 = "Hello"
       └────────────────────────────────────────────────┘

0x45   (calldata 结束)                            calldataload → 0 → Action.Halt → stop()
```

---

## 2. BytesCalldata 指针追踪

### 指令 1：BytesCalldata₁ = `uint32(0x1c)`

**阶段一：BBCDecoder 产出**（`BBCDecoder.decodeDynCall`，从 ptr=0x05 开始）

解码器逐字段推进指针：canFail(0x05) → target(0x07-0x1a) → value(0x1b)。到达 `data` 字段时：

```solidity
// BBCDecoder.sol 第 716-722 行
nextByteLen := shr(u32Shr, calldataload(0x1c))    // 读 4 字节: 0x00000004 → dataLen=4
data := 0x1c                                      // ★ BytesCalldata₁ = 0x1c
nextPtr := add(0x1c, 0x04)                        // 跳过 length → 0x20
nextPtr := add(0x20, 4)                           // 跳过 data body → 0x24
```

`data` 只记录了一个偏移量 `0x1c`。**零 memory 操作，零数据复制。**

**阶段二：dynCall 消费**（`Dyn.sol:6-18`）

```solidity
// data = BytesCalldata₁ = 0x1c
let dataLen := shr(0xe0, calldataload(0x1c))    // 读 calldata[0x1c:0x1f] → 4
data := add(0x1c, 0x04)                         // data 指针跳到 0x20 (数据体起始)
calldatacopy(fmp, 0x20, 4)                      // ★ 从 calldata[0x20] 复制 4 字节到 memory
success := call(gas(), echo, 0, fmp, 4, 0, 0)   // 用 memory 中的 0xCAFEBABE 调用 Echo
```

**链上验证**：Echo 合约 emit `Called(caller=LotusRouter, value=0, data=0xcafebabe)` ✓

### 指令 2：BytesCalldata₂ = `uint32(0x3c)`

**阶段一：BBCDecoder 产出**（ptr 从 0x25 开始）

同样的解码过程，到达 `data` 字段：

```solidity
data := 0x3c                                      // ★ BytesCalldata₂ = 0x3c
```

**阶段二：dynCall 消费**

```solidity
let dataLen := shr(0xe0, calldataload(0x3c))    // 读 calldata[0x3c:0x3f] → 5
data := add(0x3c, 0x04)                         // data 指针跳到 0x40
calldatacopy(fmp, 0x40, 5)                      // ★ 从 calldata[0x40] 复制 5 字节到 memory
success := call(gas(), echo, 0, fmp, 5, 0, 0)   // 用 memory 中的 "Hello" 调用 Echo
```

**链上验证**：Echo 合约 emit `Called(caller=LotusRouter, value=0, data=0x48656c6c6f)` → ASCII `"Hello"` ✓

---

## 3. 执行 Trace（Forge 模拟输出）

```
[8817] LotusRouter::fallback{value: 0}(69 bytes BBC calldata)
  │
  ├─ [2330] Echo::fallback(0xcafebabe)          ← BytesCalldata₁ 经 calldatacopy 后的产物
  │   ├─ emit Called(caller: LotusRouter, value: 0, data: 0xcafebabe)
  │   └─ ← [Stop]
  │
  ├─ [2330] Echo::fallback(0x48656c6c6f)        ← BytesCalldata₂ 经 calldatacopy 后的产物
  │   ├─ emit Called(caller: LotusRouter, value: 0, data: 0x48656c6c6f)
  │   └─ ← [Stop]
  │
  └─ ← [Stop]                                   ← Action.Halt (calldata 耗尽)
```

整个交易只消耗 **8,817 gas**（不含 base fee 和 calldata gas）。LotusRouter 的 `fallback()` 无任何 Solidity 函数调度开销，`BytesCalldata` 的 lazy copy 确保每段动态数据只被复制一次。

---

## 4. Gas 效率对比

| 维度 | BBC 编码 (本交易) | 等效标准 ABI |
|------|-------------------|-------------|
| Calldata 大小 | 69 bytes | 328 bytes（2 × `dynCall(address,uint256,bytes)`） |
| 压缩率 | **79% 节省** | 基准 |
| 函数选择器 | 1 个 (takeAction) | 2 个 (每次 dynCall 各 1 个) |
| 数据复制次数 | 1 次/指令 (`calldatacopy`) | 2 次/指令 (ABI decode + ABI re-encode) |
| Gas Used | 30,801 | — |

BBC 编码的节省来自两个层面：

1. **紧凑 calldata**：地址编码为 1 字节前缀 + 20 字节数据 = 21 字节，而非 ABI 的 32 字节（省去 12 字节零填充 × 4 gas = 48 gas，新增 1 字节前缀 × 16 gas，净省 32 gas/地址）；零值完全省略（`value=0` 只需 1 字节长度前缀，而非 ABI 的 32 字节零填充）
2. **BytesCalldata lazy copy**：动态数据在 BBCDecoder 阶段零开销传递（只传一个 uint32 偏移量），直到 `dynCall`/`UniV2Pair.swap` 等消费端才通过 `calldatacopy` 做唯一一次复制

---

## 5. 关键观察

1. **BytesCalldata 就是一个 uint32 偏移量**。BytesCalldata₁ = `0x1c`，BytesCalldata₂ = `0x3c`——它们分别指向 calldata 中两段 BBC 动态数据的长度前缀起始位置。

2. **两个 BytesCalldata 共存于同一份 calldata**。它们只是不同的偏移值，指向同一份 `msg.data` 的不同区域。EVM 的 `calldataload` 可以随机读取 calldata 的任意位置，不需要顺序访问。

3. **数据复制只在消费端发生一次**。从 `BBCDecoder.decodeDynCall` 产出 `BytesCalldata` 到 `dynCall` 消费它之间，没有任何 memory 操作。`calldatacopy` 是整个流程中唯一的数据搬运操作。

4. **隐式 Halt 是零成本的终止机制**。calldata 末尾之后的 `calldataload` 自动返回 0，等于 `Action.Halt`（enum 值 0），无需显式编码终止标记。

---

## 复现方式

```bash
# 在 lotus-router/ 目录下
export PRIVATE_KEY=<your_sepolia_key>
export SEPOLIA_RPC_URL=<your_rpc_url>

forge script script/BytesCalldataDemo.s.sol:BytesCalldataDemo \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast -vvvv
```

---

*分析基于 Lotus Router 源码 (solc 0.8.28, via\_ir, optimizer\_runs=max) 部署在 Sepolia testnet (chain 11155111)*
