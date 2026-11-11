# ensures-coverage

对Verus项目中的每个exec函数和proof函数 (pub和非pub), 检查postcondition是否提及了每个输出: 返回值, `#[verus_spec]`返回元组的每个分量, 每个`&mut`参数. 没有被提及的输出, 调用者调用之后对它一无所知, 没法接着证明. 工具先检查全部函数, 生成报告时再由审阅者用选择器挑出要看的函数.

设计 (为什么这样做, 每条规则的确切含义, 局限) 见[design.md](design.md). 本文说明怎样运行, 以及怎样读结果.

## 文件

| 文件 | 内容 |
|---|---|
| [design.md](design.md) | 设计: 问题, 原则, 设计结论, 注意 (局限), 经验 |
| [main.rkt](main.rkt) | 命令行入口和报告; 报告的全部文字都在其中的"text"一节 |
| [check.rkt](check.rkt) | 检查本身: 收集输出和提及, 得出结果 (只产出数据) |
| [results.rkt](results.rkt) | 结果文件的格式: 构造, 读写, 访问, 类型的Rust写法 |
| [select.rkt](select.rkt) | 选择器: 从结果中挑出要报告的函数 |
| [vir.rkt](vir.rkt) | 读Verus的`--log vir`输出 (`crate.vir`) |
| [items.rkt](items.rkt) | 调用`item-index`, 给函数取名, 找出函数的源码行 |
| [item-index/](item-index/src/main.rs) | Rust程序, 用`verus_syn`解析源文件, 输出每个函数的位置和所在的`impl`/trait |
| [contrib/pr-functions.rkt](contrib/pr-functions.rkt) | 审PR时的辅助脚本 (不属于工具本身): 列出PR涉及的函数 |
| [tests/](tests/run.sh) | fixture测试: 一个小的Verus crate, 每条规则对应几个函数, 以及期望的结果 (见"测试") |
| [.claude/skills/ensures-coverage/](.claude/skills/ensures-coverage/SKILL.md) | 给Claude Code的使用skill: 核对版本, 运行, 审阅报告, 汇报的流程 |

在本目录中运行Claude Code时, skill自动可用. 要在别的项目 (如vostd检出) 中使用, 把这个目录复制到`~/.claude/skills/ensures-coverage/`; 这时skill找不到工具目录, 使用时会询问本工具在本机的路径.

## 准备

在Windows 11 (Git Bash) 和Linux (WSL的Ubuntu 24.04) 上测试过, 两者对同一份VIR给出逐字相同的结果和报告. macOS没有测试过.

需要:

- **Racket** 9.x (在9.2上测试). 不需要预先编译: `racket main.rkt`每次运行时在内存中编译, 多花不到1秒. 也可以先运行`raco make main.rkt contrib/pr-functions.rkt`, 把编译结果存进`compiled/`; 这个目录与Racket版本绑定, 不要从别的机器拷过来.
- **Rust工具链** (`cargo`), 用来编译`item-index`.
- **一份已能用Verus验证的项目检出**, 下文记为`$SRC`, 例如[vostd](https://github.com/asterinas/vostd).

编译`item-index`:

```bash
cd item-index
cargo build --release
```

`verus_syn`从crates.io取, `item-index/Cargo.lock`把它固定为vostd `36e90fe19`所用Verus的版本. 离线时, 或者项目所用Verus的语法更新 (解析器报错, 见下文"警告"), 以及在CI中, 改用项目自带的那份:

```bash
cd item-index
P='patch.crates-io.verus_syn.path="<$SRC>/tools/verus/dependencies/syn"'
cargo update -p verus_syn --config "$P"
cargo build --release --config "$P"
```

`cargo update`一步不能省: 没有它, `Cargo.lock`中固定的版本优先, cargo只警告一句"patch ... was not used", 照样用crates.io上的旧版本编译. 它会改动`item-index/Cargo.lock`, 用完后可以`git checkout item-index/Cargo.lock`恢复. (2026-11以前`Cargo.toml`把版本写成`=...`, 项目自带的版本不同时这条patch从不生效.)

`check`默认使用`item-index/target/release/`中的`item-index`. 设了`CARGO_TARGET_DIR`时 (例如Windows上路径过长时设一个短的), 要在`check`的最后一个参数给出它的路径.

## Verus版本

`--log vir`的格式由Verus的`source/vir/src/ast.rs`派生 (`#[derive(ToDebugSNode)]`), 没有版本号, 也不保证稳定, 完全跟着Verus走; 过去一年中`ast.rs`平均每月改动8次左右, 其中约每一两个月就有一次涉及本工具读的部分. 所以用之前要核对Verus的版本.

本工具在下面这些Verus上验证过 (与已审阅的结果逐字一致, 或经人工核对):

| Verus (`verus --version`) | 提交 (asterinas/verus) | 日期 | 验证所用的项目 |
|---|---|---|---|
| `0.2026.10.25.ccf969f` | `ccf969f39f892d1f9fe44011187b4dbea835caf5` | 2026-10-25 | vostd `36e90fe19`, PR #706 #838 #870 (旧head) |
| `0.2026.10.28.e87a025` | `e87a0254cb2a7c425b431e40d687d3c16577830f` | 2026-10-28 | vostd PR #797 #802 #819 #854 #865 #870 (rebase后) |
| `0.2026.11.08.68d8005` | `68d80057bcbcf4a5e50c1a2ec2c0b3c092a7a4a6` | 2026-11-08 | vostd `8e4b202d6` (经人工核对, 见下) |

前两者之间`source/vir/src/ast.rs`和`printer.rs`没有改动. 到`0.2026.11.08`, Verus的`942817445` (Fix DefId -> Path collisions) 改了两处本工具读的名字, 旧版工具不报警告, 只给出错误的结果:

- VIR路径的每一段带上了命名空间: 模块, 类型和trait是`t%`, 消歧的名字是`tdis%N%`/`vdis%N%`, `extern`块是一整段`foreign_mod%N`, 例如`ostd::t%mm::t%frame::impl&%3::into_raw`. 旧版工具的结果中路径, 模块, 类型名都带着`t%`, 按模块的选择器 (`^ostd::mm`) 一个函数也选不中. 现在由`vir.rkt`的`path->text`去掉它们, 结果中的路径与以前相同; 查找函数时仍用原始路径.
- 未起名的返回值从`%return`改名为`return%`. 旧版工具把它当作名字写进报告.

核对的办法: 同一份VIR上改前改后的结果去掉前缀后, 除推断的函数名有几处改善 (`Option::from_bits`变成`PageTableFlags::from_bits`) 外逐行相同; design.md结论22的例子中仍存在的两个函数与旧结果逐字一致; `ostd::mm`和`ostd::sync`的pub函数571个, 报告164条 (`36e90fe19`上是572个, 177条); 抽查的报告与源码一致. 两处改名现在都有警告 (结论24).

vostd总是跟着最新的Verus验证, 所以要留意的主要是**新版本**: vostd每次升级Verus之后, 新版本就落在上表之外, 要先按下面的办法核对, 确认后再加进上表. **第一步总是用新Verus跑一遍fixture测试** (见"测试"): 它检查的是工具的行为, 不论变化出在Verus的哪个文件; 下面的源码diff只能帮助理解失败的原因. 例如`%return`改名为`return%`发生在`def.rs`, 只看下面列出的三个文件会漏掉它, 而fixture测试会失败. 下文的格式检查 (design.md结论24) 只能发现某个名字整个消失了, 字段的含义变了或出现了新的写法 (例如`final`改用`MutRefFinal`表示) 它都发现不了. 审PR时merge-base可能需要比head更早的Verus, 两边要分别核对.

已知**不能用**的: `0.2026.09.03.21b580b` (vostd `8dd86cda1`). 那时返回值参数在VIR中叫`:ret` (2026-10-07的`ce82df44`才改名为`:outer_ret`), 检查会漏掉全部返回值; `check`对此会警告. `item-index`所用的`verus_syn`是crates.io上的`0.0.0-2026-09-06-0133`, 能解析这两个版本的vostd.

查看项目所用的Verus:

```bash
$SRC/tools/verus/source/target-verus/release/verus --version
git -C $SRC/tools/verus log -1 --format='%H %cd' --date=short
```

不在上表中时, 先看`ast.rs`中本工具依赖的部分有没有变 (`<old>`取上表中最近的提交):

```bash
git -C $SRC/tools/verus diff <old> <new> -- source/vir/src/ast.rs source/vir/src/printer.rs source/vir/src/def.rs source/builtin_macros/src/syntax.rs
```

本工具依赖的VIR名字 (design.md中对应的结论):

- `FunctionX`的字段: `name`, `mode`, `kind`, `visibility` (`restricted_to`), `owning_module`, `params`, `outer_ret`, `ensure` (两个列表, 结论15), `returns`, `attrs` (`is_external_body`).
- `FunctionKind::TraitMethodImpl`的`method`, `trait_path`, `trait_typ_args`, `inherit_body_from` (结论3, 13, 14).
- `DatatypeX`的`user_defined_invariant_fn` (`FunWithVis`的`fun`, 结论17).
- `UnaryOp::MutRefFuture` (结论9). **`UnaryOp::MutRefFinal`**是`final`关键字改写之前的形式, 本工具不认; 它若出现在导出的VIR中, 所有`&mut`参数都会被报告为未提及.
- 变量: `PlaceX::Local`, `ExprX::Var`, `VarIdent` (结论11); 返回元组: `StmtX::Decl`的`pattern`和`init`, `PatternX::Constructor`/`Var` (结论8).
- 类型: `TypX`的`Bool`, `Int`, `TypParam`, `MutRef`, `Decorate`, `Datatype` (`Dt::Path`/`Dt::Tuple`), `Projection`, `Primitive` (结论7, 17, 22).
- Verus生成的名字: `_VERUS_VERIFIED_` (结论2), `_VERUS_ret_ident` (返回元组, 结论6), `return%` (未起名的返回值, 结论8; `0.2026.11.08`以前是`%return`), `Self%`.
- 路径段的命名空间前缀: `t%`, `tdis%N%`, `vdis%N%`, `foreign_mod%N`, 以及`impl&%N` (`vir.rkt`的`path->text`). 出现了别的前缀时, `check`会警告模块路径中有认不出的段.

这些都没变, 一般就可以用; 改了就要先修改`check.rkt`. 最可靠的办法是对一个已有结果的提交用新Verus重跑, 与旧结果比较. 验证了新版本后, 把它加进上表.

## 测试

`check`按名字读VIR, VIR的格式变了时它不会出错, 只会给出错误的结果. fixture测试用来及时发现这一点: [tests/fixture/fixture.rs](tests/fixture/fixture.rs)是一个小的Verus crate, design.md的每条规则 (结论1到17) 对应几个函数, 有该报告的也有不该报告的, 注释写明期望; [tests/expected.results](tests/expected.results)是期望的结果文件.

```bash
VERUS=$SRC/tools/verus/source/target-verus/release/verus \
VERUS_Z3_PATH=$SRC/tools/verus/source/z3 \
tests/run.sh
```

脚本用给定的Verus验证fixture并导出VIR (几秒), 再运行`check`, 与期望的结果逐字比较. 下面任何一种情况都算失败:

- Verus没有验证通过fixture (Verus的语法变了, 先改fixture);
- `check`在stderr上有任何输出 (结论24的警告);
- 结果与期望不同. 这说明VIR的格式或工具的行为变了: 先读diff, 弄清原因, 修改`check.rkt`使结果恢复; 只有确认新结果才是对的 (例如有意修改了规则或fixture) 时, 才用`tests/run.sh --update`重写期望的结果, 并在提交中说明.

每次换Verus版本, 以及每次修改`check.rkt`, `vir.rkt`, `items.rkt`或`item-index`之后都要跑. 用`0.2026.11.08`以前的工具在`0.2026.11.08`上跑, 这个测试会失败 (路径带`t%`, 返回值名为`return%`), 而工具本身没有任何警告.

fixture只覆盖其中写到的写法. 给工具新增或修改规则时, 同时在fixture中加上对应的函数.

## 运行

### 1. 导出VIR

用Verus的`--log vir`选项导出, 每个要检查的crate各导出一份 (design.md结论18). **要在`$SRC`中运行**, 这样VIR中的源文件路径是相对于`$SRC`的. 对vostd, 用`--no-verify`只导出不验证, 每个crate约20到40秒:

```bash
cargo dv focus --package ostd -- --no-verify --log vir --log-dir <log-dir>
```

`vstd_extra`等其他crate同样用`--package`分别导出. `dv`的命令行随vostd的版本而变 (2026年9月的vostd用`--targets ostd`), 报错时先看`cargo dv focus --help`. 改了别的架构的代码时加`--target` (如`--target loongarch64-unknown-none-softfloat`), 否则被`cfg`掉的代码不在VIR中.

**注意cargo-verus的缓存.** 源码内容没有变化时, cargo-verus直接用缓存, 照样以退出码0打印"Verified", 这时`--log vir`什么也不写, `<log-dir>`根本不会被创建 (只改`--log-dir`不会让缓存失效). 所以每次用一个新的`<log-dir>`, 导出后确认`<log-dir>/crate.vir`存在. 不存在时, 删掉该crate的fingerprint再导出:

```bash
rm -rf <target>/verus-partial/x86_64-unknown-none/debug/.fingerprint/ostd-<hash>
```

`<target>`是`CARGO_TARGET_DIR`, 没设时是`$SRC/target`; 只删`ostd-<hash>`这一个目录 (`ostd-pod-<hash>`等是别的crate). `cargo clean -p ostd`删不到它.

工具假定项目在这个提交上验证通过; 验证要另外运行. 同样因为缓存, 在`--no-verify`导出之后紧接着验证, 会不经验证就打印"Verified". 本次输出中有`verification results:: N verified, M errors`一行, 才说明真的验证了.

### 2. 检查

```bash
racket main.rkt check <log-dir>/crate.vir ostd.results $SRC
```

- 第一个参数可以是用逗号分隔的多份VIR, 每个crate一份, 结果写进同一个文件: `ostd.vir,vstd_extra.vir`.
- 读`crate.vir`文本要20秒左右 (vostd的`ostd`, 100MB). 要反复检查同一份VIR时, 可以先缓存为fasl, 之后把`.fasl`文件当作VIR传给`check`:

  ```bash
  racket main.rkt cache <log-dir>/crate.vir ostd.fasl
  ```

- `$SRC`的源码要与导出VIR时一致, 因为函数名按源码位置对应. 本地有改动时, 可以取出一份干净的源码, 把`<dir>`作为这里的`$SRC`:

  ```bash
  git archive <commit> ostd verified_libs | tar -x -C <dir>
  ```

- 最后一个参数可选, 是`item-index`的路径 (见"准备").

`check`写出结果文件, 并在stdout上给出检查的函数数和解析器找不到的函数数; 输入有问题时在stderr上警告 (见"警告").

### 3. 生成报告

```bash
racket main.rkt report ostd.results ostd.md <选择器>
```

同一份结果可以按不同选择器多次生成报告. 选择器的完整语法见design.md结论20, 常用的:

| 要看的函数 | 选择器 |
|---|---|
| 全部 | `all` |
| 一个模块 | `'^ostd::mm'`, 即`'(module "^ostd::mm")'` |
| 一个模块中的pub函数 | `'(and (module "^ostd::mm") pub)'` |
| 一个文件 | `'(file "^ostd/src/mm/tlb[.]rs$")'` |
| 几个函数 | `'(or (name "^PageTable<C>::empty$") (name "^TlbFlusher<.a>::new$"))'` |
| 一段源码中的函数 | `'(lines "ostd/src/mm/tlb.rs" 40 120)'` |
| 文件中列出的选择器 (用`or`组合) | `@functions.txt` |

正则表达式中的`\`要写成`\\`, 匹配`.`可以写成`[.]`. 选择器中有`"`: Windows PowerShell 5.1把参数传给程序时会弄乱其中的双引号, cmd不认单引号; 在Windows上用Git Bash, 或者把选择器写进文件, 传`@文件名`.

### 审PR

工具不判断一个PR改动了哪些函数, 由审阅者决定 (design.md结论19). 可以读过PR后自己把要看的函数写进文件传`@文件名`, 也可以用辅助脚本机械地列出PR涉及的函数: 在PR head (CI中是PR的合并提交) 上检查一遍全部函数, 再

```bash
racket contrib/pr-functions.rkt head.results <PR的git worktree> <merge-base> pr.results [base.results]
racket main.rkt report pr.results pr.md all
```

它选出这几类函数, `pr.results`中每个函数后面的注释写明它属于哪一类:

- changed: 整个条目 (属性, 规格, 签名, 函数体) 与`git diff <merge-base>...HEAD`有交集. 解析器找不到的函数 (注意9, 如`derive`生成的) 没有源码行, 按VIR中的行判断.
- decl: trait方法的实现, 其声明是changed. 实现的postcondition来自声明 (结论13), 声明一改, 实现的结果就可能变, 即使实现本身一行没动.
- new: 只在给了`base.results` (merge-base上的检查结果) 时才有: head上有而merge-base上没有的函数, 按模块和函数名比较 (函数改名或移动模块也算new).

在vostd 2026年11月的4个PR (#883 #897 #900 #855, 选中3到48个函数, 报告0到3条) 上试过: changed和decl已经选出了new的全部函数, 不需要merge-base上的检查; 与diff有交集而没有被选中的部分都是`use`, 文档注释, spec函数, 被删除的函数, 不在`verus!`中的代码, 以及被`cfg`掉的其它架构的代码. decl是必要的: #897改了`NonNullPtr`的声明, 有7个实现本身一行没动, 只由decl选出.

**已知的两个缺口** (都不报错, 只是漏选; 还没有在真实PR上量过漏了多少):

1. **其它架构的代码.** VIR只含导出时所选target的代码 (注意7). vostd在x86_64, riscv64, loongarch64上验证; 只导出x86_64时, PR改动`arch/riscv`, `arch/loongarch`, `specs/arch/riscv`等处的函数根本不在结果中 (如#879). 要按PR改动的架构分别用`--target`导出, 或者三个都导出.
2. **其它crate.** 只导出`ostd`时, PR改动`vstd_extra`等crate (如#819) 中的函数不被检查. 更隐蔽的是decl不跨crate: 改了`vstd_extra`中的trait声明 (如`Repr`, `InvView`) 时, `ostd`中的实现一行没动就选不出, 因为声明不在结果中. 要把改动的crate也导出, 一起传给`check` (结论18).

按设计不选的: spec函数的改动 (如`is_device_address`的函数体从`true`改成`d <= MAX_PADDR`) 改变了依赖它的规格的含义, 但不改变"是否提及"某个输出, 所以不选依赖它的函数, 与工具本身的含义一致. 还没有在样本中出现, 因而没有验证过的: 函数改名或移动, 宏生成的函数, 移进`verus!`而缩进不变的代码.

### 在CI中运行

计划接入vostd的CI. 方针:

- 报告只是提示, 不拦截PR, 也不考虑拦截. 只报告PR涉及的函数 (上一节的选取), 而不是比较前后报告的增减.
- 先跑fixture测试 (见"测试"); 失败时这一次ensures-coverage直接停止, 不检查也不报告. 停止本身要让人看到: PR上只在job summary中写一行, push到main时让这个job失败, 由维护本工具的人去修.
- 每个PR只导出一份VIR: 合并提交 (`refs/pull/N/merge`) 的. base是`github.event.pull_request.base.sha`, 用于`git diff`, 不需要导出.
- vostd的CI每次都用asterinas/verus的最新HEAD, 不按vostd的提交固定Verus, 所以fixture测试和检查要在同一个job中, 用同一份`tools/verus`.
- 在CI中编译`item-index`时用项目自带的`verus_syn` (见"准备"), 它总与Verus的语法一致.

**资源消耗** (2026-11-10在WSL上实测, vostd `ostd`, PR #883的合并提交; 没有在CI的runner上测过):

| 步骤 | 用时 | 峰值内存 | 备注 |
|---|---|---|---|
| 导出VIR, 冷启动 (新的`CARGO_TARGET_DIR`) | 1分20秒 | 约1.0GB | 含从头编译依赖, 平均约3.5个核; `target`约1.3GB, `crate.vir` 111MB |
| 导出VIR, 同一`target`再导出 | 约17秒 | | |
| `check` (读VIR文本) | 18秒 | 约380MB | 结果文件300KB |
| `contrib/pr-functions.rkt` | 0.5秒 | 约130MB | |
| `report` | 0.9秒 | | |

在4核16GB的GitHub runner上, 导出估计在2分钟上下. 单独的job还要恢复Verus的缓存 (`tools/verus`去掉`.git`和`source/target`约2GB), 安装Racket, 编译`item-index` (后两者可以缓存), 估计整个job 3到5分钟, 与verify并行, 不拖慢PR. 每多导出一个架构或crate, 多一次导出和`check`, 约20秒到1分钟.

## 怎样读结果

### 报告

报告 (Markdown) 开头是汇总, 然后把选中的函数分成两组: **有postcondition的函数**和**没有postcondition的函数** (只有`requires`也算没有). 每个有报告的函数一节, 每个未被提及的输出一条. 最后"选中的函数"一节列出选中的全部函数和各自的报告数, 不论有无报告.

**怎样算"提了".**

- 返回值: postcondition里出现了返回值的名字, 或者写了`returns`. 没有起名的返回值 (`-> T`而不是`-> (r: T)`) 只能靠`returns`.
- `&mut`参数`x`: postcondition里某个`final(...)`中出现了`x`. 只写`old(x)`不算, 因为那说的是调用前的`x`.
- trait方法的实现: trait声明的`ensures`/`returns`也算 (实现会继承它们), 但`default_ensures`不算 (覆盖了默认实现就得不到它).

**一条报告是什么意思.** 只是"这个值没被提到", 不一定是错. 常见的不是错的情况:

- 作者故意不承诺什么;
- 这个值马上就被丢掉了;
- 规格换了个地方说它, 比如通过返回值 (返回值借用了`&mut`参数), 或者通过一个ghost模型. 工具看不出这种间接的说法.

在vostd上的经验是: 报告与源码都一致, 其中约四分之一是真缺陷 (design.md"经验").

**没有报告也不代表规格写全了.** 只要提到一次就算提了, 哪怕只写了`final(x).inv()`, 或者只在某个分支里提到; 条件式的`ensures`即使条件恒假也算.

**工具看不到的.** 不经过`&mut`参数的修改 (`PCell`, 原子量, 全局变量等), 嵌套的`&mut` (如`Option<&mut T>`), 按值传入后不再交还的tracked参数. 完整的局限见design.md"注意".

**报告里的标注.**

- **非pub**: 调用者都在本crate中且已验证通过, 一条报告更可能说明这个值没有被用到, 或者规格只写了现有调用者够用的部分; 新写调用者时同样会缺这些事实.
- **只有类型不变量**: 调用者只知道这个值本身合法, 不知道它和参数, 和调用前的状态有什么关系. 只看最外层的类型, 所以`Option<Frame>`这样的输出即使`Frame`有不变量也注明为"无任何约束".
- **只在`default_ensures`中提及**: 只有沿用trait默认实现的类型才保证这一点, 经由trait泛型调用时得不到.
- **postcondition来自trait声明X**: 这是trait方法的实现, 规格来自trait的声明. 要补规格, 可以在实现上加`ensures`, 也可以改声明. 没有附加任何子句的实现, 结果与声明相同: 声明也在报告中时只随声明报告一次; 否则同一方法的多个实现合并为一节.
- **`external_body`**: 函数体没有验证过, 规格是被信任的.
- **名称由VIR推断**: 解析器没找到这个函数 (如`#[derive(Clone)]`或宏生成的函数), 名字是由VIR推断的, 它也没有源码行, `lines`选择器选不到它.

**看到报告后怎么办.** 先想一想调用者需不需要知道这个值. 需要就补一条`ensures`. 如果函数其实不改`x`, 就写上`*final(x) == *old(x)`. 最可靠的确认方法是按真实用法写一个调用者, 看它能不能证下去.

### 结果文件

结果文件 (`.results`) 是紧凑的S表达式, 每个检查过的函数一行, 只记事实, 格式见design.md结论22. 它便于直接阅读, 也便于别的工具 (或LLM) 使用. 结果文件不依赖本机, 可以拷到别的机器上生成报告; 开头的`(vir ...)`只是记录, `report`不读它.

## 警告

`check`在输入与预期不符时只在stderr上警告, 照常写出结果 (design.md结论24). 看到警告时, 结果可能不可信或不完整:

| 警告 | 含义和处理 |
|---|---|
| `...; the VIR format may have changed` | VIR中找不到检查所依赖的节点或字段名. 多半是Verus升级改了VIR格式, 结果不可信. 需要按新格式修改`check.rkt`. |
| `source file(s) are named by absolute paths in the VIR` | 导出VIR时不在`$SRC`中运行. 在`$SRC`中重新导出. |
| `source file(s) are not found under ...` | `$SRC`不是导出VIR的那份源码, 或者给错了目录. |
| `item-index: FILE:LINE:COL: ... parse error` | 解析器解析不了这个文件, 其中的函数没有源码行. 多半是`verus_syn`的版本旧于项目所用的Verus, 按"准备"改用项目自带的那份重新编译. |
| `N of them not found by the source parser` | 不是警告: 宏和`derive`生成的函数本来就找不到 (vostd的`ostd`约200个, 大多来自`bitflags!`). 占了大半时, 源码或解析器与VIR不符. |

换了Verus版本后, 最好先对一个已有结果的提交重跑一遍, 与旧结果比较.
