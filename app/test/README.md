# 测试说明

这份文档回答三件事：**怎么跑**、**每个测试文件在测什么**、**加测试时请守什么约定**。

当前数字以 [`../docs/TEST_REPORT.md`](../docs/TEST_REPORT.md) 为准（那里的数字是跑出来的）。

---

## 一、怎么跑

在 `app/` 目录下：

```powershell
flutter analyze                                                # 静态检查，必须零告警
flutter test                                                   # 单元 + 界面测试（不需要设备）
flutter test test/import_session_test.dart                     # 只跑一个文件
flutter test --plain-name '提交之后首页与整理页'                 # 只跑名字匹配的用例

# 下面两条必须插着真机（-d 后面是设备 id，用 flutter devices 查）
flutter test integration_test/database_test.dart -d <设备>      # SQL 层
flutter test integration_test/file_source_test.dart -d <设备>    # 文件选择通道

# 对着真 GitHub 跑一次升级检查（默认跳过，见下面「手动测试」）
flutter test test/manual/live_update_test.dart --dart-define=YOUNUM_LIVE=1
```

### 为什么分成「纯 Dart」和「真机」两层

`flutter test`（不带设备）跑在 Dart VM 上，**没有原生 SQLite** ——
本机只有一个给 UWP 用的 `winsqlite3.dll`，`sqlite3.dll` 并不存在。
所以：

| 层 | 位置 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| 纯 Dart | `test/` | 业务规则、会话编排、界面接线、平台通道的错误分支 | 真实 SQL 行为、真实文件选择器 |
| 真机 | `integration_test/` | 外键、唯一约束、`ON DELETE RESTRICT`、事务原子性、迁移链、加密搬迁 | 需要人手的界面（系统选择器、通知送达） |

**这个分工不是偷懒**：内存实现里的绿灯不能当作 SQL 的证据 ——
`allocation(transaction_id, category_id)` 的唯一索引、
`refund_allocation` 的 `ON DELETE RESTRICT`，内存实现根本碰不到它们。

需要人手的部分逐条列在 [`../docs/MANUAL_CHECKS.md`](../docs/MANUAL_CHECKS.md)，
**标着未验证的不要当成已验证**。

---

## 二、目录

```text
test/
├── *_test.dart                    59 个测试文件（下面逐个说明）
├── support/
│   ├── ledger_fixtures.dart       公开夹具：只用指南 10.1 的固定基准，不含真实账单
│   └── fake_file_source.dart      可控的文件来源（选到了什么 / 取消 / 失败）
├── manual/
│   └── live_update_test.dart      对着真 GitHub 接口跑（默认跳过）
└── 账单/                          真实账单样本，**被 .gitignore 排除**，不进仓库

integration_test/
├── database_test.dart             真机：结构、约束、迁移、导入、加密……
└── file_source_test.dart          真机：文件选择通道
```

---

## 三、每个文件在测什么

### 3.1 纯规则（最快，也最该先跑）

| 文件 | 测什么 |
| --- | --- |
| `money_test.dart` | 金额以「分」保存、精确十进制解析（`0.005` 报错而不是四舍五入）、加总溢出 |
| `allocation_rules_test.dart` | 拆分守恒：每项 > 0、合计**精确等于**原金额 |
| `refund_rules_test.dart` | 退款：抵扣不超原消费、退款分配合计等于退款金额、单项累计不超原项 |
| `month_insights_test.dart` | 日均的分母、环比的前提、**不伪造缺失月份** |
| `monthly_stats_test.dart` | 指南 10.1 的固定金额基准（跨阶段验收的锚点，动了就得说清为什么） |
| `reminder_rules_test.dart` | 每月提醒按**自然日历**推算下次时间（不是固定 30 天） |
| `update_rules_test.dart` | 升级判定：残缺的 GitHub 响应、没有 APK、千奇百怪的 tag、忽略语义 |
| `export_rules_test.dart` | 明细 CSV 的结构、**防公式注入**（`= + - @` 开头）、隐私开关 |
| `share_poster_rules_test.dart` | 海报要画什么（纯数据决定），隐藏金额时清单里就不该有金额 |
| `icon_asset_rules_test.dart` | 图片图标校验：太大、尺寸不对、坏图、格式不支持 |
| `color_math_test.dart` | 颜色逐通道混色、线性化亮度、对比度 ≥ 4.5:1 |
| `csv_parser_test.dart` | CSV：引号、字段内逗号、字段内换行、BOM、CRLF |
| `text_decoding_test.dart` | 编码探测：UTF-8 严格解析 → GBK 对比，判不出来时给用户选 |
| `xlsx_reader_test.dart` | XLSX：自写 zip + 共享字符串 + **Excel 日期序列号** |
| `import_rules_test.dart` | 表头识别、字段映射、逐行标准化、两级去重 |
| `bank_statement_test.dart` | 银行账单适配器（按**整套表头**识别，不能污染微信账单） |
| `import_cross_source_test.dart` | 跨来源疑似重复（同一笔同时出现在银行卡与微信里，商户名完全不同） |
| `category_management_test.dart` | 分类：新建、同级重名、改名保留 ID、图标、删除默认归档 |
| `category_merge_test.dart` | 合并：规则、真的迁账、撞唯一索引时金额相加、退款分配改指向 |
| `quick_pick_test.dart` | 用途快捷项：默仍然内置那 8 个、按给定顺序取子集、过滤已归档/细分/重复且**不自动补位**、上限 8 个、写偏好失败时列表**不变**并给出原因 |
| `migrations_test.dart` | 迁移框架（用假执行器跑，不碰真数据库） |

### 3.2 仓库与编排（内存存储 / mock 通道）

| 文件 | 测什么 |
| --- | --- |
| `ledger_repository_test.dart` | 整理流程的编排：提交、稍后、重新整理、撤销、持久化、失败处理 |
| `review_session_test.dart` | 整理会话状态机：跳过不计完成、未选分类不能提交、撤销恢复队列位置 |
| `split_test.dart` | 拆分：不复制原交易（笔数不变）、合计必须精确相等、有退款时不能改结构 |
| `nature_test.dart` | 交易性质：收入/转账/排除统计不需要分类、排除必须写原因、退款要关联 |
| `detail_edit_test.dart` | 详情页保存：备注与用途必须**一次写完**（否则撤销只能还原一半） |
| `refund_link_test.dart` | 建立退款关联（含跨月） |
| `refund_allocation_test.dart` | 拆分消费的退款分配（要指明抵到哪几项、各多少） |
| `refund_unlink_test.dart` | 解除退款关联，退款回到待核对 |
| `category_image_test.dart` | 「换图片图标」这条编排（处理 → 落盘 → 提交引用 → 清理旧资源） |
| `import_session_test.dart` | 导入会话：选文件→解析→核对→提交→撤回、编码重试、重复取舍、**改账后要通知外面** |
| `import_workflow_test.dart` | 暂存 / 提交 / 撤回的编排，含跨批次复用与引用计数 |
| `import_recovery_test.dart` | 进程被杀之后的收尾（补记已提交 / 放回待提交，两种都不能重复入账） |
| `import_large_file_test.dart` | 6 万行的大文件：**复杂度写错**会被抓出来（行数翻倍不能变成平方级） |
| `export_files_test.dart` | 导出编排：文件名、渲染失败时不落盘 |
| `icon_asset_store_test.dart` | 真的解码一张 PNG、居中裁方、缩到 256×256、写进文件柜 |
| `share_poster_renderer_test.dart` | 海报真的渲染成 PNG（文件头、IHDR 尺寸、能重新解码） |
| `document_saver_test.dart` | 「保存文档」通道的错误码 → 用户能看懂的一句话（mock 通道，不需要设备） |
| `file_source_test.dart` | 「选文件」通道的同上 |
| `theme_controller_test.dart` | 主题：拖动只预览、松手才写盘、写盘失败保留预览、冷启动保持 |
| `reminder_controller_test.dart` | 提醒：开关、权限、排期，以及**如实上报状态**（发不出去就别显示已开启） |
| `update_controller_test.dart` | 升级状态机：**不打扰**（查不到别出声）、**不撒谎**（别把查不到说成已是最新） |
| `real_bills_test.dart` | 用**真实账单**跑端到端；样本不在仓库里就**跳过**，不当作通过 |

### 3.3 界面接线（把真正的 `YounumApp` 挂起来走一遍）

这一组专抓「页面根本没接上」：按钮点了没反应、跳错页、数字还是样例数据 ——
`flutter analyze` 与纯逻辑单测都看不见。

| 文件 | 测什么 |
| --- | --- |
| `onboarding_widget_test.dart` | 三屏引导：首尾不循环、竖向滑动不翻页、每屏能跳过、按钮文案随屏变化 |
| `import_flow_widget_test.dart` | 导入全流程，以及**提交之后首页与整理页立刻能看到**、**跨月导入要跟着走到那个月** |
| `category_widget_test.dart` | 分类管理：新建真的落库、重名被拒还在原地、归档能从「已归档」恢复 |
| `category_merge_widget_test.dart` | 合并界面：目标列表只给同层级、确认弹层说清影响、账目真的换了分类 |
| `split_widget_test.dart` | 拆分页带的是**那一笔**、合计不符不能提交、已拆过的要回填 |
| `nature_widget_test.dart` | 性质页：没有预选、退款要选原消费（且候选里没有自己） |
| `detail_edit_widget_test.dart` | 详情页：备注回填、保存真的写库 |
| `card_swipe_widget_test.dart` | 滑动手势回归（卡片高度实现方式变过一次）；另有一组「确认之后的提示条」—— 提示条里必须是商户名，不能是对象的 `toString`（真机上报过，见 `DECISIONS.md` 76 节） |
| `text_scale_widget_test.dart` | 系统字号 1.0 / 1.25 / 2.0：不溢出、不重叠、卡片真的长高 |
| `report_coverage_widget_test.dart` | 月报页的「确认本月范围完整」入口 |
| `share_export_widget_test.dart` | 隐私开关必须影响**文件**，不是屏幕遮罩 |
| `reminder_widget_test.dart` | 提醒设置页：拿不到权限时不能显示「已开启」 |
| `update_widget_test.dart` | 检查更新页：按钮不贴在一起、查不到不能写成已是最新；**启动时的新版本提示**也在这一组（只弹一次、忽略过的版本不弹、出现更高版本再提、「以后再说」不写偏好、Release 正文那种长度与字号 2.0 下不溢出） |
| `share_import_widget_test.dart` | 系统「分享一份账单到有数」：落到确认导入页、认不出表头去映射页、老式 `.xls` 与读不了的文件要说清原因、同一份分享**只导一次** |
| `quick_pick_widget_test.dart` | 用途快捷项接线：卡片上的几格就是配好的那几个与那个顺序；管理页移除后卡片跟着变；**拖动改顺序真的落盘**；只剩一个时不能移除；满了显示「已满」且点不动 |
| `demo_ledger_exit_widget_test.dart` | 退出示例账本：「我的」那一行退出后回到自己的账本且能走回去、徽标 → 弹层 → 退出、「继续体验」什么都不改 |
| `tablet_layout_widget_test.dart` | 平板竖屏（720×1152dp）：走一遍不溢出、正文正好 560dp 且居中、插画不跟着屏宽变形、弹层也跟着限宽 |

### 3.4 夹具与手动测试

| 文件 | 用途 |
| --- | --- |
| `support/ledger_fixtures.dart` | 账目测试的公开夹具，全部来自指南 10.1 的固定基准 |
| `support/fake_file_source.dart` | 可控文件来源：`bytes` / `cancel` / `failure`，导入流程每个分支才测得到 |
| `manual/live_update_test.dart` | 对着**真的** GitHub 接口跑一次，确认线上拿得到东西。默认跳过（断网/限流/被墙会让它变红，而那是环境问题），要跑就 `--dart-define=YOUNUM_LIVE=1` |
| `账单/` | 真实账单样本（微信/支付宝/银行卡），**不进仓库**；`real_bills_test.dart` 找不到样本时会跳过 |

---

## 四、加测试时请守这些约定

1. **每条测试都要有自己的「为什么值得写」。**
   仓库里的用例前面基本都有一段注释，写的是**它当初抓到了什么 bug**、
   或者什么情况下会失效。这不是凑字数 —— 后来改代码的人靠它判断
   「这条断言还能不能动」。新加用例请照这个习惯写。

2. **修 bug 之前先写一条会失败的测试，并且真的看到它红。**
   没红过的测试只是个摆设。做法见 [`../../AGENTS.md`](../../AGENTS.md) 第 3 节：
   临时把修复去掉跑一遍，确认它失败，再把修复放回来。

3. **不要依赖网络、时间、设备**（除非那个文件本来就跑在真机上）。
   需要「现在」的地方用可替换的 `Clock`；需要网络的地方用手写 JSON。

4. **样本缺失时跳过，不要假装通过。**
   `real_bills_test.dart` 与 `live_update_test.dart` 都是这么做的 ——
   `markTestSkipped` 会如实记成跳过。

5. **内存实现与真机实现的行为必须一致。**
   两者是同一份端口的两套实现（`data/memory` 与 `data/db`）。
   改了一边的语义，另一边要跟上，并且两边都要有用例 ——
   否则「单元测试绿、真机炸」或者反过来。

6. **界面测试里点按钮要留神两件事**（都踩过）：
   - 页面标题与按钮文案经常一样（左上「选择账单文件」+ 下面那个按钮也叫这个名字），
     用 `find.descendant(of: find.byType(PrimaryAction), …)` 精确定位；
   - 折叠线以下的按钮要先 `ensureVisible` 再点，否则 `tap` 只是「点了个空」，
     测试会以「什么都没发生」的形式失败。

7. **数字会过时。** 测试数量变了，请顺手更新
   `../docs/TEST_REPORT.md` 与 `../docs/IMPLEMENTATION_STATUS.md` 里的数字
   （只更新实际跑出来的）。
