# 第 3 篇：闪电贷与 DEX —— MEV 的两大基础设施

在第 1 篇中我们看到，AttackContract 的 Base 链部署在 30 秒内完成了 12 笔攻击，净提取 295.75 ETH。在第 2 篇中我们理解了，175-253 gwei 的 gas price 是对时间窗口的精确定价。但有一个问题我们一直跳过了：攻击者用什么资金来执行这些攻击？

答案是：几乎没有。

以 TX_01 为例，AttackContract 从 Aerodrome 的 CLPool 中闪贷了 650,064,525,566,293 wei 的 wrsETH——大约 0.00065 个 wrsETH，按真实市场价计算价值不到 3 美元。就是这不到 3 美元的"启动资金"，通过 Moonwell 预言机的 1657 倍价格偏差，借出了价值约 $8,800 的 cbXRP，经 DEX 兑换后净赚约 30.79 ETH（约 $110,000）。整个过程在一笔交易内完成——如果任何一步失败，所有操作回滚，攻击者的损失仅是 gas 费。

这种"空手套白狼"的能力来自两项 DeFi 基础设施：**闪电贷**（提供无抵押的瞬时资金）和 **DEX**（提供确定性的代币兑换）。它们是 MEV 世界的两大支柱，也是理解 MEV 路由合约回调架构的前提。

## 闪电贷：原子性魔法

### 一个违反直觉的金融产品

在传统金融中，无抵押贷款是不可想象的——没有担保，谁会把钱借给你？但闪电贷打破了这个常识。

闪电贷的规则极其简单：你可以在一笔交易中借走任意金额的资金，只要你在**同一笔交易结束前**归还本金和手续费。如果你做不到——不是罚款，不是追债，而是**整笔交易回滚**，就像它从未发生过一样。

这里的关键是以太坊交易的**原子性**：一笔交易中的所有操作，要么全部成功，要么全部失败。没有"部分执行"的中间态。闪电贷正是利用了这个特性——借款和还款被强制包裹在同一个原子性操作中，协议不需要信任借款人，因为 EVM 本身保证了还款。

在代码层面，闪电贷的工作流程是一个**回调模式**：

```
1. 你的合约调用闪贷协议的 flash() 函数，请求借款
2. 协议将资金转给你的合约
3. 协议调用你合约的回调函数（"资金到账了，做你想做的事"）
4. 你的合约在回调中执行任意逻辑（套利、清算、攻击...）
5. 回调结束后，协议检查资金是否已归还
6. 如果归还了 → 交易成功；如果没有 → 整笔交易 revert
```

这个模式意味着闪电贷的安全性不依赖任何外部保证——它被编码在协议的智能合约中，由 EVM 执行引擎强制执行。

### TX_01 的闪电贷：0.00065 wrsETH 的奇妙旅程

让我们具体看看 TX_01 中闪电贷是如何被使用的：

```
第 1 步：AttackContract 调用 CLPool.flash()，闪贷 0.00065 wrsETH
        （Aerodrome CLPool: 0x14dc...e2a4）

第 2 步：CLPool 将 0.00065 wrsETH 转给 AttackContract

第 3 步：CLPool 调用 AttackContract 的 uniswapV3FlashCallback()

第 4 步：在回调中，AttackContract 执行攻击序列：
        a. 将 wrsETH 存入 Moonwell（mint mwrsETH）
        b. 利用 1657x 预言机偏差，从 Moonwell 借出 12,057 cbXRP
        c. 在 Algebra DEX 上将 cbXRP 换成 ~30.96 WETH
        d. 将部分 WETH 换回 wrsETH 用于还贷

第 5 步：AttackContract 归还 0.00065 wrsETH + 手续费给 CLPool

第 6 步：CLPool 验证归还 ✓ → 交易成功
        攻击者获利 ~30.79 ETH
```

注意一个有趣的细节：闪电贷的金额（0.00065 wrsETH）和最终利润（~30.79 ETH）完全不成比例。闪电贷在这里的角色不是"提供攻击资金"，而是"提供进入借贷协议的入场券"——一点点抵押品就够了，因为真正的杠杆来自预言机的价格错误。

## 闪电贷协议全景：四种协议，五种签名

不同的闪电贷协议有不同的接口设计——这个事实直接决定了 MEV 路由合约需要多少个函数选择器。让我们逐一看看主流协议的回调签名。

### Uniswap V3 flash

最直接的闪贷接口。你调用池子的 `flash()` 函数，池子在回调中传入手续费金额：

```solidity
// 发起闪贷
pool.flash(recipient, amount0, amount1, data);

// 你的回调函数
function uniswapV3FlashCallback(
    uint256 fee0,      // token0 的手续费
    uint256 fee1,      // token1 的手续费
    bytes calldata data // 你传入的自定义数据
) external;
// 归还方式：直接 transfer(token, pool, amount + fee)
```

这是最简洁的设计——参数签名为 `(uint256, uint256, bytes)`，回调名称就是协议标识。

### AAVE V2 / V3

AAVE 是最大的借贷协议之一，其闪贷回调叫做 `executeOperation`。V2 和 V3 的签名不同：

```solidity
// AAVE V2/V3 标准闪贷（多资产）
function executeOperation(
    address[] calldata assets,    // 借入的资产地址列表
    uint256[] calldata amounts,   // 借入的金额列表
    uint256[] calldata premiums,  // 手续费列表
    address initiator,            // 发起者地址
    bytes calldata params         // 自定义数据
) external returns (bool);
// 归还方式：approve(pool, amount + premium)，由 pool 拉取

// AAVE V3 Simple 闪贷（单资产，V3 新增）
function executeOperation(
    address asset,        // 借入的资产地址
    uint256 amount,       // 借入的金额
    uint256 premium,      // 手续费
    address initiator,
    bytes calldata params
) external returns (bool);
```

注意 AAVE 的归还方式与 Uniswap V3 不同——不是你主动 transfer，而是你 `approve` 给 pool，让 pool 自己来拉取。这个差异看似微小，但对 MEV 路由合约的通用调用逻辑意味着不同的处理路径。

### Balancer

Balancer 支持多资产闪贷，回调签名是：

```solidity
function receiveFlashLoan(
    address[] calldata tokens,   // 借入的代币列表
    uint256[] calldata amounts,  // 借入的金额列表
    uint256[] calldata fees,     // 手续费列表
    bytes calldata userData      // 自定义数据
) external;
// 归还方式：直接 transfer 每个 token 的 amount + fee 给 Vault
```

### Morpho Blue

Morpho 的闪贷接口最为简洁：

```solidity
function onMorphoFlashLoan(
    uint256 assets,       // 借入金额
    bytes calldata data   // 自定义数据
) external;
// 归还方式：直接 transfer 回 Morpho 合约
```

### 回调签名差异总结

| 协议 | 回调函数名 | 参数签名 | 归还方式 |
|------|----------|---------|---------|
| Uniswap V3 | `uniswapV3FlashCallback` | `(uint256, uint256, bytes)` | transfer |
| AAVE V2/V3 | `executeOperation` | `(address[], uint256[], uint256[], address, bytes)` | approve + pull |
| AAVE V3 Simple | `executeOperation` | `(address, uint256, uint256, address, bytes)` | approve + pull |
| Balancer | `receiveFlashLoan` | `(address[], uint256[], uint256[], bytes)` | transfer |
| Morpho | `onMorphoFlashLoan` | `(uint256, bytes)` | transfer |

四种协议（Uniswap V3、AAVE、Balancer、Morpho），五种不同的回调签名（AAVE 因 V2/V3 标准和 V3 Simple 有两种）。但这还不是全部。

## 回调签名爆炸：为什么 AttackContract 需要 42 个函数

上面只列出了 5 种协议。现实情况远比这复杂，因为 Uniswap V3 的接口被大量 DEX fork：

- PancakeSwap V3 使用 `pancakeV3FlashCallback`
- Solidly V3 使用 `solidlyV3FlashCallback`
- Algebra 使用 `algebraFlashCallback`
- Squad V3 使用 `squadV3FlashCallback`
- 还有 Thruster、Zebra、DragonSwap、Xei、StoryHunt、FusionX、VVS...

它们的参数签名完全一样——都是 `(uint256, uint256, bytes)`——但**函数名不同**，所以**选择器不同**。每一个不同的选择器都需要合约中有一个对应的外部函数来接收回调。

AttackContract 用了 42 个函数来覆盖它需要交互的协议——因为它部署在几乎所有主要 EVM 链上，每条链有不同的主流 DEX。

来看这些回调的代码，它们的实现几乎完全一样：

```solidity
// AttackContract.sol —— 闪贷回调，全部路由到同一个内部函数
function uniswapV3FlashCallback(uint256 f0, uint256 f1, bytes calldata d)
    external { _handleUintCb(f0, f1, d); }
function pancakeV3FlashCallback(uint256 f0, uint256 f1, bytes calldata d)
    external { _handleUintCb(f0, f1, d); }
function algebraFlashCallback(uint256 f0, uint256 f1, bytes calldata d)
    external { _handleUintCb(f0, f1, d); }
function solidlyV3FlashCallback(uint256 f0, uint256 f1, bytes calldata d)
    external { _handleUintCb(f0, f1, d); }
// ... 还有更多类似的函数
```

15 个闪贷回调函数，一模一样的参数类型 `(uint256, uint256, bytes)`，一模一样的函数体，唯一的区别是函数名。这看起来极其冗余——但没有别的办法。EVM 的函数分派机制基于选择器（函数名 + 参数类型的 keccak256 前 4 字节），不同的函数名就是不同的选择器，合约必须为每一个选择器提供入口。

这就是 MEV 路由合约选择器膨胀的根本原因：不是逻辑复杂，而是 DeFi 生态的碎片化。每一个协议的 fork 都可能用自己的回调函数名，而你的合约必须全部支持。

## DEX Swap 的两大范式

理解了闪电贷的回调机制，现在来看 MEV 的另一根支柱：DEX swap。链上交易所的 swap 操作有两种根本不同的范式，这个差异直接影响了 MEV 路由合约的架构设计。

### 范式一：V2 "先转账后 swap"

Uniswap V2 及其 fork（SushiSwap、PancakeSwap V2 等）采用一种朴素的设计：

```
1. 你先将输入代币 transfer 到池子合约
2. 你调用池子的 swap() 函数
3. 池子将输出代币 transfer 给你
```

```solidity
// V2 Swap 示意（简化，生产代码应使用低级 call + 返回值检查的 safeTransfer）
// 第 1 步：转入输入代币
IERC20(tokenIn).transfer(pair, amountIn);

// 第 2 步：调用 swap，指定你要获得的输出数量
// amount0Out 和 amount1Out 中有一个为 0，另一个为计算好的输出量
pair.swap(amount0Out, amount1Out, recipient, "");
```

这里有一个关键的顺序约束：**必须先转账，后 swap**。因为 `swap()` 函数内部会检查池子的余额变化——如果你没有先转入代币，`swap()` 会因为 `K` 值检查失败而 revert。

在 AttackContract 的 V2_SWAP 操作码（0x00）中，这个流程被实现为：

```solidity
// AttackContract V2_SWAP 核心逻辑（简化）
// 1. 转账输入代币到池子
_safeTransfer(inputToken, pool, amount);

// 2. 获取储备量
(uint112 r0, uint112 r1,) = IUniV2Pool(pool).getReserves();

// 3. 用恒定乘积公式计算输出
uint256 amtIn = amount * (10000 - fee);  // fee 通常为 30 (0.3%)
uint256 amtOut = (amtIn * reserveOut) / (reserveIn * 10000 + amtIn);

// 4. 调用 swap 获取输出
IUniV2Pool(pool).swap(amount0Out, amount1Out, address(this), "");
```

V2 范式的特点是**无回调**——整个过程是同步的，调用者完全掌控流程。这意味着 AttackContract 不需要为 V2 swap 提供任何回调函数。

### 范式二：V3 "先 swap 后回调"

Uniswap V3 采用了相反的设计——**先执行 swap，再通过回调收取输入代币**：

```
1. 你调用池子的 swap() 函数
2. 池子计算交换结果，将输出代币 transfer 给你
3. 池子调用你合约的回调函数，告诉你"你欠我多少"
4. 你在回调中将输入代币 transfer 给池子
```

```solidity
// V3 Swap 示意
// 调用 swap —— 池子会回调你的合约
(int256 amount0, int256 amount1) = pool.swap(
    recipient,           // 输出代币接收者
    zeroForOne,          // 方向：true = token0→token1
    amountSpecified,     // 输入数量（int256）
    sqrtPriceLimitX96,   // 价格限制
    data                 // 传给回调的自定义数据
);

// 池子会调用你的这个函数
function uniswapV3SwapCallback(
    int256 amount0Delta,  // 正数 = 你欠池子 token0
    int256 amount1Delta,  // 正数 = 你欠池子 token1
    bytes calldata data
) external {
    // 将欠款转给池子
    if (amount0Delta > 0) {
        IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
    }
    if (amount1Delta > 0) {
        IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
    }
}
```

V3 回调模式的核心价值在于**灵活性**：你不需要在调用 swap 之前就持有输入代币。代币可以在回调中从任何地方获取——其他池子的 swap 输出、闪电贷资金、甚至另一个回调中的资金。这正是 MEV 路由合约实现多跳 swap 的基础。

### 两种范式的对比

| 特性 | V2（先转后 swap） | V3（先 swap 后回调） |
|------|------------------|-------------------|
| 资金流向 | 你 → 池子 → 你 | 池子 → 你，你 → 池子（回调中） |
| 回调函数 | 不需要 | 必须实现 |
| 调用前需要持有代币 | 是 | 否 |
| 选择器开销 | 无 | 每个 fork 一个 |
| AMM 公式 | 恒定乘积 x·y=k | 集中流动性（sqrtPrice） |
| 适合 MEV 路由 | 简单但不灵活 | 灵活但增加合约复杂度 |

对 MEV 路由合约来说，V3 的回调模式是把双刃剑：它让多跳路由成为可能（Lotus Router 的递归回调正是利用了这一点），但也是选择器膨胀的另一个来源——每个 V3 fork 的 swap 回调名称不同，合约必须全部支持。

## Algebra 与有符号 Delta 语义

在 V3 风格的 DEX 中，有一个重要的变体需要特别关注：Algebra Protocol。

Algebra 不是一个面向终端用户的 DEX，而是一个 **DEX 引擎供应商**——它提供一套集中流动性 AMM 代码库，其他 DEX 项目可以直接集成来获得集中流动性、动态手续费等功能。你可以把它理解为"DEX 界的白牌引擎"：很多手机品牌用高通芯片，很多 DEX 用 Algebra 的 AMM 引擎。THENA（BNB Chain）、Camelot（Arbitrum）、QuickSwap V3（Polygon）都是基于 Algebra 构建的。

Algebra 的核心功能与 Uniswap V3 非常相似（集中流动性），但有两个关键差异：一是自适应动态手续费——根据波动率和交易量自动调整，而非 Uniswap V3 的固定费率档位；二是模块化插件架构——Algebra Integral（V4 版本）允许在池子上挂载自定义插件，类似于 Uniswap V4 的 hooks 概念，但 Algebra 更早实现。

在 TX_01 的攻击流程中，AttackContract 将从 Moonwell 借出的 cbXRP 通过 AlgebraPool（`0xee58...27ed`）兑换成 WETH。这个池子就是 Base 链上集成了 Algebra 引擎的 DEX（从链上 State Changes 中出现的 HydrexBasePlugin 来看，很可能是 Hydrex）提供的 cbXRP/WETH 交易对。这也是 AttackContract 中有 `algebraSwapCallback`（选择器 `0x2c8958f6`）的原因——Algebra 系的 DEX 在执行 swap 时回调 `algebraSwapCallback`，而不是 Uniswap V3 的 `uniswapV3SwapCallback`。AttackContract 同时实现了两种回调，所以既能在 Uniswap V3 池上 swap，也能在 Algebra 池上 swap。

理解了 Algebra 的定位，再来看它的 swap 回调。Algebra 使用了与 Uniswap V3 相同的**有符号 delta 语义**：

```solidity
function algebraSwapCallback(
    int256 amount0Delta,  // 正数 = 你需要付出 token0；负数 = 你收到的 token0
    int256 amount1Delta,  // 正数 = 你需要付出 token1；负数 = 你收到的 token1
    bytes calldata data   // 自定义数据
) external;
```

正数表示"你欠池子的"，负数表示"池子给你的"。在 swap 回调中，总是一个参数为正（你要付的），另一个为负（你收到的）。处理逻辑很简单——只需要转账正数部分：

```solidity
// AttackContract _handleIntCb —— 统一处理所有 V3 风格 swap 回调
function _handleIntCb(int256 a0, int256 a1, bytes calldata) internal {
    if (a0 > 0) {
        address t = IUniV3Pool(msg.sender).token0();
        _safeTransfer(t, msg.sender, uint256(a0));
    }
    if (a1 > 0) {
        address t = IUniV3Pool(msg.sender).token1();
        _safeTransfer(t, msg.sender, uint256(a1));
    }
}
```

这段代码同时处理了 Uniswap V3、Algebra、PancakeSwap V3、Solidly V3 等所有使用有符号 delta 语义的 DEX——它们的回调参数类型完全一样（`int256, int256, bytes`），只是函数名不同。

这个观察直接引出了 AttackContract 的一个优雅设计。

## AttackContract 的回调分派：按参数类型而非协议名称

既然闪贷回调的参数类型总是 `(uint256, uint256, bytes)`，swap 回调总是 `(int256, int256, bytes)`，那为什么不直接**按参数类型分类**？AttackContract 正是这样做的：

```
(uint256, uint256, bytes) → _handleUintCb   — 15 个选择器（闪贷回调）
(int256, int256, bytes)   → _handleIntCb    — 16 个选择器（swap 回调）
其他特殊签名               → 独立实现         — 11 个选择器（Morpho、Balancer、AAVE 等）
```

为什么这样分？因为有一个关键的语义对应关系：

- **所有闪贷回调**的前两个参数都是 **uint256**（手续费金额，无符号）
- **所有 swap 回调**的前两个参数都是 **int256**（delta 金额，有符号）

参数类型就是语义分界线。AttackContract 在字节码级别直接按参数类型分派，不需要关心回调的函数名——只要参数签名匹配，就路由到正确的处理函数。

两个处理函数的核心差异在于"执行还是只转账"：

```solidity
// 简化示意
function _handleUintCb(uint256 fee0, uint256 fee1, bytes memory d) internal {
    // 闪贷回调：需要执行指令 + 还贷
    uint256 preBalance = IERC20(token).balanceOf(address(this));
    _execLoop(d);  // 执行嵌套指令！
    _safeTransfer(token, msg.sender, preBalance + fee);  // 还贷
}

function _handleIntCb(int256 a0, int256 a1, bytes memory) internal {
    // Swap 回调：只需转账欠款
    if (a0 > 0) _safeTransfer(token0, msg.sender, uint256(a0));
    if (a1 > 0) _safeTransfer(token1, msg.sender, uint256(a1));
}
```

闪贷回调中会执行指令序列（`_execLoop(d)`），因为闪贷是整个攻击流程的"外壳"——所有后续操作（借贷、swap、利润提取）都在闪贷回调内完成。而 swap 回调只负责一件事：转账欠款给池子。

这个设计还带来了一个额外好处：当新的 DEX fork 出现时，只要它的回调参数类型是 `(uint256, uint256, bytes)` 或 `(int256, int256, bytes)`，AttackContract 只需要添加一个新的外部函数（同样的函数体，不同的函数名），就能自动路由到正确的处理逻辑。

## AMM 数学基础：确定性是关键

MEV 之所以可行，一个重要前提是 DEX swap 的**确定性**——给定输入数量和当前池子状态，输出数量是可以精确计算的。这意味着 Searcher 可以在链下模拟整个攻击路径的利润，只有在利润为正时才提交交易。

### V2：恒定乘积公式

Uniswap V2 的核心是恒定乘积公式 `x · y = k`，其中 `x` 和 `y` 是池子中两种代币的储备量。当你用 `Δx` 数量的 token0 换取 token1 时（扣除 0.3% 手续费后）：

```
Δy = (Δx · 997 · y) / (x · 1000 + Δx · 997)
```

这个公式的性质是：**投入越多，单位产出越低**（价格滑点）。这也是攻击者将攻击拆分为 12 笔交易的原因之一——每笔控制滑点在可接受范围内，总利润反而更高。

### V3：集中流动性

Uniswap V3 引入了集中流动性——流动性提供者可以将资金集中在特定价格区间，而非均匀分布在 0 到 ∞ 的全价格范围。这意味着在活跃的价格区间内，同样的流动性可以支撑更大的交易量和更小的滑点。

V3 的数学模型基于 `sqrtPriceX96`——一个 Q64.96 定点数表示的价格平方根。swap 调用中的 `sqrtPriceLimitX96` 参数设定了价格滑动的上限。AttackContract 在代码中硬编码了两个常量：

```solidity
// AttackContract.sol
uint160 constant MAX_SQRT_RATIO_M1 =
    1461446703485210103287273052203988822378723970341;  // 最大价格 - 1
uint160 constant MIN_SQRT_RATIO_P1 = 4295128740;       // 最小价格 + 1
```

这两个值分别是 Uniswap V3 允许的最大和最小 sqrtPrice，减/加 1 以通过边界检查。AttackContract 总是使用极限值——意味着它不设滑点保护，接受任何价格的执行。对于预言机套利来说这是合理的：利润空间远大于滑点损失，所以不需要精细的价格限制。

### 确定性的价值

对 MEV Searcher 来说，AMM 的确定性意味着：

1. **精确模拟**：链下可以用相同的公式计算预期输出，精确到 wei
2. **利润预判**：在提交交易前就知道能赚多少（或亏多少）
3. **参数优化**：可以穷举不同的输入量，找到利润最大化的最优解

AttackContract 的 Moonwell 攻击之所以能精确计算每个市场的最优借贷金额，正是因为 DEX 输出是确定性的。链下系统只需要：预言机偏差 × Moonwell 可借余额 × DEX 输出函数 → 预期利润。如果利润为正，生成 calldata，提交交易。

## 动手环节

### 任务 1：最简 AAVE V3 闪电贷合约

以下合约演示了闪电贷的核心流程：借入 → 回调 → 归还。没有任何套利逻辑，纯粹展示机制。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 简化示意：仅展示闪电贷核心流程
// 部署到 fork 测试环境中运行

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract SimpleFlashLoan {
    IPool public immutable POOL;

    // Ethereum 主网 AAVE V3 Pool Addresses Provider
    // 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e
    constructor(address provider) {
        POOL = IPool(IPoolAddressesProvider(provider).getPool());
    }

    /// @notice 发起闪电贷
    /// @param asset 要借的代币地址（如 USDC、WETH）
    /// @param amount 借入金额
    function initiateFlashLoan(address asset, uint256 amount) external {
        // 发起闪贷，AAVE 会回调 executeOperation
        POOL.flashLoanSimple(
            address(this), // 接收者 = 本合约
            asset,
            amount,
            "",            // 自定义参数（这里不需要）
            0              // referral code
        );
    }

    /// @notice AAVE 的闪贷回调 —— 资金到账后被自动调用
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,   // 手续费（通常为借入金额的 0.05%）
        address initiator,
        bytes calldata /* params */
    ) external returns (bool) {
        // 安全检查：确保是自己发起的闪贷
        require(msg.sender == address(POOL), "caller must be pool");
        require(initiator == address(this), "initiator must be self");

        // ====== 在这里执行你的逻辑 ======
        // 此时合约已持有 `amount` 数量的 `asset`
        // 可以做任何事：套利、清算、仓位调整...
        // 本示例什么都不做，直接归还
        // ================================

        // 归还本金 + 手续费
        // AAVE 的方式：approve 给 Pool，由 Pool 拉取
        uint256 totalDebt = amount + premium;
        IERC20(asset).approve(address(POOL), totalDebt);

        return true; // 返回 true 表示归还成功
    }
}
```

**Foundry 测试脚本**：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// 将上面的 SimpleFlashLoan 合约导入或粘贴到同一文件
// import {SimpleFlashLoan} from "../src/SimpleFlashLoan.sol";

contract FlashLoanTest is Test {
    // Ethereum 主网地址
    address constant AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    SimpleFlashLoan flashLoan;

    function setUp() public {
        // Fork 以太坊主网
        vm.createSelectFork("https://eth.llamarpc.com");
        flashLoan = new SimpleFlashLoan(AAVE_PROVIDER);

        // 给合约一点 USDC 用于支付手续费（0.05%）
        deal(USDC, address(flashLoan), 1000e6); // 1000 USDC
    }

    function test_flashLoan() public {
        uint256 borrowAmount = 1_000_000e6; // 借 100 万 USDC

        uint256 balBefore = IERC20(USDC).balanceOf(address(flashLoan));
        flashLoan.initiateFlashLoan(USDC, borrowAmount);
        uint256 balAfter = IERC20(USDC).balanceOf(address(flashLoan));

        // 闪贷后余额应该减少（支付了手续费）
        assertLt(balAfter, balBefore, "should have paid premium");
        emit log_named_uint("Premium paid (USDC)", balBefore - balAfter);
    }
}
```

```bash
# 运行测试（需要网络访问用于 fork）
forge test --match-test test_flashLoan -vvv
```

**观察要点**：合约可以瞬间"借到"100 万 USDC，执行任意操作后归还，只需支付约 500 USDC（0.05%）的手续费。

### 任务 2：最简 Uniswap V3 Swap 回调合约

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 简化示意：展示 V3 swap 回调模式

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract SimpleV3Swap {
    // Uniswap V3 价格边界常量（与 AttackContract 相同）
    uint160 constant MIN_SQRT_RATIO_P1 = 4295128740;
    uint160 constant MAX_SQRT_RATIO_M1 =
        1461446703485210103287273052203988822378723970341;

    /// @notice 执行 V3 swap
    /// @param pool 池子地址
    /// @param zeroForOne 方向：true = token0 换 token1
    /// @param amountIn 输入数量
    function doSwap(
        address pool,
        bool zeroForOne,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        // 价格限制设为极值（不限制滑点，与 AttackContract 策略一致）
        uint160 limit = zeroForOne ? MIN_SQRT_RATIO_P1 : MAX_SQRT_RATIO_M1;

        // 调用 swap —— 池子会回调 uniswapV3SwapCallback
        (int256 a0, int256 a1) = IUniswapV3Pool(pool).swap(
            address(this),      // 输出代币接收者
            zeroForOne,
            int256(amountIn),   // 正数 = exact input
            limit,
            ""                  // 回调数据（这里不需要）
        );

        // 计算输出数量（负数 = 我们收到的代币）
        amountOut = zeroForOne ? uint256(-a1) : uint256(-a0);
    }

    /// @notice V3 swap 回调 —— 池子调用此函数收取输入代币
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /* data */
    ) external {
        // 正数 = 我们欠池子的代币，需要转账
        if (amount0Delta > 0) {
            address token0 = IUniswapV3Pool(msg.sender).token0();
            IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            address token1 = IUniswapV3Pool(msg.sender).token1();
            IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
        }
    }
}
```

**对比练习**：如果这是一个 V2 swap，代码会变成什么样？最大的区别是什么？

> 提示：V2 不需要 `uniswapV3SwapCallback` 函数，但需要在调用 `swap()` 之前先 `transfer` 输入代币到池子。执行顺序完全反转。

## 小结

闪电贷和 DEX 是 MEV 的两大基础设施。闪电贷的原子性保证让攻击者可以"无本万利"——AttackContract 用不到 3 美元的 wrsETH 作为起点，撬动了约 30.79 ETH 的利润。DEX swap 的确定性让 Searcher 可以在链下精确模拟利润，只在有利可图时才提交交易。

两者的回调机制共同塑造了 MEV 路由合约的架构：闪电贷回调是"外壳"（在回调中执行全部攻击逻辑），V3 swap 回调是"内壳"（在回调中完成代币转账）。不同协议的回调签名差异是选择器膨胀的根本原因——AttackContract 的 42 个函数中，核心逻辑几乎一样，但函数名各不相同。按参数类型（`uint256` vs `int256`）而非协议名称分派回调，是对这个问题的一种优雅工程解法。

**下一篇**：第 4 篇《MEV 路由合约设计——Lotus Router 源码精读》，我们将打开一个真实的 MEV 路由合约源码，从 `fallback()` 函数开始，逐行理解 Calldata 驱动 VM 的运行机制——指令循环、递归回调和 `findPtr()` 偏移恢复。
