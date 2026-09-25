# 有数 YOUNUM

把账单，整理成生活。

Android 记账整理 App。导入月账单 → 逐笔卡片确认用途 → 生成可对账的月度消费概况。

当前进度：**阶段 0 + 阶段 1**（设计系统 + 33 个设计状态的界面）。
界面已按设计稿实现并可在真机运行；业务数据仍来自设计稿样例，
接入数据库与真实解析属于阶段 2 起的工作。详见
[`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md)。

> **工程位置：`D:\dev\younum`**（仓库根，`设计稿/` 与 `app/` 同级）。
> 不要放回含中文或 OneDrive 同步的目录，否则 Gradle 会拒绝构建、
> Dart analysis server 会崩溃。原因与迁移过程见 `docs/DECISIONS.md` 第 10 节。

---

## 环境与版本

实际使用的版本（用 `flutter --version` 可核对）：

| 项目 | 版本 |
| --- | --- |
| Flutter | 3.47.5 · stable |
| Dart | 3.13.4 |
| compileSdk / targetSdk | 由 Flutter 3.47 默认提供（实测设备 API 36） |
| minSdk | 26（指南 2.1 的产品取舍） |
| JDK / Gradle JVM target | 17 |
| applicationId / namespace | `com.younum.app`（暂定，发布前需确认未被占用） |

依赖锁定在 `pubspec.yaml` + `pubspec.lock`，未使用 `+` 或快照依赖。
除 `shared_preferences` 与 SDK 内置的 `flutter_localizations` 外无第三方依赖。

## 构建与运行

在 `app/` 目录下执行：

```powershell
flutter pub get
flutter devices                       # 确认手机已连接
flutter run -d <device-id>            # 开发运行
flutter run -d <device-id> --profile  # 测性能必须用这个，不要用 debug 判断性能
flutter build apk --profile           # 产出性能对照包
flutter build apk --debug             # 产出调试 APK
flutter analyze                       # 静态检查（可加 --fatal-infos）
flutter test                          # 单元测试（不需要设备）

# 数据库测试必须跑在**真机**上：外键、唯一约束、ON DELETE RESTRICT
# 这些东西只有真实 SQLite 能证明，内存实现里的绿灯不算数。
flutter test integration_test/database_test.dart -d <device-id>
```

调试 APK 路径：`app/build/app/outputs/flutter-apk/app-debug.apk`

> **判断性能请用 profile 或 release 包。**debug 模式下 Dart 是 JIT 解释执行、
> 断言全开，本身就会明显慢于发布形态。在 `flutter run` 中按 `P` 可打开性能浮层。
>
> **本机跑不了 `flutter test` 里的数据库用例**：那需要一个本机并不存在的
> `sqlite3.dll`（系统里只有给 UWP 用的 `winsqlite3.dll`）。
> 把系统 DLL 改名软链过去是机器相关做法，项目不做。分层方式见
> `docs/DECISIONS.md` 第 18.1 节。

真机运行截图见 [`docs/screenshots/`](docs/screenshots/)：
欢迎页、空首页、本月首页、整理卡片、月报、右滑确认后、分类选中态、消费趋势。
截图里的金额都是演示账本的真实查询结果（总消费 ¥633.30，与指南 10.1 的基准一致）。

### 本机工具链注意事项

这三条都是**环境问题，不是代码问题**，遇到时不要改业务代码：

1. **`sdkmanager.bat` 不可用**：调用时以 `NTSTATUS 0xC0000409` 崩溃。
   因此任何需要联网补装 Android SDK 组件的操作都会失败。
   当前通过把 `ndkVersion` 显式指向本机已装的 `30.0.16248370` 规避。
2. **关掉了 Kotlin 增量编译**（`kotlin.incremental=false`）：
   pub 缓存在 C 盘、工程在 D 盘，Kotlin 增量缓存跨盘符时
   `relativeTo` 会抛 `different roots`，导致守护进程编译失败。
3. **不要回到桌面上的旧目录**（`OneDrive\桌面\小项目\youshu`）：
   那里的内容已清空并停用（只剩一个空文件夹，等 VS Code 切换工作区后可手动删除）。
   中文路径会让 AGP 直接拒绝构建，OneDrive 还会持续同步构建产物。

## 演示路径：怎么走到每个设计状态

App 不做登录，冷启动进入欢迎页，之后不再重复出现。

```text
欢迎引导 → 空首页 →「先用示例账单体验」→ 本月首页（示例账本）
```

「我的」页在**调试构建**下底部有 **设计状态走查** 入口，按 5 个分组列出全部
33 个设计状态，点进去都是真实页面。Release 构建不注册该路由。

| 想看什么 | 怎么走 |
| --- | --- |
| 导入流程（8 个状态） | 空首页 →「导入月账单」→ 任一来源 → 文件与月份 → 识别账单 → 核对 → 疑似重复 |
| 卡片整理闭环 | 底部「整理」→ 选分类 → 右滑或点确认；左滑进稍后队列；撤销可回退 |
| 整理完成 / 月报 | 把 6 笔全部处理完 →「看看我的整理结果」→ 勾选范围完整 → 月报 |
| 数据看板 | 底部「月报」→ 概况 / 分类详情 / 趋势（近 6 个月）；底部「本月」→「查看明细 ›」 |
| 六套主题 | 「我的」→「主题与配色」；预设点选立即生效，取色器拖动即时预览 |
| 分类图标 | 「我的」→「分类管理」→ 任一分类；保存后卡片与分类网格同步变化 |
| 保存失败路径 | 设计走查 → 打开「交互验证开关」→ 回卡片页确认，卡片应回弹且用途保留 |
| 无消费空态 | 设计走查 →「月报 · 无消费空状态」 |

> **环比与分类变化需要连续两个范围完整的月份。**演示账本只有一个月的数据，
> 所以实机上这些位置会显示「暂无可比月份」而不是数字 —— 这是**正确行为**，
> 不是未完成。相关口径由单元测试覆盖（`test/month_insights_test.dart`）。

## 目录结构

```text
app/
  lib/
    app/                 路由表、根装配、路由参数
    core/
      designsystem/      颜色派生、令牌、字体、尺寸、图标、主题装配
      components/        共用组件（金额、按钮、面板、卡片堆叠、字段、弹层…）
      money/             金额解析与格式化（整数「分」）
      time/              可替换 Clock、统计时区、月度提醒时间推算
      preferences/       主题偏好、引导状态、账本模式
    domain/              纯业务层：不依赖 Flutter、不依赖数据库
      models/            账本、分类、交易、分配、退款关联、月份、会话记录
      rules/             分配守恒、退款抵扣、月度统计、整理进度（纯函数）
      repositories/      仓库与存储端口
    data/
      db/                SQLite 结构、版本化迁移、sqflite 存储实现
      memory/            内存存储（单元测试与存储不可用时兑底）
      seed/              演示账本的初始记录（指南 10.1 基准）
      sample/            尚未接到数据库的页面用的样例数据（阶段 5 清理）
    features/
      start/             欢迎、空首页、本月首页
      import_flow/       来源、指引、上传、识别、字段匹配、核对、重复、异常
      organize/          卡片、分类、分类管理、编辑器、详情、拆分、性质、稍后、完成
      report/            概况、分类详情、趋势、明细、分享、月份
      profile/           我的、主题、导入记录、隐私、提醒、清除确认、保存状态
      review/            设计状态走查（仅调试构建）
  android/               MainActivity（Kotlin）、清单、备份规则
  test/                  纯 Dart 单元测试（业务规则、会话编排、迁移框架）
  integration_test/      真机测试（外键、唯一约束、事务原子性）
  docs/                  DECISIONS.md、IMPLEMENTATION_STATUS.md
```

## 主题系统

主色 `primary` 的派生链（与原型 `theme.js` 逐通道对齐，见
`lib/core/designsystem/color_math.dart`）：

```text
primary   = 原始色每步向黑色混 5%，直到与白色文字对比度 ≥ 4.5:1
onPrimary = #FFFFFF
pressed   = primary → #000000 14%
ink       = primary → #182126 55%
soft      = 原始色 → #FFFFFF 90%
wash      = 原始色 → #FFFFFF 97%   （页面底色）
tint      = 原始色 → #FFFFFF 80%
border    = 原始色 → #FFFFFF 72%
muted     = primary → #707570 60%
```

六套预设：`forest`（默认）、`ocean`、`lavender`、`rose`、`amber`、`slate`。

**不随主题变化**的语义色：危险 / 警告 / 提示条、分类系列色（图例与环形图共用）。

主题偏好存在 `shared_preferences`，**首帧之前**加载完成，避免启动时闪一下默认色。

## 无障碍

* 全部可点击目标 ≥ 48×48dp；图标按钮必须提供可读名称。
* 卡片、分类、主题、月份、重复组都带 `selected` 语义，不只用颜色区分；
  选中的分类还有勾选标记。
* 金额合并为单个朗读单位（如「¥ 8,432.60」），不被逐个字符读出。
* 装饰层（后层卡片、环形图、插画、色块）全部 `ExcludeSemantics`。
* 图表提供文字摘要，不依赖截图。

## 已知限制

* **首页、整理、月报、趋势、明细、分享、月份、我的已经是真实数据库查询**
  （本地 SQLite，10 张表），且共用同一份报告，所以同一笔交易在哪个页面
  都是同一个数字。
* **导入流程**（选择来源 / 上传 / 识别 / 字段映射 / 核对 / 疑似重复 / 异常）
  仍是 `lib/data/sample/sample_data.dart` 里的样例数据（阶段 3）。
* **分类管理**（新建 / 改名 / 图标）仍写内存，重启回到出厂图标（阶段 4）。
* **拆分 / 非消费 / 退款关联**的规则与仓库入口已实现且有测试覆盖，
  但界面还没接上去，用户点不到（阶段 4）。
* **导出**已接入：明细 CSV（防公式注入）与月报海报 PNG（默认隐藏金额，走系统「创建文档」流程）。
* 「导入记录」页仍为样例；「数据管理」里的「导入批次」如实留空。
* 「确认本月范围完整」目前只能从整理完成页进入，月报页还没有入口。
* 未接入系统 Photo Picker，分类图标只能使用 12 个预设矢量图标。
* 提醒未接入后台任务与通知权限。
* 文字缩放上限 1.6（原因见 `docs/DECISIONS.md` 第 4 节）。
* 横屏与平板未做专门适配；界面按竖屏手机设计，窄屏可滚动。
* 旋转、大字号、TalkBack 未在阶段 5 回归。
* 自动化测试已有 **139 个单元测试 + 20 个真机数据库测试**，
  但界面层的 widget test 与截图回归仍未编写（阶段 7）。
* 真实平台账单文件的兼容性**未经验证**，没有任何真实样本被测试过。
* 本机 `sdkmanager` 不可用，后续需要补装 SDK 组件时会受阻（见上文）。
