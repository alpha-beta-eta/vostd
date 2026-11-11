# ensures-coverage 的设计

## 问题

在Verus中, 调用者对一次调用的结果所知道的, 只有被调用函数的postcondition. 如果函数有一个返回值, 或者会修改某个`&mut`参数, postcondition却对它一字未提, 调用者调用之后就对它一无所知, 没法接着证明.

验证器发现不了这种缺陷: 函数本身照样验证通过, 要等到有人写调用者时才会暴露. 而在正在开发的已验证代码中, 很多API还没有已验证的调用者. 本工具机械地找出这样的输出, 作为审阅规格时的信号.

## 设计原则

1. 只读函数签名和规格, 以及其他所需的Verus元数据, 不涉及函数体.
2. 根本做法: 判断函数是否有返回值或`&mut`参数没有被postcondition提及.
3. 设计尽可能简单, 只做简单和容易理解的分析. 工具只给出信号, 是否是缺陷由人判断.

## 设计结论

下文中"结论N"指本节的第N条, "注意N"指下一节的第N条; 代码注释也这样引用.

### 检查哪些函数

1. 检查全部exec函数和proof函数, 不含spec函数, pub和非pub都检查 (报告时再按结论20筛选). proof函数的调用者对tracked返回值和tracked `&mut`参数的了解同样只来自postcondition, 检查方法相同. 非pub函数在报告中注明"非pub": 它的调用者都在本crate中, 而crate已经验证通过, 所以一条报告不意味着现有调用者证不下去, 更可能是这个输出没有被用到, 或者规格只写了现有调用者够用的部分; 新写调用者时同样会缺少这些事实.
2. `#[verus_spec]`生成的两份函数, 只检查带真正规格的`_VERUS_VERIFIED_`版本. 另一份是`requires false`, 只供未验证的调用者使用.
3. 实现没有覆盖的trait默认方法不作为实现检查: 调用时执行的是声明的函数体, 规格也是声明的, 已经作为声明本身检查过 (结论4). Verus为这样的实现生成的副本 (VIR中`:inherit_body_from`非空) 直接跳过.
4. trait方法的声明本身也检查, 即使它没有默认函数体: 调用者可能经由trait泛型调用它, 依据的就是声明的规格.
5. `external_body`函数照常检查, 在报告中注明: 函数体未经验证, 但调用者同样依赖它的规格.

### 输出

6. 输出有三种, tracked和ghost的输出与exec的输出同样对待:
    - 返回值. 剥掉`Tracked`等包装; 返回unit时不算输出.
    - `#[verus_spec]`的返回元组: 第0个分量是exec返回值, 其余是`with`子句中`-> ...`声明的幽灵返回值. 每个分量单独作为一个输出, unit分量跳过. (幽灵返回值往往是调用者继续证明所需的资源, 合起来算会让一个分量的提及掩盖另一个分量的未提及.)
    - `&mut`参数 (结论7).
7. `&mut`参数指剥掉`Tracked`等包装后, 类型的最外层是`&mut`的参数, 包括tracked `&mut`参数. 嵌套在其它类型中的`&mut`不看, 如`Option<&mut T>`, 元组, 按值传入而内部装着`&mut`的结构体. (由原则3.)

### 什么算提及

8. 返回值被提及, 当且仅当它的名字出现在postcondition中 (位置不限), 或者有`returns`子句.
    - 返回值的名字是规格给它起的名字, 如`-> (r: T)`或`#[verus_spec(r => ...)]`中的`r`. 没有起名的返回值在VIR中叫`return%` (2026年11月以前的Verus中叫`%return`), 不可能被提及, 报告中不写名字.
    - `#[verus_spec]`返回元组各分量的名字取自postcondition中的元组模式, 如`(res, owner)`, 按位置对应. 在VIR中, 这是一个以返回变量为初值的`let`; 只认这一种元组模式.
    - `returns e`是`ensures r == e`的简写, 只算exec返回值 (元组的第0个分量) 被提及.
    - 函数体中被返回的表达式不看 (原则1).
9. `&mut`参数`x`被提及, 当且仅当`x`出现在postcondition的某个`final(...)`之中, 位置不限, 例如`final(x)`, `final(x).inv()`, `final(x)@.len()`, `final(x.f)`, `final(*x)`. `old(x)`和单独出现的`x`都不算: 它们说的是调用前的`x`. 在VIR中`final(...)`是`UnaryOp MutRefFuture`, vstd内部的`mut_ref_future(e)`也是它, 一并算. 除`final(...)`之外, 可能还有别的写法也能描述`x`调用后的值, 本工具一律不认. (由原则3: 只认`final`这一种句法形式.)
10. 只看直接提及. `&mut`参数`x`调用后的状态没有被postcondition直接提及, 就报告为未提及, 而不考虑`x`的借用是否流入返回值, postcondition是否借由返回值间接描述了`x`. (由原则2, 3: 判断间接描述需要分析生命周期, 还要理解关于返回值的规格的含义, 不是简单的分析.)
11. 变量按VIR的`VarIdent`比较. 它带有rustc给每个绑定的编号, 所以`forall |x|`等绑定的同名变量不会被当成参数`x`. 变量在VIR中有`(Place Local x)`和`(> Var x)`两种写法, 后者出现在Verus自动生成的规格中, 两种都识别.

### 调用者能用的postcondition

12. 函数**有postcondition**, 当且仅当调用者能用的postcondition子句至少有一条; 否则**没有postcondition**. 报告按这一点分为两组, 检查本身不受影响: 没有postcondition的函数照样检查, 它的每个输出都报告为未提及.
    - 调用者能用的子句: 函数自身的`ensures`和`returns`; trait方法的实现再加上声明的`ensures`和`returns`, 不含`default_ensures` (结论13). 声明在VIR中找不到时, 只按实现自身的子句判断, 并在报告中注明.
    - `requires`, `recommends`, `decreases`等不描述调用后的状态, 不算. 只有`requires`的函数没有postcondition.
    - 类型不变量属于类型而不属于函数, 不算; 受它约束的输出按结论16注明.
    - Verus自动生成的`ensures` (如`#[derive(Clone)]`的规格) 在VIR中就是`ensures`, 算.
    - 只看子句是否存在, 不看内容: `ensures true`和条件式的`obeys_xxx() ==> ...`都算有postcondition. (由原则3.)
13. trait方法的实现, 其postcondition是trait声明的`ensures`和`returns` (不含`default_ensures`) 加上实现自己附加的子句, 两者合起来判断是否提及. 声明中的参数名和返回值名按位置换成实现的. (由原则2: 调用者能用的是两部分的合取; 只看实现自己的部分, 会把声明已经提及的输出误报为未提及.) Verus只把`default_ensures`给予沿用默认函数体的实现, 覆盖了该方法的实现不继承它; 而`returns`在Verus内部被并入`ensures`, 所以会被实现继承.
14. trait方法实现的声明: 按实现在VIR中的`:method`路径查找, 先找它的`_VERUS_VERIFIED_`版本, 找不到再用普通版本.
15. VIR中的`:ensure`由两个表达式列表组成: 第一个是`ensures` (含`returns`), 第二个是`default_ensures`, 后者只能出现在带默认函数体的trait声明上. 检查trait声明本身时, `default_ensures`不算提及, 也不算postcondition子句 (结论12): 声明按经由trait泛型调用的调用者所知来检查, 而这些调用者得不到`default_ensures`. 但某个输出若只在`default_ensures`中被提及, 就在报告中注明"只在`default_ensures`中提及": 沿用默认函数体的实现的调用者知道它, 而这些实现按结论3不单独检查.

### 类型不变量

16. 有类型不变量 (`#[verifier::type_invariant]`) 的输出, 未被提及时仍报告为未提及, 只在报告中注明"只有类型不变量". 不变量只说明这个值本身合法, 不说明它与参数或调用前的状态有什么关系. (由原则1, 2: 是否有类型不变量是类型的元数据, 可以读; 但它不是postcondition中的提及.)
17. 输出的类型不变量: 剥掉包装和`&mut`后, 看最外层的类型在VIR的`Datatype`中是否有`user_defined_invariant_fn`.

### 输入, 流程和产物

18. 输入是Verus的`--log vir`导出的`crate.vir` (S表达式文本), 用Racket的`read`加一个readtable读入, 可以缓存为fasl; 检查用Racket实现. 每个crate要分别导出: 一个crate的VIR中也有它用到的依赖crate的函数, 但只是其中一部分, 也只有pub的. VIR中没有直接标明函数是否从依赖导入, 本工具这样判断: 一份VIR中某个crate有非pub函数, 这份VIR就是该crate自己的; 每个函数只从它的crate自己的VIR中取, 有多份时取含该crate函数最多的那份. 因此全部函数都是pub的crate不会被检查; 只给`ostd`的VIR时, `vstd`, `vstd_extra`等依赖的函数不会混进来.
19. 先检查全部函数, 再用选择器从结果中挑出要报告的函数. 检查本身很快 (vostd的`ostd`约1500个函数, 几秒), 先选再查没有好处; 先查后选, 一份结果可以按不同条件反复筛选. 所以分两步: `check`检查一份或多份VIR中的全部函数, 写出结果文件 (结论22); `report`按选择器筛选结果, 展开成可读的报告 (结论23). 要报告哪些函数由审阅者决定, 工具不去推断, 例如不根据git diff猜测一个PR改动了哪些函数. (`contrib/pr-functions.rkt`是审阅者一方的辅助脚本, 不属于工具本身.)
20. 选择器是S表达式:
    - `(module RX)`: `owning_module`匹配正则表达式RX. 单独一个字符串`RX`等同于它; 命令行上不以`(`, `"`或`@`开头的文字也当作模块正则.
    - `(path RX)`: VIR中的函数路径 (去掉`_VERUS_VERIFIED_`) 匹配RX.
    - `(name RX)`: 报告中的函数名 (结论21) 匹配RX, 如`(name "^TlbFlusher<'a>::")`.
    - `(file RX)`: 源文件路径 (相对于源码根目录, 用`/`) 匹配RX.
    - `(lines FILE A B)`: 函数的源码行与FILE的第A到B行有交集.
    - `pub`, `exec`, `proof`, `all`.
    - `(and S ...)`, `(or S ...)`, `(not S)`.
    - 命令行上的`@FILE`读入文件中的一个或多个选择器, 多个时用`or`组合, 便于列出一批函数.

    选择器只用位置和名字这些元数据, 不分析函数体的内容 (原则1). spec函数和沿用的trait默认方法不检查 (结论1, 3), `#[verus_spec]`的两份函数只检查一份 (结论2), 所以选择器也选不到它们.
21. 函数名和函数的源码行由源码解析器`item-index`给出: 按VIR中的源码位置, 找到源文件中同名, 且行范围包含该位置的函数, 以及它所在的`impl`块或trait. VIR中函数的位置只有签名; 解析器给出的是整个条目的行: 属性 (含`#[verus_spec]`), 签名, 规格和函数体. 解析器只读签名和位置.
    - 解析器用Verus版的syn (`verus_syn`). `verus!`宏在解析之前先用`rejoin_tokens`把一些token合并 (如`!is`变成`isnt`, `!has`变成`hasnt`), 解析器也要这样做, 否则用了这些写法的文件整个解析失败.
    - `verus_syn`的版本要能解析项目所用的语法.
    - 解析器找不到的函数, 用由VIR推断的名字, 并注明; 它没有源码行, `lines`选不到它 (注意9).
    - 源码须与导出VIR时一致, 因为函数按源码位置对应.
22. 检查的直接输出是紧凑的S表达式, 只记事实; 一切可读的说法 (类型的Rust写法, 分组, 合并, 说明文字) 都由报告从它展开. 结果文件是一串顶层表: 先是`(vir PATH ...)`, 记下来自哪些VIR, 只作记录, `report`不读它; 然后每个检查过的函数一个`fn`表, 一行一个. 有报告和没有报告的函数都在其中. 结果文件不依赖本机, 可以拷到别处生成报告.

    ```
    (fn PATH MODE (name NAME [inferred]) (at FILE LINE) [(lines START END)] [(module MODULE)]
        [private] [external-body] [(trait DECL [missing])] [(post SOURCE ...)] [(outs N)]
        FINDING ...)
    ```

    - `PATH`: VIR中的函数路径 (去掉`_VERUS_VERIFIED_`), 字符串. `MODE`: `exec`或`proof`.
    - `(name NAME)`: 报告中的函数名 (结论21); 由VIR推断时加`inferred`.
    - `(at FILE LINE)`: VIR中的位置 (签名所在行). `(lines START END)`: 解析器给出的整个条目的行, 解析器找不到时省略.
    - `(module MODULE)`: `owning_module`. 与由`PATH`推出的模块 (去掉最后一段, 再去掉末尾的`impl&%N`) 相同时省略.
    - `private`: 非pub (结论1). `external-body`: 结论5.
    - `(trait DECL)`: trait方法的实现, DECL是声明的路径 (结论14); 声明不在VIR中时加`missing` (结论12).
    - `(post SOURCE ...)`: 调用者能用的postcondition子句来自哪里 (结论12, 13), SOURCE是`own` (函数自身的`ensures`或`returns`) 或`decl` (trait声明的). 省略表示没有postcondition.
    - `(outs N)`: 输出的个数 (结论6), 0时省略.
    - 每个未被提及的输出一个FINDING (结论6, 8, 9):
        - `(ret NAME TYPE FLAG ...)`: 返回值. NAME是规格给它起的名字, 没有起名时为`#f`.
        - `(ret-part I NAME TYPE FLAG ...)`: `#[verus_spec]`返回元组的第I个分量.
        - `(mut NAME TYPE FLAG ...)`: `&mut`参数.
        - FLAG: `ghost` (tracked或ghost), `(inv PATH)` (只有类型不变量, PATH是不变量函数, 结论16), `default-only` (只在`default_ensures`中提及, 结论15).
    - TYPE是类型的紧凑形式: 原始类型, 类型参数, 不带参数的数据类型写成符号 (`u64`, `T`, `Self`, `Frame`); 带参数的数据类型和`Tracked`等包装写成`(Name T ...)`; 另有`(& T)`, `(&mut T)`, `(tuple T ...)` (单元类型是`(tuple)`), `(slice T)`, `(as SELF TRAIT NAME)` (关联类型`<SELF as TRAIT>::NAME`, TRAIT也按类型的形式写), 认不出的类型是`?`. 数据类型只记路径的最后一段. (因此名为`tuple`, `slice`的数据类型会与这些形式混淆; Rust的类型名一般不会是这样.)

    例如 (取自vostd):

    ```
    (fn "ostd::mm::tlb::impl&%0::dispatch_tlb_flush" exec (name "TlbFlusher<'a>::dispatch_tlb_flush") (at "ostd/src/mm/tlb.rs" 110) (lines 95 151) external-body (post own) (outs 2) (mut "self" (&mut TlbFlusher)))
    (fn "ostd::cpu::all_cpus" exec (name "ostd::cpu::all_cpus") (at "ostd/src/cpu/mod.rs" 134) (lines 118 147) (post own) (outs 1))
    (fn "ostd::io::io_mem::allocator::impl&%0::new" exec (name "IoMemAllocator::new") (at "ostd/src/io/io_mem/allocator.rs" 122) (lines 112 124) private (outs 1) (ret #f IoMemAllocator (inv "ostd::io::io_mem::allocator::impl&%3::type_inv")))
    ```

    第一个函数有postcondition, 但没有提及`&mut self`调用后的状态; 第二个没有报告; 第三个是非pub函数, 没有postcondition, 返回值没有名字, 只受类型不变量约束.

    (由原则3: 检查只产出事实, 说法只在一处; 结果文件也便于人直接读, 便于别的工具使用.)
23. 报告用中文, Markdown格式:
    - 开头: 结果中的函数总数, 选择器, 选中的函数数 (按exec/proof和pub/非pub分别计数), 以及两组 (结论12) 各自的函数数, 输出数和报告数. 报告数按"返回值未被提及"和"`&mut`参数调用后的状态未被提及"两类, 每类再分"无任何约束"和"只有类型不变量".
    - 正文按两组分开. 组内按源码位置排序, 每个有报告的函数一节, 写明函数名和源码位置; 每个未被提及的输出一条, 写明: 输出是返回值, 返回元组的第几个分量, 还是`&mut`参数; 它的名字, 类型, 是否为幽灵值. 适用时加注: 非pub (结论1), `external_body` (结论5), postcondition来自哪个声明 (结论13), 未找到声明 (结论12), 只有类型不变量 (及不变量名, 结论16), 只在`default_ensures`中提及 (结论15), 名称由VIR推断 (结论21).
    - trait方法的实现若没有附加任何postcondition子句, 其结果与声明相同. 声明也在报告中时, 只随声明报告一次, 不逐个实现重复; 声明不在报告中时 (如标准库trait的声明不被检查, 或者被选择器筛掉了), 同一trait方法的多个实现合并为一条, 列出各实现的位置. (由原则3: 这只是对报告的合并, 不需要额外分析.)
    - 最后列出选中的全部函数, 不论有无报告, 写明位置和报告数, 以便知道检查了哪些函数. 随声明报告而不单独列出的实现也在其中.
    - 每种报告和标注的说明文字只在代码中的一处定义.
24. 检查按名字匹配VIR的节点和字段, 而`--log vir`的格式是Verus的内部格式, 不保证稳定; 名字变了时检查不会出错, 只会给出错误的结果. 输入与预期不符时同样如此. 所以`check`在stderr上警告这些情况, 但照常写出结果:
    - VIR中找不到检查所依赖, 而任何真实crate都会用到的名字: `Function`节点的字段 (含`:outer_ret`), 参数的`:name`, `:typ`, `:mode`, `:ensure`的两个列表 (结论15), `MutRefFuture` (结论9), `TraitMethodImpl`的`:method`, `:trait_path`, `:trait_typ_args`, `:inherit_body_from` (结论3, 13, 14), `:user_defined_invariant_fn` (结论17). 例如2026年10月以前的Verus把返回值参数叫`:ret`而不是`:outer_ret`; 不检查这个字段时, 所有返回值都会被静默地当作没有输出, 只报告`&mut`参数.
    - 未起名的返回值的名字 (结论8): 有返回值的函数中没有一个叫`return%`或`%return`.
    - 路径段的命名空间前缀: 去掉已知的前缀 (`t%`, `tdis%N%`, `vdis%N%`, `foreign_mod%N`) 之后, 模块路径中还有带`%`的段. 2026年11月的Verus给路径段加上了这些前缀, 当时工具不认识它们, 结果中的模块名都带着`t%`, 按模块的选择器什么也选不中, 而没有任何警告.
    - VIR中的源文件是绝对路径, 或者在源码根目录下找不到.
    - 解析器读不了或解析不了的文件 (转述解析器的报错, 带行号).
    - 最后给出解析器找不到的函数数. 有一些是正常的 (注意9); 占了大半, 就说明源码根目录或解析器与VIR不符.

## 注意

1. 未被提及不等于规格有缺陷, 需要人工判断. 例如: 设计上有意不承诺; 输出马上就被销毁; 规格经由别的对象 (如ghost模型) 描述了它; 规格经由返回值描述了`&mut`参数 (结论10).
2. 被提及不等于规格完整, 这些都不报告: 只提及一次, 如只有`final(x).inv()`; 只在某个分支中提及, 如`cond ==> r is None`; 条件式的`ensures`, 如`obeys_xxx() ==> ...`, 而所有实现中条件都为假.
3. 由结论9, 未提及的报告可能多于实际: 规格若用`final(...)`以外的写法描述了`x`调用后的值, 本工具仍会报告`x`未提及.
4. 由结论7, 经由嵌套的`&mut`所做的修改不被检查, 全部漏报.
5. 签名之外的修改看不到, 全部漏报: 内部可变性 (`PCell`, 原子量, `AtomicInvariant`等经`&self`的修改), 不带tracked权限参数的裸指针写入, 全局状态和硬件状态. 经`PPtr`等的写入通常带有一个tracked `&mut`权限参数, 这个参数会被检查. 按值传入, 调用后不再交还的tracked参数也不是输出, 同样看不到 (见"经验").
6. 由结论17, 只查最外层类型的类型不变量, 所以有些输出实际受类型不变量约束, 报告中却注明为"无任何约束". 这只影响标注, 不影响是否报告 (结论16). 例如返回`Option<Frame>`而`Frame`有类型不变量: 调用者知道`Some(f)`中的`f`满足它, 但最外层的`Option`没有不变量, 这个输出被注明为"无任何约束". `Result`, 元组, `Vec`等同理. 泛型参数 (如`T`) 和关联类型 (如`M::Owner`) 在声明处不知道是哪个具体类型, 也查不到不变量; 对经由泛型调用的调用者来说, 注明为"无任何约束"是对的.
7. 不进入VIR的代码本工具看不到: 标了`#[verifier::external]`的函数, 被`cfg`关掉的代码 (如`#[cfg(ktest)]`), 导出VIR时所选target之外的代码.
8. 用`assume_specification`给外部函数写的规格, 在VIR中名字是外部函数的路径 (如`core::ptr::non_null::impl&%3::new_unchecked`), 但`owning_module`是写这份规格的模块 (如`vstd_extra::external::nonnull`), 所以按模块的选择器会选中它. 它的`is_external_body`为真, 按结论5注明. 报告中的函数名是外部函数的名字; 解析器按外部函数路径的最后一段对应它.
9. 解析器找不到的函数没有源码行, `lines`选不到它们, 要用`file`, `name`, `path`或`module`选 (源文件取自VIR中的位置). 例如`#[derive(Clone)]`生成的实现, `bitflags!`等宏生成的函数, 嵌套在函数体中的`fn`.
10. 选择器中的字符串按Racket的语法读入, 正则表达式中的`\`要写成`\\`; 匹配`.`等字符时也可以写成`[.]`.

## 经验

工具在vostd上的使用中得到的, 对理解它的报告有用的事实.

- **报告本身可靠, 判定要靠人.** 对vostd `36e90fe19`的`ostd::mm`和`ostd::sync` (pub函数, 572个) 的177条报告逐条人工审阅: 没有一条是工具的错误 (都与源码一致); 33条判为缺陷, 14条很可能是缺陷, 合起来约四分之一; 97条是有意不承诺或受抽象所限 (如锁和守卫没有值的模型), 33条不是问题.
- **"不是问题"的几种典型情况:** 经由返回值描述了参数 (结论10的预期误报, 7条, 都容易辨认: 返回值的类型带着参数的生命周期, 规格对返回值说得很多); 调用后马上销毁 (如`on_drop`); 状态全在ghost模型中; 锁一直留在`guards`中 (`Drop`的限制); `Debug::fmt` (vstd给它的规格没有ensures).
- **缺陷的典型后果是API无法连续使用.** 例如链表`push_back`不提`final(self)`的良构性, 于是只能push一次; 拿到页表游标后, 游标的每个方法都要求的不变量没有被转发, 一个方法也调不了. 这些API当时都还没有已验证的调用者, 所以验证发现不了.
- **纳入proof函数是值得的.** 81个proof函数只产生2条报告, 但都是缺陷.
- **审PR时**, 由审阅者列出PR涉及的函数 (`contrib/pr-functions.rkt`: 整个条目与diff有交集的函数, 声明被改动的trait方法实现, 以及可选的merge-base上没有的函数), 再用`@文件`或该脚本写出的结果生成报告. 每条报告再按真实用法写一个调用者来确认, 比只读规格可靠.
- **工具看不到, 但反复出现的真问题:** 按值消耗tracked owner而不交还 (调用者因此失去这部分ghost状态); 条件式ensures的条件在所有实现中都为假, 规格等于没写 (注意2); 文档与实现或规格不符. 这些需要别的检查或人工阅读.
- **输入不对时工具是静默的**, 结论24的警告都来自这样的教训: 解析器没有`rejoin_tokens`时, 用了`!is`的文件整个解析失败, 其中的函数没有源码行, 按diff行选函数时被漏掉, 而当时没有任何提示. 用未经验证的旧Verus (2026-09-03) 导出的VIR中返回值字段名不同, 检查照常结束, 只是一条返回值的报告也没有.
- **只看工具的报告会低估问题.** 对`mm::frame::unique`的一次审阅中, 工具报告2条, 而阅读规格又找出了好几处更严重的: 返回的owner缺`inv`, 导致后续调用的前提无从得知; 缺少其它帧不变的框架条件; `external_body`的`From`/`TryFrom`实现绕过了被调函数的`requires`. 这些输出都"被提及"了, 所以工具看不到 (注意2).
