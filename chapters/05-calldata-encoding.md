# 第 5 篇：Calldata 压缩编码 —— 三套方案的工程权衡

在第 4 篇中，我们看到 Lotus Router 的 `BBCDecoder` 从 calldata 中逐字节解码参数——地址前面有一个长度前缀，金额也有一个长度前缀。这种编码方式和 Solidity 标准的 ABI 编码完全不同。为什么 MEV 路由合约要费力自定义编码格式？

答案藏在一个简单的 gas 定价规则里。

## 为什么要压缩 Calldata

以太坊对交易 calldata 的收费规则很直接：

- **非零字节**：每字节 16 gas
- **零字节**：每字节 4 gas

这意味着 calldata 的每一个字节都有成本。标准 Solidity ABI 编码将所有值对齐到 32 字节——一个 20 字节的地址会被填充 12 字节的前导零，一个值为 `1` 的 uint256 会被填充 31 字节的前导零。这些零字节虽然只收 4 gas，但积少成多。

以 AttackContract 的 Base 链 Moonwell 攻击为例：每笔交易的 calldata 是 932 字节。如果用标准 ABI 编码所有参数，calldata 可能超过 2000 字节。在 175-253 gwei 的 gas price 下，多出的 1000+ 字节意味着数万 gas 的额外成本——按当日价格，可能是几十美元。对于需要在极短时间窗口内执行 12 笔交易的攻击者来说，每笔交易节省的 gas 乘以 12 就是可观的金额。

但 calldata 压缩不只是省钱。更短的 calldata 意味着更快的广播和更小的区块占用，在 gas 竞争激烈的 MEV 场景下，这些微小的优势可能是决定成败的边际因素。

本篇对比三种编码方案：Lotus Router 的 BBC 长度前缀编码、AttackContract 的固定宽度编码和标准 ABI 编码，展示三者在字节级别的差异和工程取舍。

## 方案 C（基线）：标准 ABI 编码

先看我们最熟悉的标准方案。Solidity ABI 编码的核心规则是**32 字节对齐**：

```
ABI 编码一个 V2 swap 调用：swap(uint256, uint256, address, bytes)

022c0d9f                                                          ← 4B selector
0000000000000000000000000000000000000000000000000de0b6b3a7640000  ← 32B amount0Out
0000000000000000000000000000000000000000000000000000000000000000  ← 32B amount1Out (=0)
000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266  ← 32B to (address)
0000000000000000000000000000000000000000000000000000000000000080  ← 32B data offset
0000000000000000000000000000000000000000000000000000000000000008  ← 32B data length
6465616462656566000000000000000000000000000000000000000000000000  ← 32B data + padding

合计：4 + 32×6 = 196 字节（仅 swap 调用的 calldata）
```

注意有多少空间被浪费了：

- `amount0Out`（1 ETH = `0x0de0b6b3a7640000`）实际只有 8 字节有效数据，但用了 32 字节
- `amount1Out` 是 0，但仍占 32 字节
- `to`（一个 20 字节地址）被填充了 12 字节零

如果加上 Lotus Router 需要编码的完整 `SwapUniV2` 操作（包含 pair 地址和 canFail 标志），ABI 编码需要 **288 字节**。

## 方案 A：Lotus Router "BBC 长度前缀"编码

BBC（Big Brain Chad）编码的核心思想：**用 1 字节长度前缀告诉解码器"接下来的有效数据有多长"，然后只存储去掉前导零后的紧凑值**。

同一个 V2 swap 操作的 BBC 编码：

```
01                                        ← 1B Action = SwapUniV2
00                                        ← 1B canFail = false
14                                        ← 1B pair 长度 = 20 字节
b4e16d0168e52d35cacd2c6185b44281ec28c9dc  ← 20B pair 地址（无填充）
08                                        ← 1B amount0Out 长度 = 8 字节
0de0b6b3a7640000                          ← 8B amount0Out（去前导零）
00                                        ← 1B amount1Out 长度 = 0（值为零，不占空间）
14                                        ← 1B to 长度 = 20 字节
f39fd6e51aad88f6f4ce6ab8827279cfffb92266  ← 20B to 地址
00000008                                  ← 4B data 长度（动态类型用 4 字节前缀）
6465616462656566                          ← 8B data 内容

合计：66 字节
```

**288 字节 → 66 字节，压缩 77%。**

BBC 编码的三条规则：

| 类型 | 编码方式 | 示例 |
|------|---------|------|
| 8 位及以下（bool 等） | 直接 1 字节，无长度前缀 | `canFail = false` → `00` |
| 9-256 位（address, uint256 等） | `[1B byte_len_u8] [byte_len 字节数据]` | `address(20B)` → `14` + 20 字节 |
| 动态类型（bytes） | `[4B byte_len_u32] [数据]` | `8 字节 data` → `00000008` + 8 字节 |

当值为零时，`byte_len = 0`，不需要后续数据——一个零值 uint256 只花 1 字节（长度前缀 `00`），而 ABI 编码需要 32 字节。

### BBCDecoder：三行汇编的解码模式

Lotus Router 的 `BBCDecoder.sol`（约 725 行纯内联汇编）中，所有参数的解码都遵循同一个模式。以解码一个地址为例：

```solidity
// BBCDecoder.sol — 解码地址的核心汇编
assembly {
    // 第 1 步：读取长度前缀
    nextByteLen := shr(0xf8, calldataload(nextPtr))
    // calldataload 读 32 字节，shr(248) 取最高 1 字节 → 得到 byte_len

    // 第 2 步：计算位移量
    nextBitShift := sub(0x0100, mul(0x08, nextByteLen))
    // bitShift = 256 - 8 * byteLen
    // 例：byteLen=20 → bitShift=96（右移 96 位取高 160 位）

    // 第 3 步：跳过长度前缀
    nextPtr := add(nextPtr, 0x01)

    // 第 4 步：读取紧凑值
    pair := shr(nextBitShift, calldataload(nextPtr))
    // calldataload 读 32 字节，右移 bitShift 位，得到对齐后的值

    // 第 5 步：指针前进
    nextPtr := add(nextPtr, nextByteLen)
}
```

关键是第 4 步的 `shr(nextBitShift, calldataload(nextPtr))`。`calldataload` 总是从指定位置读取 32 字节，但我们只需要其中的 `byteLen` 字节。通过右移 `256 - 8 * byteLen` 位，低位的无关数据被移除，高位对齐到正确值。

这三行汇编（读长度、算位移、读值）是 BBCDecoder 全部 11 种操作码解码的统一模式。

### signextend：有符号整数的特殊处理

V3 swap 的 `amountSpecified` 是 `int256` 类型——可以是负数。BBC 编码中，有符号数的编码需要保留符号位。解码时多了一步 `signextend`：

```solidity
// 解码 int256 amountSpecified
amountSpecified := shr(nextBitShift, calldataload(nextPtr))
amountSpecified := signextend(sub(nextByteLen, 0x01), amountSpecified)
```

`signextend(b, x)` 是 EVM 原生指令：它将 `x` 的第 `b` 字节的最高位视为符号位，向高位扩展。

举例：假设编码了一个 2 字节的负数 `-255`（`0xFF01`）：

```
编码：02 FF01         （byte_len=2, 值=0xFF01）
解码后：shr → 0x000...FF01
signextend(1, 0xFF01) → 0xFFFF...FF01  （符号位 1 扩展到高位）
```

简单理解：`signextend` 将短字节的有符号数正确扩展为 int256。没有它，负数会被解释为一个很大的正数。

编码端也有对应的处理。`BBCEncoder.byteLen(int256)` 在计算长度时，会将值左移 1 位来为符号位预留空间——确保解码后 `signextend` 能恢复正确的符号。

## 方案 B：AttackContract "固定宽度"编码

AttackContract 采用了一种更简洁的方案：不用长度前缀，而是**按类型固定字段宽度**。

核心规则：

| 数据类型 | 固定宽度 | 说明 |
|---------|---------|------|
| address | 20 字节 | 紧密打包，无 ABI 零填充 |
| uint256 | 32 字节 | 直接读取，无长度前缀 |
| uint16 | 2 字节 | 大端序（用于长度和费率） |
| uint8 / bool | 1 字节 | 操作码、方向标志、比较符 |
| bytes | `[2B length] [N bytes]` | 可变长数据段 |

以 AttackContract 的 V2_SWAP（0x00）为例：

```
00                                        ← 1B opcode
00                                        ← 1B flag
14dccdd311ab827c42cca448ba87b1ac1039e2a4  ← 20B pool 地址（紧密打包）
000000000000000000000000000000000000000000000de0b6b3a7640000  ← 32B amount
01                                        ← 1B dir
01                                        ← 1B cb
1e                                        ← 1B fee (30 = 0.3%)

合计：57 字节（固定）
```

对比同一操作的 BBC 编码需要根据参数值动态变化（50-66 字节），AttackContract 的编码是固定的 57 字节。

### 三个辅助函数：_rAddr、_r16、_slice

AttackContract 的指令解码依赖三个简洁的辅助函数（参见 `AttackContract.sol`）：

```solidity
// 从 bytes 的指定偏移读取 20 字节地址
function _rAddr(bytes memory d, uint256 off) internal pure returns (address a) {
    assembly { a := shr(96, mload(add(add(d, 0x20), off))) }
    // mload 读 32 字节，shr(96) 右移 12 字节，取高 20 字节
}

// 从 bytes 的指定偏移读取 2 字节大端序 uint16
function _r16(bytes memory d, uint256 off) internal pure returns (uint16) {
    return uint16(uint8(d[off])) << 8 | uint16(uint8(d[off + 1]));
}

// 从 bytes 的指定偏移复制指定长度的片段
function _slice(bytes memory d, uint256 off, uint256 sz)
    internal pure returns (bytes memory out)
{
    out = new bytes(sz);
    for (uint256 i = 0; i < sz; i++) out[i] = d[off + i];
}
```

`_rAddr` 的汇编与 BBCDecoder 中读取地址的逻辑本质一样——都是 `shr(96, ...)` 从 32 字节中取高 20 字节。区别在于 AttackContract 不需要读取长度前缀（宽度固定为 20），也不需要计算 `bitShift`（固定为 96）。

`_r16` 读取 2 字节大端序，用于 calldata 长度前缀（如 RAW_CALL 中的 `cd_len`）和费率字段。

这三个函数的共同特点是**极其简洁**——没有边界检查，没有错误处理，纯粹的字节读取。在 MEV 合约中，calldata 的正确性由链下系统保证，链上合约不需要验证。

### 指令编码格式一览

AttackContract 全部 12 个操作码的编码格式：

| 操作码 | 编码 | 固定/变长 | 总字节数 |
|--------|------|----------|---------|
| 0x00 V2_SWAP | `[op][flag][pool:20B][amt:32B][dir][cb][fee]` | 固定 | 57 |
| 0x01 V3_SWAP/FLASH | `[op][flag][pool:20B][amt:32B][dir][cb][d?]` | 准固定 | 56-57 |
| 0x02 FLASH_LOAN_INITIATE | `[op][amt:32B][token:20B][type][pool:20B]` | 固定 | 74 |
| 0x03 WETH_DEPOSIT | `[op]` | 固定 | 1 |
| 0x04 WETH_WITHDRAW | `[op]` | 固定 | 1 |
| 0x05 REGISTER_COPY | `[op]` | 固定 | 1 |
| 0x06 SET_OR_MIN | `[op][value:32B][flag]` | 固定 | 34 |
| 0x07 BALANCE_OF | `[op][token:20B]` | 固定 | 21 |
| 0x08 SUB_BALANCE | `[op][token:20B]` | 固定 | 21 |
| 0x09 RAW_CALL | `[op][target:20B][vflag][len:2B][cd:NB]` | 变长 | 24+N |
| 0x0a CALL_WITH_AMT | `[op][target:20B][vflag][plen:2B][trail:2B][prefix:PB][trail:TB]` | 变长 | 26+P+T |
| 0x0b CALL_WITH_CHECK | `[op][target:20B][vflag]...[len:2B][cd:NB]` | 变长 | 57+N |

大多数操作码是固定长度的，解码时指针步进量已知。只有 RAW_CALL、CALL_WITH_AMT 和 CALL_WITH_CHECK 是变长的——它们携带任意长度的 calldata 片段，用 2 字节 `uint16` 长度前缀标明大小。

## 逆向认知演进：早期分析中的 opcode 误判

值得一提的是，上面的 opcode 表是基于最终的统一逆向重建（AttackContract.sol）确认的正确规格。在逆向工程的早期阶段，由于仅观测到 Base 链 15 笔攻击交易的 opcode 子集，分析者曾对几个操作码产生过误判：

| 操作码 | 早期误判 | 实际功能 | 误判原因 |
|--------|---------|---------|---------|
| 0x02 | READ_ADDR（读 20B 地址） | FLASH_LOAN_INITIATE（73B 闪电贷发起） | 15 笔 Base 链交易未使用此 opcode，仅从字节码静态分析推断 |
| 0x05 | SET_AMOUNT（读 7B 打包整数） | REGISTER_COPY（0B 寄存器拷贝） | 同上，未观测到实际执行路径 |
| 0x06 | CHECK_AMOUNT（读 20B token 地址） | SET_OR_MIN（33B 值+flag） | 同上 |

这些误判在跨链 replay 验证中被逐一修正——当更多链的攻击交易触发了这些 opcode 的完整执行路径后，正确的参数布局和语义才浮出水面。这个过程本身就是逆向工程中"从局部观察推断整体"的典型挑战，我们将在第 6 篇中详细展开。

## 三种方案的全维度对比

现在把三种编码方案放在一起，用同一个操作（ERC20 transfer：将 1 ETH 的 WETH 转给 `0xf39F...2266`）做对比。

### 标准 ABI 编码

```
a9059cbb                                                          ← 4B selector
000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266  ← 32B 地址
0000000000000000000000000000000000000000000000000de0b6b3a7640000  ← 32B 金额
                                                        合计：68 字节
```

### Lotus Router BBC 编码

```
04                                        ← 1B Action = TransferERC20
00                                        ← 1B canFail = false
14                                        ← 1B WETH 长度 = 20
C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2  ← 20B WETH 地址
14                                        ← 1B receiver 长度 = 20
f39Fd6e51aad88F6F4ce6aB8827279cffFb92266  ← 20B 接收地址
08                                        ← 1B amount 长度 = 8
0de0b6b3a7640000                          ← 8B 金额 (1 ETH)
                                                        合计：53 字节
```

### AttackContract 固定宽度编码

AttackContract 没有独立的 ERC20 transfer 操作码，它用 RAW_CALL（0x09）实现：

```
09                                        ← 1B opcode = RAW_CALL
C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2  ← 20B target (WETH)
00                                        ← 1B vflag
0044                                      ← 2B calldata 长度 = 68
a9059cbb                                  ← 4B selector
000000000000000000000000f39Fd6e51aad88...  ← 32B address
0000000000000000000000000de0b6b3a7640000  ← 32B amount
                                                        合计：92 字节
```

注意 AttackContract 的 RAW_CALL 携带的是完整的 ABI 编码 calldata（68 字节），外加自己的操作码头部（24 字节）。对于通用调用，AttackContract 不压缩被调用函数的参数。

### Gas 成本对比

| 方案 | 总字节 | 非零字节 | 零字节 | Calldata Gas |
|------|--------|---------|--------|-------------|
| ABI | 68 | ~40 | ~28 | 40×16 + 28×4 = **752** |
| BBC | 53 | ~50 | ~3 | 50×16 + 3×4 = **812** |
| AttackContract RAW_CALL | 92 | ~52 | ~40 | 52×16 + 40×4 = **992** |

一个有趣的发现：对于这个特定例子，BBC 编码的 calldata gas 并不比 ABI 低——因为 BBC 用非零的长度前缀替换了 ABI 的零填充，而非零字节更贵（16 vs 4 gas）。BBC 的优势在零值参数上更明显——当参数为零时，BBC 只用 1 字节（长度前缀 `00`），ABI 需要 32 字节零（128 gas vs 4 gas）。

在真实的 MEV 操作中（包含多个参数、部分为零），BBC 的压缩优势显著。Lotus Router README 中的量化数据表明，一笔典型的 V2 swap 从 288 字节压缩到 66 字节，calldata gas 节省超过 50%。

## 工程权衡总结

| 维度 | ABI 标准编码 | BBC 长度前缀 | AttackContract 固定宽度 |
|------|------------|------------|---------------|
| **压缩率** | 基线 | 最高（~77%） | 中等（~30-50%） |
| **解码复杂度** | 最低（编译器处理） | 最高（全汇编） | 中等（简单辅助函数） |
| **编码复杂度** | 最低（编译器处理） | 高（需计算 byteLen） | 低（固定格式拼接） |
| **代码可读性** | 最高 | 最低 | 中等 |
| **有符号数处理** | 自动 | 需 signextend | 不适用（无 int256 参数） |
| **零值优化** | 无（32B 全零） | 极佳（1B） | 无（32B 全零） |
| **解码 gas 开销** | 最低 | 中（位移计算） | 低（固定偏移） |
| **链下工具要求** | 标准（ethers/web3） | 需自定义编码器 | 需自定义编码器 |
| **运行时灵活性** | 无（值预定） | 无（值预定） | 有（amount 寄存器） |

三种方案各有适用场景：

- **ABI 编码**：适合标准合约交互、安全优先的场景。不需要压缩，不需要自定义工具。
- **BBC 长度前缀**：适合极致 gas 优化的场景。压缩率最高，但解码复杂度也最高。Lotus Router 选择这种方案因为它追求每一个 gas 的极限。
- **AttackContract 固定宽度**：在压缩和简洁之间取平衡。对地址（20B）和标志位（1B）做紧凑，对 uint256 保持 32 字节不压缩。解码逻辑简单——不需要位移计算，固定步进即可。设计优先级是**可靠性和开发效率**而非极致压缩。

## 动手环节

### 任务 1：手动编码同一操作的三种格式

编码以下 V3 swap 操作的参数，计算三种编码格式的字节数和 calldata gas：

**操作**：在 Uniswap V3 WETH/USDC 池（`0x8ad5...3487`）上，用 0.5 ETH（`0x06f05b59d3b20000`，8 字节）换 USDC，方向 zeroForOne=true，sqrtPriceLimitX96 = MIN_SQRT_RATIO + 1（`0x01000276a4`，5 字节非零）。

**ABI 编码**（`swap(address,bool,int256,uint160,bytes)`）：
```
参数 1: recipient (address, 20B有效) → 32B
参数 2: zeroForOne (bool)           → 32B
参数 3: amountSpecified (int256)    → 32B
参数 4: sqrtPriceLimitX96 (uint160) → 32B
参数 5: data (bytes, 空)            → 32B offset + 32B length = 64B
selector:                             4B
合计: 4 + 32×4 + 64 = 196 字节
```

**BBC 编码**（Lotus Router SwapUniV3）：
```
action:        1B  (0x02)
canFail:       1B  (0x00)
pool:          1B + 20B = 21B
recipient:     1B + 20B = 21B
zeroForOne:    1B  (直接编码，无前缀)
amountSpec:    1B + 8B = 9B
sqrtPriceLimit:1B + 5B = 6B
data:          4B + 0B = 4B (空 data)
合计: 64 字节
```

**AttackContract 固定宽度**（V3_SWAP 0x01）：
```
opcode:  1B
flag:    1B
pool:    20B
amt:     32B
dir:     1B
cb:      1B
合计: 56 字节
```

| 方案 | 字节数 | 预估 calldata gas |
|------|--------|-----------------|
| ABI | 196 | ~2,100 |
| BBC | 64 | ~900 |
| AttackContract | 56 | ~780 |

在这个例子中，AttackContract 的固定宽度编码反而比 BBC 更短——因为 AttackContract 不编码 recipient（固定为 `address(this)`）和 data（不使用回调数据），而 BBC 需要为每个参数都加长度前缀。

**结论**：没有"最优"的编码方案。最合适的方案取决于操作的参数结构、值的分布和合约的设计目标。

### 任务 2：计算 AttackContract Moonwell 攻击的 calldata gas 节省

AttackContract 一笔 Base 链 Moonwell 攻击的 calldata 是 932 字节。其中指令集 1 约 600 字节，指令集 2 为 77 字节，其余是 ABI 编码的 approve 包装层。

粗略估算：
1. 用 `cast tx` 获取 TX_01 的完整 calldata
2. 统计非零字节和零字节的数量
3. 计算实际 calldata gas
4. 思考：如果用标准 ABI 编码所有 11 条指令的参数（每条约 3-5 个 32 字节参数），calldata 会有多长？

```bash
# 获取 TX_01 calldata 并统计字节分布
cast tx 0x229caeb87e0b6c31afad950150d2ba05a8d7fe823c9e5c05af63b4150b8f6cc6 \
  input --rpc-url https://mainnet.base.org | \
  sed 's/0x//' | fold -w2 | sort | uniq -c | sort -rn | head -5
```

## 小结

Calldata 压缩是 MEV 路由合约的核心工程决策之一。以太坊对非零字节收取 16 gas、零字节 4 gas 的定价规则，直接激励了自定义编码格式的诞生。

Lotus Router 的 BBC 编码用动态长度前缀消除前导零，在参数含大量零值时压缩率可达 77%。AttackContract 的固定宽度编码在地址（20B）和标志位（1B）上做紧凑，uint256 保持 32 字节不压缩，换取更简单的解码逻辑和更可靠的开发体验。逆向过程中对 opcode 0x02/0x05/0x06 的误判和修正，则展示了从局部观察推断整体时的认知挑战。

没有"最优"的编码方案——只有最适合特定设计目标的方案。BBC 适合极致 gas 优化，固定宽度适合开发效率与可靠性优先，标准 ABI 适合安全和互操作性优先。

**下一篇**：第 6 篇《拆解攻击合约——从字节码到重建源码》，我们进入系列中最具原创性的内容——从没有源码的 24,543 字节的字节码出发，展示完整的逆向方法论：工具链选择、选择器分发表重建、calldata 驱动逆向，以及"编译→重放→失败→字节级对比→修复"的迭代循环。
