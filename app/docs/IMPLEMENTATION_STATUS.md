# 实现状态

> 每次交接都更新本文件。格式见实现指南 11「建议状态记录格式」。

## 当前阶段

**阶段 0 + 阶段 1 + 阶段 2 已完成；阶段 5 的「统计与回顾」先做了一批。**

界面按指南第 5 节的 33 个设计状态全部实现并可真机运行。
账单落在本地 SQLite；**首页、整理、月报、趋势、明细、分享、月份、我的**
的数字全部来自真实查询，且共用同一份报告（见 `DECISIONS.md` 第 26 节）。
**导入流程（阶段 3）与分类管理 / 拆分 / 退款界面（阶段 4）仍为样例或未接线**。

---

## 已完成

### 阶段 0

* 通读 `设计稿/` 下的实现指南、设计说明、交互补充规范，以及
  `app.js`（页面定义与文案）、`style.css` / `theme.css`（视觉规则）、
  `theme.js`（颜色派生算法）、`interactions.js` / `interactions.css`（滑卡与图标）。
* 核对环境：Flutter 3.47.5 / Dart 3.13.4；真机 2211133C（Android 16 / API 36）。
* `docs/DECISIONS.md`：记录技术栈替换（Flutter 取代 Kotlin + Compose）、
  图标库替换、字号上调、缩放上限、样例数据披露方式等全部偏离及原因。

### 阶段 1

**工程与配置**

* 单 Activity（`MainActivity`，Kotlin 保留给平台侧），
  applicationId / namespace = `com.younum.app`，minSdk 26，label「有数」。
* `android:allowBackup="false"` + `data_extraction_rules.xml` 全量排除云备份与设备迁移。
* 未申请任何权限（包括 `INTERNET`）。
* 路由集中在 `lib/app/app_routes.dart`，覆盖 33 个状态。

**设计系统**（`lib/core/designsystem/`）

* `color_math.dart`：逐通道 sRGB 混色、线性化相对亮度、对比度、
  逐步加深至 ≥ 4.5:1、HEX 解析（只接受完整 `#RRGGBB`）。
* `younum_colors.dart`：主题派生色 + **不随主题变化**的固定语义色
  （危险 / 警告 / 分类系列色 / 图片占位）分开建模。
* `younum_text.dart`：字号层级，辅助文案下限 12sp，金额用等宽数字。
* `younum_dimens.dart`：间距、圆角、触控目标（≥ 48dp）。
* `younum_icons.dart`：12 个内置分类图标 + 界面图标，集中登记便于替换。
* `younum_theme.dart`：只提供浅色方案，禁用涟漪，统一输入框 / 弹层 / 开关样式。

**主题系统**

* 六套预设（`forest` 默认），点击立即全局生效并保存。
* `ThemeController`：拖动只改内存、手势结束才写盘；写盘失败保留预览并
  提供重试；非法 HEX 保持上次有效主题；恢复默认不动账单。
* 首帧之前加载偏好，不出现「先闪默认绿」。
* App 内取色控件（色相 / 饱和度 / 明度三个系统滑块）+ HEX 输入。

**共用组件**（`lib/core/components/`）

`YounumScreen` / `YounumTopNav` / `AppBottomBar` / `YounumPanel` /
`AmountText` / `PrimaryAction` / `YounumPressable` / `YounumListRow` /
`YounumTileIcon` / `CategoryIconView` / `CategoryGrid` / `YounumChip` /
`YounumProgressTrack` / `YounumDonutChart` / `YounumLegend` / `YounumBarRow` /
`YounumTextField` / `YounumSelectField` / `YounumSwitchRow` / `YounumCheckRow` /
`YounumRadioGroup` / `ConfirmSheet` / `YounumColorSwatch` / `YounumThemeSwatch` /
`YounumDashedBox` / `YounumDemoNote` / 空态 / 错误态 / 圆形符号。

**33 个设计状态**

| 分组 | 状态 | 实现位置 |
| --- | --- | --- |
| 开始与本月（3） | `welcome` `empty` `home` | `features/start/start_screens.dart` |
| 导入（8） | `import` `guide` `upload` | `features/import_flow/import_screens.dart` |
| 导入（8） | `parsing` `mapping` `checkimport` `duplicates` `importerror` | `features/import_flow/parse_screens.dart` |
| 整理（9） | `cards` `allcats` `categorymanage` `newcat` | `features/organize/cards_screen.dart` / `category_screens.dart` |
| 整理（9） | `detail` `split` `nonexpense` `pending` `complete` | `features/organize/review_screens.dart` |
| 回顾（6） | `report` `breakdown` `trends` `transactions` `share` `months` | `features/report/report_screens.dart` |
| 我的与状态（7） | `profile` `importhistory` `privacy` `reminder` `deleteconfirm` `offline` | `features/profile/profile_screens.dart` |
| 我的与状态（7） | `theme` | `features/profile/theme_screen.dart` |

**已按目标形态实现的业务规则**（数据源暂为内存）

* 滑卡：阈值 = 宽度 28%（钳制 72–120dp）、1.3 倍轴锁定、±12° 旋转、
  屏幕边缘避让、取消手势回弹、**先事务后动画**、失败回弹且保留选择、
  减少动画时业务顺序不变、提交期间禁止并发。
* 整理会话：跳过不计完成数；未选分类不可提交（含右滑）；每次操作清空临时选择；
  撤销恢复记录**与队列位置**；主队列空但稍后队列非空时不进完成页。
* 拆分：各项 > 0 且合计**精确等于**原金额才可提交；可增删项。
* 交易性质：退款必须关联原消费，排除统计必须保留原因。
* 完成页：有待整理记录时不显示完成态；范围完整性由用户显式确认。
* 月报：范围未确认时标注「部分账单」；无消费走空状态；
  分类占比由分类净额 ÷ 总净消费计算，分类金额之和等于总额。
* 月份：无记录的月份不显示任何金额。
* 分享：每次进入默认隐藏金额，隐藏时**不渲染数值**。
* 提醒：默认关闭；按自然日历推算下次时间（非固定 30 天）；权限未开启不显示「已开启」。
* 清除数据：逐项说明清除与保留范围；执行后账本与会话一起归零。
* 金额：精确十进制解析（`0.005` 报错而非四舍五入）、加总溢出检查。

## 本次验证

工程已迁移到 `D:\dev\younum`（原因见 `DECISIONS.md` 第 10 节），以下结果均在**新位置**取得。

| 项目 | 命令 / 方式 | 结果 |
| --- | --- | --- |
| 依赖解析 | `flutter pub get` | 通过 |
| 静态检查 | `flutter analyze` | **No issues found!**（0 error / 0 warning / 0 info） |
| 单元测试 | `flutter test` | **52 passed** |
| Android 编译 | `flutter build apk --debug` | 成功，产出 `build/app/outputs/flutter-apk/app-debug.apk` |
| 真机安装 | `adb install -r`（2211133C，Android 16 / API 36） | Success |
| 启动无异常 | `flutter run` 日志 + 冷启动 | 无 Dart 异常 |
| 引导流程 | 手动：欢迎 → 空首页 → 示例账本 | 通过；`onboarding.seen` 与 `ledger.mode` 均已持久化 |
| 分类选中态 | 手动：点「餐饮」 | 通过；边框加粗 + 勾选标记 + 加粗文字 |
| **右滑确认** | 手动：选「餐饮」后右滑卡片 | 通过；进度 `0/6 → 1/6`、卡片推进到下一笔、**选择被清空** |
| 主题持久化 | 单元测试覆盖（含写盘失败、损坏偏好、纯白/纯黑/纯黄） | 通过 |
| 空态与部分账单 | 手动：月报页未确认范围 | 显示「部分账单」+ 明确说明 |

截图证据存于 `docs/screenshots/`：
`01-welcome`、`02-empty-home`、`03-home`、`04-cards`、`05-report`、
`06-swipe-confirm`（右滑确认后）、`07-category-selected`（分类选中态）。

**尚未在本次验证**

* 左滑进入稍后队列、撤销按钮、拆分 / 非消费提交（状态机已有单元测试覆盖，但未在真机点验）。
* 六套主题在真机上逐一走查。
* 旋转、深色系统主题、大字号、TalkBack。

### 阶段 1 期间修掉的两个真实缺陷

1. **固定语义色全部透明（严重）**
   `Color(int)` 按 `0xAARRGGBB` 解释，而我把 `YounumColors` 的固定色常量写成了六位
   `0xRRGGBB`，于是 `const Color(YounumColors.line)` 的 alpha 为 0 —— 徽标、分隔线、
   面板描边、图标底色、危险 / 警告色**全部不可见且不报错**。
   修复：常量统一改成 8 位不透明值，并新增 `allFixedColorValues` + 单元测试防回归。
   验证：修复后「示例账本」徽标、面板描边、列表分隔线、导航栏上边线全部正常显示。

2. **堆叠卡片页底部操作行被导航栏截断**
   指南 6.2 要求「核心确认区尽量稳定可达」。收紧卡片内边距（22→18dp）、
   分类格子最小高度（68→62dp）、进度条与手势说明的上下留白，使确认按钮与
   撤销 / 稍后 / 更多操作行在 412dp 宽的真机上不滚动即可见。

### 阶段 1 走查后的 UI 调整（需求方提出）

1. **月份入口的下箭头**：原先用 Unicode 字符 `⌄`，生僻字形落到回退字体，
   又小又偏。改为 20dp 的 Material 矢量图标并与文字水平对齐。
   顺带把首页与月报两份重复的轻量按钮实现合并为 `PlainTextButton`。
2. **卡片手势提示行不再常驻**：移除了卡片下方的
   「← 左滑：稍后处理 / 右滑：确认已选分类 →」。
   ⚠️ 这与指南 14.1 冲突，属需求方决定的偏离，详见 `DECISIONS.md` 第 14.2 节。
   手势语义、拖动中的实时反馈、按钮入口均保持不变。

验证：真机上确认月份箭头已放大对齐；整理页首屏不再出现提示行，
其余内容（卡片、分类网格、确认按钮、操作行、注释）全部完整可见。

### 阶段 1 走查后的第二批调整（需求方提出）

1. **卡片遮挡整理进度条**：后层卡片旋转后包围盒变高，而堆叠区没有预留空间，
   旋转后的上角压到了进度条上。新增 `stackSwingReserve = 17`
   （公式与重算要求见 `DECISIONS.md` 第 15 节），堆叠区高度改为卡片高 + 2×reserve。
2. **去掉底部注释**「也可点按钮操作 · 未选分类时右滑不会提交」。
3. **性能优化**：拖动热路径改为 `ValueNotifier` 驱动（拖动期间不再 `setState`）、
   去掉每帧触发的 `LayoutBuilder` 与多余的 `Listener`、卡片加 `RepaintBoundary`、
   去掉卡片的模糊阴影、虚线分隔线改 `CustomPaint`、标签页各包一层 `RepaintBoundary`。
   详见 `DECISIONS.md` 第 16 节。

验证：真机上确认进度条不再被遮挡；选「餐饮」后快速右滑 → `0/6 → 1/6` 且卡片推进；
左滑 → 卡片推进（稍后队列）；点「撤销」→ 提示「已撤销：确认 优衣库 UNIQLO」、
进度回到 `0/6`、队列位置正确恢复。三重手势语义均未被重写破坏。

### 性能测量（实测数据与局限）

| 项目 | 结果 |
| --- | --- |
| `dumpsys gfxinfo` | **不可用** —— Flutter 走 SurfaceView，帧不计入，返回 0 / 4950ms 哨兵值 |
| `dumpsys SurfaceFlinger --latency` | **无数据** —— 能拿到图层与刷新周期（60Hz），但时间戳为空 |
| `logcat` 的 `Choreographer: Skipped N frames` / `HWUI: Davey!` | **可用**，作为粗粒度掉帧指标 |

脚本化负载（10 次快速拖动 + 4 次二级页往返 + 4 次边缘返回手势）下，
debug 与 profile 包**都没有产生掉帧日志**，只有 2–3 条亚毫秒级的
`Frame time is 0.08 ms in the future`（vsync 时间戳提示，不是掉帧）。

⚠️ **未完成验收**：无法用 `input swipe` 复现需求方主观感受到的卡顿。
脚本化滑动只产生少数指针事件，真手指以 120–240Hz 上报，对「每帧 setState」
这类问题的放大程度差很多。因此优化针对的是已定位到的机制，
但**「改完是否真的不卡」需要真手指在 profile 包上复测确认**。
如需逐帧数据，走 DevTools Performance 页（`flutter run --profile` 后按 `P`）。


### 阶段 2 第一批：数据底座与账目规则

**依赖**（选型理由见 `DECISIONS.md` 第 18 节）：

* `sqflite 2.4.4` —— Android 用系统自带 SQLite，**不需要**编译原生库，
  不引入 NDK / CMake 环节；
* `path`（拼数据库路径）、`integration_test`（真机数据库测试）；
* 除以上与 `shared_preferences` 外没有第三方依赖，没有状态管理库。

**领域层**（`lib/domain/`，纯 Dart，不依赖 Flutter 与数据库）

* `models/`：`YearMonth`（结构化月份，字符串排序会错位所以不能用字符串）、
  `Ledger`、`Category`、`LedgerTransaction`（**性质与整理状态分开建模**）、
  `Allocation` / `RefundLink` / `RefundAllocation`、`LedgerDataset`、
  `ReviewSessionRecord` / `UndoRecord`。
* `rules/`：`AllocationRules`（拆分每项 > 0、合计**精确等于**原金额）、
  `RefundRules`（累计抵扣不超原额、拆分消费必须明确退款分配、
  有关联退款时不能破坏原拆分）、`MonthlyStats`（月度净消费、分类净额、守恒）、
  `ReviewProgress`、`MonthOverview`。
* `repositories/`：`LedgerStore`（存储端口）与 `LedgerRepository`（业务编排）。

**数据层**（`lib/data/`）

* `db/younum_schema.dart`：10 张表（`ledger` `category` `txn` `allocation`
  `refund_link` `refund_allocation` `review_session` `review_queue_item`
  `review_action` `month_review`）+ 关键索引。
* `db/migrations.dart`：逐版推进的迁移框架，**不支持降级**，
  全新安装也会先建 v1 再跑迁移链（保证升级路径每次全新安装都被走到）。
* `db/sqflite_ledger_store.dart`：显式 SQL + 集中在 `onConfigure` 的
  `PRAGMA foreign_keys = ON`。
* `memory/in_memory_ledger_store.dart`：给 `flutter test` 与存储不可用时兑底。
* `seed/demo_ledger_seed.dart`：指南 10.1 的 6 笔基准真实落库。

**数据库把能拦的都拦了**

| 问题 | 约束 |
| --- | --- |
| 同源重复写入 | `idx_txn_source` 唯一部分索引（基于去重键） |
| 同一消费拆到同一分类两次 | `idx_allocation_tx_category` |
| 同一退款重复关联 | `idx_refund_link_refund` 唯一索引 |
| 同级分类重名 | `idx_category_parent_name` 表达式索引（`ifnull(parent_id,-1)`） |
| 悬空分类 / 悬空分配 | 外键 + `ON DELETE RESTRICT` |
| 金额为负 / 未知枚举值 | `CHECK` 约束 |
| 排除统计没有原因 | `CHECK (nature <> 'EXCLUDED' OR exclude_reason IS NOT NULL)` |
| 同一账本月份重复会话 | `idx_review_session_unique` |

**界面接线**

* `ReviewSession` 改为读写数据库：队列顺序、已完成分类、稍后队列、
  撤销日志全部落库。
* 首页的「已导入支出 / 笔数 / 来源 / 整理进度」接真实查询；
  账本有没有记录不再用「是不是演示账本」近似。
* 「清除本地数据」真实清空数据库（保留主题与引导状态）。

## 本次验证（阶段 2 与阶段 5 第一批）

| 项目 | 命令 / 方式 | 结果 |
| --- | --- | --- |
| 静态检查 | `flutter analyze` | **No issues found!** |
| 单元测试 | `flutter test` | **121 passed** |
| 真机数据库测试 | `flutter test integration_test/database_test.dart -d 412913d4` | **20 passed** |
| Android 编译 | `flutter build apk --debug` | 成功 |
| 真机安装启动 | `adb install -r` + 冷启动 | 无 Dart 异常，logcat 无崩溃 |

### 指南 10.1 固定基准：单元测试与真机双重确认

| 断言 | 结果 |
| --- | --- |
| 6 笔全部归类后总消费 | **63330 分 / ¥633.30** |
| 餐饮净额 | **15480 分** |
| 消费笔数 | **6** |
| 盒马拆 8680 + 4000 后 | 总额 63330，餐饮 11480，购物 33900，笔数仍 6 |
| 10 月发生、关联 9 月优衣库的 10000 分退款 | 9 月净消费 **53330**，10 月消费 **0（不为负）** |
| 同一退款重复关联 | 明确失败 |
| 退款超过原消费剩余额度 | 明确失败，金额保持之前的值 |
| 分类净额之和 | 恒等于总净消费（守恒） |

### 真机走查（应用在设备上实际跑出来的）

* 首页显示 **¥633.30 · 6 笔消费 · 2 个来源**，
  与支付宝 ¥503.80 + 微信支付 ¥129.50 相加完全对得上 ——
  这些数字全部来自数据库查询，不是界面常量。
* 整理页卡片显示 MANNER COFFEE ¥28.00 / 09.23 · 14:26 / 微信支付；
  点「餐饮」→「确认分类」→ **已整理 1 / 6 笔（17%）**，卡片推进到优衣库。
* **杀进程重启后进度仍在**：首页显示 17%、「已经整理 1 笔，剩下 5 笔」。
* 重启后点「撤销」→ 回到 **0 / 6**、卡片回到 MANNER COFFEE。
  这同时证明了撤销日志（`review_action`）也跨进程保留了。

### 阶段 2 发现的三个真实问题

1. **撤销有关联退款的消费会造成静默的错账**（详见 `DECISIONS.md` 第 20 节）
   原实现靠外键 `RESTRICT` 拦，实测**拦不住** —— 单分类消费的退款不需要
   `refund_allocation` 行，没有外键引用那条分配。已改为显式业务校验。
2. **卡片页分类网格把底部操作行挤出屏幕**：分类改从数据库读之后，
   自建分类（宠物、学习成长）让网格从 2 行变 3 行，确认按钮与
   撤销 / 稍后 / 更多操作行不可见。已改为网格只放 8 个内置一级分类
   （与设计稿一致），自建分类走「全部分类」。
3. **无记录的月份会显示「这个月，理清了。」**：真实账本一笔都没有时，
   空队列被当成「整理完成」。已区分「没有账单」与「整理完了」两种空状态。


### 阶段 5 第一批：统计与回顾接真实数据

把月报这一组页面从样例数字换成真实查询。新增 `lib/domain/rules/month_insights.dart`：
`MonthReports.build` 一次算出**概况 + 洞察 + 趋势 + 有记录的月份 + 完整数据集**，
六个页面共用（`DECISIONS.md` 第 26 节）。

**验证（真机）**

| 项目 | 结果 |
| --- | --- |
| 单元测试 | **139 passed**（新增 18 个洞察 / 趋势用例） |
| 静态检查 | **No issues found!** |
| 未整理时的月报 | 空状态，并说明「已导入 6 笔但还没有确认归类」 |
| 6 笔整理完后的月报 | ¥633.30、「截至 9月23日」、部分账单、占比 47.2/24.4/18.1/10.3 |
| 占比与明细是否对得上 | 逐笔核对一致（交通=优衣库 29900、娱乐=滴滴+周末电影） |
| 趋势页 | 4–8 月显示「无记录」不伪造；日均写成「已覆盖范围日均 ¥27.53（23 天）」；环比给「暂无可比月份」 |
| 月份页 | 只有 9 月有状态（待确认），空月份不显示任何金额且按钮不可用 |
| 清除本地数据 | 回到空账本；演示账本重置为 0/6 |
| 冷启动日志 | 无 Dart 异常、无崩溃 |

**验证数字与算法的核对**

* 63330 / 23 = 2753 分 = **¥27.53**，且明确标注分母是 23 天而不是 30 天。
* 未确认范围时写「截至 9月23日」，因为最晚一笔记录在 23 日。
* 分类占比之和为 100.0%，分类净额之和恒等于总净消费。

**本轮发现并修掉的问题**

1. **环比与分类变化没有任何入口。** 「确认本月范围完整」只能从整理完成页进入，
   而月报页没有这个入口 —— 于是环比永远显示「暂无可比月份」，
   用户根本看不到这个功能。已记入「下一步」，**本轮未修**。
2. **导入批次在「数据管理」里用样例数字充数**（显示「2 份」而实际一份都没有）。
   已改为如实留空。
3. **「已经陪你回顾了 6 个月」是样例常量**，而实际只有 1 个月有记录。
   已改为按真实月份数计算。

## 未完成及风险

**仍然是样例数据的地方**

* **导入流程**（选择来源 / 上传 / 识别 / 字段映射 / 核对 / 疑似重复 / 异常）
  全部是 `SampleData`，属阶段 3。
* **分类管理**（新建 / 改名 / 图标）仍写内存，重启回到出厂图标（阶段 4）。
* **导入记录**页仍为样例；`import_batch` 表尚未建。
  因此「数据管理」里的「导入批次」如实留空，不用样例数字充数。
* **拆分 / 非消费 / 退款关联**的规则与仓库入口已实现并有测试覆盖，
  但界面还没接上去（阶段 4）。
* **导出**（PNG / CSV）未接入文件写入，点按后如实提示。
* 主题页里的预览金额用的是样例数字（仅预览用）。

**阶段 3（导入）已落地的部分**

| 内容 | 位置 | 验证 |
| --- | --- | --- |
| CSV 解析（RFC 4180、分隔符探测、未闭合引号报行号） | `lib/domain/rules/csv_parser.dart` | 单元测试 22 个 |
| 编码探测（BOM → UTF-8 严格 → GBK 对比） | `lib/domain/rules/text_decoding.dart` | 单元测试 14 个 |
| 表头识别、字段映射、行标准化、两级去重 | `lib/domain/rules/import_rules.dart` | 单元测试 31 个 |
| 结构与模型（`ImportStage` 九态、批次、行、来源绑定） | `lib/domain/models/import_records.dart` | 静态检查 + 真机 |
| v1 → v2 迁移：新增导入三张表 | `lib/data/db/younum_migrations.dart` | **真机验证不丢数据** |

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 单元测试 | `flutter test` | **206 passed** |
| 真机数据库测试 | `flutter test integration_test/database_test.dart -d 412913d4` | **24 passed** |

真机上的 v1 → v2 用例是这样做的：先手工造一个只建 v1 结构、版本号写着 1、
并且**已经存有账单数据**（账本、分类、交易、分配、整理会话、月范围确认）的库，
再按正常路径打开让升级链跑起来，然后逐项核对老数据是否原封不动 ——
包括 `dedupe_key`（历史数据里没有它，后续导入就会把旧记录当成新的重复入账）
与 `coverage_confirmed`（用户确认过的「本月范围完整」）。

**仍然阻塞在阶段 3 后续的功能**

* 平台适配器的完整字段集（当前是通用 CSV）、字段映射界面、导入事务与撤回、
  幂等性与 `COMMITTING` 崩溃恢复、系统文件选择器（SAF）、界面接线。
* 还缺 `category_icon_asset` 表（阶段 4 用）。
* 没有任何真实微信 / 支付宝账单样本，平台适配器只在**仿造导出格式**的
  测试数据上验过；真文件的兼容性仍需实际样本确认。
* XLSX 解析库未选型，需先做真机内存与兼容性验证再锁定依赖。
* Photo Picker、WorkManager、通知权限未接入；
  SAF 会用 `ActivityResultContracts.OpenDocument` 手写平台通道接入
  （不引新依赖，避免动现在这套脆弱的 Android 工具链）。

**明确未验证**

* 真实微信 / 支付宝 CSV / XLSX 的兼容性**完全没有验证**，也没有任何真实样本。
* XLSX 解析库未选型，需先做真机内存与兼容性验证再锁定依赖。
* Photo Picker、WorkManager、通知权限、Storage Access Framework 均未接入。
* **旋转、大字号、TalkBack 未回归**。阶段 2 改了首页与整理页的布局，
  小屏幕 / 大字号下底部操作行是否仍可见只在本机 412dp 宽的手机上验过。
* 六套主题在真机上逐一走查仍未做（主题系统未改，但首页新增了
  「来源 / 整改进度」两块，值得重看一遍颜色对比度）。

**已知取舍**

* 文字缩放上限 1.6（堆叠卡片固定高度）；阶段 7 应改为自适应高度并放开。
* 分类图标注册表在内存中，重启会回到出厂图标（阶段 4 落盘）。
* 「其他」分类用的是默认叶片图标：图标库里没有 `more` 这个键，
  之前的样例数据写了 `more` 并静默回退成叶片。已直接用回退结果，
  不再铺一个无效键。
* 卡片页在更小的屏幕或更大字号下可能仍需滚动；
  确认按钮与操作行在本机已保证可见。
* 「消费最少的一天」只在有消费的日子里比较（`DECISIONS.md` 第 24 节）。
* 趋势的环比与分类变化需要**连续两个范围完整的月份**。
  目前只能靠单元测试覆盖：演示账本只有一个月的数据，
  而「确认范围完整」的入口在完成页，还没有从月报页直接确认的入口。

**环境遗留问题（迁移不能解决）**

* 本机 `sdkmanager.bat` 会以 `NTSTATUS 0xC0000409` 崩溃，需要联网补装 SDK 组件时会受阻。
* 因此 `ndkVersion` 显式指向本机已装的 `30.0.16248370`，并关闭了 Kotlin 增量编译
  （pub 缓存在 C 盘、工程在 D 盘，跨盘符会让 Kotlin 增量缓存报 `different roots`）。
* 旧目录 `OneDrive\桌面\小项目\youshu` 的内容已清空，但那个空文件夹暂时删不掉：
  VS Code 仍以旧路径作为工作区，文件监视器持有目录句柄。
  **切换到 `D:\dev\younum` 后即可手动删除。**

## 下一步（最小任务）

1. **阶段 4：把已实现但用户点不到的规则接上界面**
   —— 详情页编辑、拆分（`AllocationRules`）、非消费（交易性质）、
   退款关联（`RefundRules` + `linkRefund`）。这些的规则与仓库入口
   都已实现并有测试，缺的是界面。
2. **在月报页补上「确认本月范围完整」的入口**。
   现在只能从整理完成页确认，没有它就看不了环比与分类变化 ——
   这是用户视角下最明显的一个缺口。
3. **阶段 3：导入（进行中）**。
   已完成：CSV 解析、编码探测、`import_batch` / `import_row` /
   `transaction_origin` 三张表与 v1→v2 迁移、表头识别与字段映射、
   逐行标准化、两级去重判定。
   还缺：平台适配器的完整字段集、导入事务与撤回、系统文件选择器（SAF）、
   界面接线。没有这一步，真实账本永远是空的。
4. **阶段 5 剩余**：导出 PNG / CSV（含防公式注入），导入记录页接真实批次。

