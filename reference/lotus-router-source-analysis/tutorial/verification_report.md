# 文档验证报告

> 初次验证：2026-03-18
> 二次审查修正：2026-03-18
> 验证测试文件：`lotus-router/test/TutorialVerification.t.sol`（位于 Foundry 项目内以访问 forge-std 依赖）

---

## 操作码语义核验

- [x] `CALLDATALOAD`: 描述正确——从 calldata 读 32 字节到栈，不足右侧零填充，超出范围返回全零。Gas = 3 ✓
- [x] `CALLDATACOPY`: 描述正确——3 个栈输入（destOffset, offset, size），gas = 3 + 3 × ⌈size/32⌉ + memory 扩展 ✓
- [x] `CALLDATASIZE`: 描述正确——0 栈输入，1 栈输出，gas = 2 ✓
- [x] `SHR`: 描述正确——逻辑右移，gas = 3 ✓
- [x] `SHL`: 描述正确——逻辑左移，gas = 3 ✓
- [x] `SIGNEXTEND`: 描述正确——将第 b 字节（从最低字节 0 开始计）的最高位扩展到所有高位。gas = 5 ✓
- [x] `MLOAD`: 描述正确——从 memory 读 32 字节到栈，gas = 3 + 扩展 ✓
- [x] `MSTORE`: 描述正确——将 32 字节写入 memory，gas = 3 + 扩展 ✓
- [x] `CALL`: 7 参数描述正确——gas, addr, value, argsOffset, argsLength, retOffset, retLength ✓
- [x] `STOP`: 描述正确——成功终止，不返回数据，gas = 0 ✓
- [x] `RETURN`: 描述正确——成功终止 + 返回数据，gas = 0 ✓
- [x] `RETURNDATASIZE`: 描述正确——返回最近外部调用的返回数据大小，gas = 2 ✓
- [x] `SIGNEXTEND` 边界行为：`shr(256, x)` 对任何 x 返回 0（bitShift=256 对应 byteLen=0）✓（测试 `test_bbc_zero_value`）

**修正项**：
- [已修正] `-1 ether` 的十六进制值：原 `0xF21F494C58000000` → 修正为 `0xF21F494C589C0000`。通过 `cast to-hex -- -1000000000000000000` 验证

---

## 数值示例实测

### Selector 验证（`cast sig`）

- [x] `transfer(address,uint256)` = `0xa9059cbb` ✓
- [x] `transferFrom(address,address,uint256)` = `0x23b872dd` ✓
- [x] `swap(uint256,uint256,address,bytes)` = `0x022c0d9f` ✓
- [x] `swap(address,bool,int256,uint160,bytes)` = `0x128acb08` ✓
- [x] `flash(address,uint256,uint256,bytes)` = `0x490e6cbc` ✓
- [x] `withdraw(uint256)` = `0x2e1a7d4d` ✓
- [x] `takeAction()` = `0x19ff8034` ✓
- [x] `uniswapV2Call(address,uint256,uint256,bytes)` = `0x10d1e85c` ✓
- [x] `uniswapV3SwapCallback(int256,int256,bytes)` = `0xfa461e33` ✓
- [x] `uniswapV3FlashCallback(uint256,uint256,bytes)` = `0xe9cbafb0` ✓
- [x] `transfer(address,uint256,uint256)` (ERC6909) = `0x095bcdb6` ✓
- [x] `transferFrom(address,address,uint256,uint256)` (ERC6909) = `0xfe99049a` ✓

### ABI 编码验证（`cast abi-encode`）

- [x] `foo(uint256, bytes, address)` offset = 0x60 ✓
- [x] `bar(bytes, string)` offsets = 0x40, 0x80 ✓
- [x] `transfer(address, uint256)` 编码格式 ✓

### 位移计算验证（Forge 测试）

- [x] `shr(224, 0xCAFEBABE << 224)` = `0xCAFEBABE` ✓（`test_shr_extract_high_4_bytes`）
- [x] `shr(248, 0x0B << 248)` = `0x0B` ✓（`test_shr_extract_high_1_byte`）
- [x] BBC bitShift 公式 `256 - 8 × byteLen` 正确 ✓（`test_bbc_bitshift_formula`）
- [x] BBC address 解码 `shr(96, packed)` ✓（`test_bbc_decode_address`）
- [x] BBC sub/mul 公式 `sub(0x0100, mul(0x08, 20))` = 96 ✓（`test_bbc_decode_address_formula`）
- [x] `signextend(7, 0xF21F494C589C0000)` = `-1 ether` ✓（`test_signextend_negative`）
- [x] `signextend(7, 0x0DE0B6B3A7640000)` = `1 ether` ✓（`test_signextend_positive`）
- [x] `shr(256, x)` = 0（byteLen=0 零值语义）✓（`test_bbc_zero_value`）

---

## 源码行号验证

### BBCDecoder.sol

- [x] `BBCDecoder.sol:38` — `u8Shr = 0xf8` ✓
- [x] `BBCDecoder.sol:39` — `u32Shr = 0xe0` ✓
- [x] `BBCDecoder.sol:71-113` — `decodeSwapUniV2` assembly block ✓
- [x] `BBCDecoder.sol:75` — `canFail := shr(u8Shr, calldataload(nextPtr))` ✓
- [x] `BBCDecoder.sol:78-82` — pair 解码三步模式 ✓
- [x] `BBCDecoder.sol:106-112` — data 字段（BytesCalldata 赋值）✓
- [x] `BBCDecoder.sol:177-178` — signextend 处理 ✓
- [x] `BBCDecoder.sol:688-723` — `decodeDynCall` assembly block（函数签名 688-694，assembly 695-723）✓

### ERC20.sol

- [x] `ERC20.sol:49-64` — `transfer` 函数（含签名）✓
- [x] `ERC20.sol:50-64` — `transfer` assembly block ✓
- [x] `ERC20.sol:57` — call 调用 ✓
- [x] `ERC20.sol:59` — `or(iszero(returndatasize()), eq(0x01, mload(0x00)))` ✓
- [x] `ERC20.sol:63` — `mstore(0x24, 0x00)` 恢复 ✓
- [x] `ERC20.sol:113-133` — `transferFrom` assembly block ✓
- [x] `ERC20.sol:114` — `let fmp := mload(0x40)` ✓
- [x] `ERC20.sol:124` — `call` ✓
- [x] `ERC20.sol:130` — `mstore(0x40, fmp)` ✓
- [x] `ERC20.sol:132` — `mstore(0x60, 0x00)` ✓

### UniV2Pair.sol

- [x] `UniV2Pair.sol:51-73` — `swap` assembly block ✓
- [x] `UniV2Pair.sol:54` — `shr(0xe0, calldataload(data))` ✓
- [x] `UniV2Pair.sol:66` — `mstore(add(fmp, 0x64), 0x80)` ✓
- [x] `UniV2Pair.sol:70` — `calldatacopy(add(fmp, 0xa4), data, dataLen)` ✓
- [x] `UniV2Pair.sol:72` — `call(gas(), pair, 0x00, fmp, add(dataLen, 0xc4), 0x00, 0x00)` ✓

### UniV3Pool.sol

- [x] `UniV3Pool.sol:57-81` — V3 `swap` assembly block ✓
- [x] `UniV3Pool.sol:74` — `mstore(add(fmp, 0x84), 0xa0)` ✓
- [x] `UniV3Pool.sol:80` — `call(gas(), pool, 0x00, fmp, add(dataLen, 0xe4), 0x00, 0x00)` ✓
- [x] `UniV3Pool.sol:125-147` — `flash` assembly block ✓

### 其他文件

- [x] `Dyn.sol:6-18` — `dynCall` 函数 ✓
- [x] `Dyn.sol:14` — `calldatacopy(fmp, data, dataLen)` ✓
- [x] `Dyn.sol:16` — `call(gas(), target, value, fmp, dataLen, 0x00, 0x00)` ✓
- [x] `WETH.sol:28-29` — 注释说明 fallback 行为 ✓
- [x] `WETH.sol:35-37` — `deposit` call ✓
- [x] `WETH.sol:62-67` — `withdraw` assembly block ✓
- [x] `ERC721.sol:52-67` — `transferFrom` scratch space（仅恢复 fmp，未恢复 zero slot）✓
- [x] `PayloadPointer.sol:34-48` — `findPtr()` ✓
- [x] `PayloadPointer.sol:67-71` — `nextAction` assembly block ✓
- [x] `LotusRouter.sol:68` — `fallback() external payable {` ✓
- [x] `LotusRouter.sol:73` — `while (success) {` ✓
- [x] `LotusRouter.sol:77-79` — `Action.Halt` → `stop()` ✓
- [x] `LotusRouter.sol:217` — `receive() external payable { }` ✓
- [x] `BBCEncoder.sol:69` — shl 编码 ✓
- [x] `BBCEncoder.sol:93` — identity precompile staticcall ✓
- [x] `BBCEncoder.sol:159, 220, 650` — 其他 identity precompile 调用 ✓
- [x] `BBCEncoder.sol:542` — `encodeDepositWETH` 无 `memory-safe` ✓
- [x] `BBCEncoder.sol:582` — `encodeWithdrawWETH` 无 `memory-safe` ✓
- [x] `BBCEncoder.sol:656-664` — `byteLen(uint256)` ✓
- [x] `BBCEncoder.sol:678-691` — `byteLen(int256)` ✓

---

## 验证测试

```
forge test --match-contract TutorialVerification -v

Ran 23 tests for test/TutorialVerification.t.sol:TutorialVerification
23 passed; 0 failed; 0 skipped
```

### 测试覆盖

| 类别 | 测试数 | 描述 |
|------|--------|------|
| Calldataload 行为 | 4 | shr 提取、shift 常量、越界零填充 |
| BBC 解码 | 5 | bitShift 公式、address 解码、signextend、零值 |
| ABI 编码布局 | 3 | 3/4/5 参数函数的 bytes offset |
| Selector | 1 | 7 个 selector 值验证 |
| Gas 计算 | 5 | address/零值/1 ether 零字节计数/bool gas/字节数对比 |
| Memory 布局 | 2 | scratch space 覆盖范围验证 |
| Call size | 2 | V2/V3 swap call size 计算 |

---

## 二次审查修正项（2026-03-18）

| # | 修正内容 | 涉及文件 | 严重度 | 说明 |
|---|----------|----------|--------|------|
| 1 | 栈生命周期 | doc1 第一部分 | 严重 | "当前操作码执行期间" → "当前 call frame（LIFO 访问）"。栈值在 call frame 内跨操作码持续存在（黄皮书 §9.1） |
| 2 | bool gas 值 | doc1 第七部分 | 严重 | bool=true 的 ABI gas 从 132 → 修正为 140（31×4 + 1×16 = 140）。节省从 116 → 修正为 124。验证测试 `test_bool_gas` 确认 |
| 3 | 1 ether 零字节误算 | doc1 第七部分 | 中等 | `0x0DE0B6B3A7640000` 中末尾 2 字节是零。ABI gas 从 224 → 200，BBC gas 从 144 → 120。swap 对比总计从 1052/920 → 1028/896。验证测试 `test_one_ether_byte_classification` 确认 |
| 4 | WETH receive→fallback | doc1 第六部分 + doc2 第五部分 | 轻微 | WETH deposit 利用的是 `fallback()` 而非 `receive()`（见 `WETH.sol:28-29` 注释）。两处已修正 |
| 5 | Memory 策略分类 | doc2 第二部分 | 中等 | 原 "参数多（3-4 个 + bytes）→ scratch space" 中的 "+ bytes" 与实例不符（ERC20.transferFrom 和 ERC6909.transfer 无 bytes 参数）。改为按 calldata 总长度分类，并增加 ERC721.transferFrom 的特殊行为说明 |
| 6 | O(1) 访问措辞 | doc1 第三部分 | 轻微 | 原 "第 N 个参数始终在 offset 4+N×32" 可能暗示动态参数的值也直接在此。修正为明确区分静态值/动态 offset |
| 7 | bytes 行 gas 缺失 | doc1 第七部分 | 轻微 | 原 "—" → 补充完整数值：ABI 96B/408 gas, BBC 9B/84 gas |
| 8 | L2 data fee 过时 | doc1 第七部分 | 轻微 | 原 "按字节计费" → 补充 EIP-4844 后 blob 定价机制说明 |
| 9 | ERC721 zero slot | doc2 第二部分 | 轻微 | 新增 ERC721.transferFrom 未恢复 zero slot 的观察说明 |

---

## 两份文档一致性检查

- [x] Calldata 操作码在文档二中简要回顾并引用文档一第四部分，未重复详解 ✓
- [x] BBC 位移公式 `sub(0x0100, mul(0x08, byteLen))` 在两份文档中描述一致 ✓
- [x] ERC20 返回值校验 `or(iszero(returndatasize()), eq(0x01, mload(0x00)))` 在两份文档中引用相同源码行 ✓
- [x] Scratch space 覆盖分析在两份文档中结论一致（transfer 覆盖 68 字节，transferFrom 覆盖 100 字节）✓
- [x] WETH deposit 在两份文档中统一描述为 `fallback()`（二次审查后）✓
- [x] Gas 数值在文档和验证测试中一致（二次审查后）✓
