# 给 AI 协作者的改动指南（有数 / younum）

这份文档面向**接手这个仓库的 AI 助手**（人类协作者同样适用）。

它只有一个目标：**让改动可验证、可回滚，并且不把别人的工作弄乱。**

请动手之前读完（大约 5 分钟）。下面每一条都来自真实踩过的坑，
不是风格偏好 —— 违反其中任何一条，都可能让一次「小修」变成一场事故。

---

## 0. 先认清这个仓库

| 事实 | 值 |
| --- | --- |
| 仓库根 | `D:\dev\younum`（`app/` 是 Flutter 工程；`设计稿/` **不在仓库里**） |
| 技术栈 | Flutter 3.47.5 / Dart 3.13.4，单 Activity + Kotlin，SQLite（SQLCipher 加密） |
| 规模 | `lib/` 106 个 Dart 文件；`test/` 58 个测试文件 |
| 当前基线 | `flutter analyze` **零告警**；`flutter test` **全绿**；真机 SQL 测试**全绿** |
| 怎么读代码 | 先读 [`app/README.md`](app/README.md) 的「目录结构」，再读 [`app/test/README.md`](app/test/README.md) |

**事实来源的优先级**（冲突时按这个顺序）：

```text
设计稿/安卓APP实现指南.md（需求，不在仓库里）
  > 本仓库 docs/（DECISIONS 是「为什么」，MANUAL_CHECKS 是「验到什么程度」）
  > 代码里的注释
  > 你的推测  ← 永远不要拿这个当依据
```

代码注释里频繁出现的「指南 3.5.8」「设计稿 14.3」指的就是那份**私有**指南。
读不到它并不意味着可以自由发挥：**拿不准就先去 `docs/DECISIONS.md` 里找
有没有相关记录，或者直接问用户。**

---

## 1. 拿到一个 bug，先分清「数据」还是「界面」

这一步能省掉大量瞎猜。**真机上出问题时，先做这两个动作**：

```powershell
# 进程还在吗？
adb shell pidof com.younum.app

# 重启一次，看问题还在不在
adb shell am force-stop com.younum.app; adb shell am start -n com.younum.app/.MainActivity
```

| 现象 | 大概率是 | 往哪查 |
| --- | --- | --- |
| 进程在 + 白屏 | 渲染 / 窗口 | logcat 里的 `I/flutter` 有没有 Dart 输出 |
| 进程不在 | 原生层崩了 | `AndroidRuntime` + `FATAL EXCEPTION`；栈里出现 `r8-map-id-` 就是 release 专属的 R8 裁剪 |
| **重启之后就好了** | **界面拿着一份旧快照** | 谁改了数据？谁该重读？见 `docs/DECISIONS.md` 第 68 节 |
| 重启之后还是不对 | 数据真的写坏了 | 先看写库那条路径是不是事务、有没有半截状态 |

这条分诊法是花时间换来的：曾经有一轮「导入完首页什么都没有」被当成
「导入没保存」查了很久，其实**杀掉应用重开数据全在** —— 界面拿着旧快照而已。

---

## 2. 动手之前必须做的五件事

1. **能复现**，并且写清楚复现步骤。复现不了就先想办法复现（造数据、写测试），
   不要凭猜测改代码。
2. **分清数据还是界面**（见上一节）。
3. **先写一条会失败的测试，并真的看到它红。**
   这是本仓库最硬的约定，做法在下面第 3 节。
4. **判断影响面**，决定改完之后要跑哪些验证（第 4 节的表）。
   改动是不是碰了 SQL？是不是碰了原生？是不是会进发布包？
5. **读一眼相关代码的注释与 `docs/DECISIONS.md`。**
   这个仓库的注释密度很高，而且**大部分写的是「为什么不那样做」** ——
   你想到的「更简洁的写法」，很可能正是某次事故之后被刻意排除的。

---

## 3. 修 bug 的标准动作：先让它红

```text
① 写一条测试，断言「正确的行为」
② 跑它 → 必须失败，而且失败信息要和你观察到的现象对得上
③ 改代码
④ 再跑 → 变绿
⑤ 把修复临时去掉再跑一次 → 确认它又变红（防止测试其实没覆盖到）
```

第 ② 步和第 ⑤ 步是关键。**没红过的测试只是个摆设**，
它会在下次重构时给你虚假的安全感。

真实例子（可以照着学）：修「导入提交后界面不刷新」时，用例里断言
「提交后整理页不该再显示『这个月还没有账单』」；把新加的接线注释掉再跑，
它立刻变红，报的正是真机上那句话。这就是一条有牙齿的测试。

如果一条测试**没法**先红（例如它测的是「新增的功能」而不是「修好的 bug」），
那就把它写清楚：**它锁的是什么行为、什么情况下会失效**。

---

## 4. 改完之后必须做什么（按改动类型查表）

| 你改了什么 | 必须跑 | 其他要求 |
| --- | --- | --- |
| 任何 Dart 代码 | `flutter analyze` + `flutter test` | 数字变了就更新 `docs/TEST_REPORT.md` 与 `docs/IMPLEMENTATION_STATUS.md` |
| `lib/domain/rules/**`（纯规则） | 同上 + 对应规则用例 | 口径变了必须写进 `docs/DECISIONS.md`（新开一节，说明为什么） |
| `lib/domain/repositories/**`、`lib/data/db/**`、`lib/data/memory/**` | 同上 + **真机** `flutter test integration_test/database_test.dart -d <设备>` | **端口的两套实现都要改**（内存 + sqflite），并各有用例 |
| `lib/features/**`（界面/控制器） | 同上 + 对应的 widget 测试 | 新增界面路径要有界面测试；必要时真机截图确认 |
| Kotlin / Manifest / Gradle / 依赖 | 上面全部 **+ `flutter build apk --release` 并装到真机点开看一眼** | debug 构建与 `flutter analyze` **都发现不了** R8 类问题 |
| 涉及 SQL 结构 | 上面全部 + 迁移链用例（`migrations_test.dart` + 真机 `database_test.dart` 的迁移组） | 老库要能升上来，且**数据一条不少** |
| 只改文档 | 核对命令、路径、数字是否与实际一致 | 别把「未验证」写成「已通过」 |
| 版本号 / 发布相关 | 照 `docs/RELEASE.md` 的清单走 | 这个仓库有「Release 不可变」等机制，**顺序不能错** |

常用命令（在 `app/` 下）：

```powershell
flutter analyze
flutter test
flutter test integration_test/database_test.dart -d <设备>
flutter test integration_test/file_source_test.dart -d <设备>
flutter build apk --release     # 只在改了原生/依赖/准备发版时才必须
```

真机上跑界面时的两个小工具（省时间，也是踩坑换来的）：

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"

# 点界面：**必须用带时长的 swipe 代替 tap**（tap 的按下-抬起几乎同刻，
# 真机上会被 Flutter 的手势竞技场丢掉，表现为「点了没反应」）
& $adb -s <设备> shell input swipe <x> <y> <x> <y> 140

# 看界面元素（拿到真实的坐标与 content-desc）
& $adb -s <设备> shell uiautomator dump /sdcard/ui.xml
& $adb -s <设备> shell cat /sdcard/ui.xml
```

> 终端里读中文输出有时会被吞掉。稳妥做法是把命令输出写进文件再读：
> `... > "$env:TEMP\out.txt"`，然后 `Get-Content "$env:TEMP\out.txt" -Encoding UTF8`。

---

## 5. 动手时的代码约定

* **守住分层**（详见 `app/README.md`）：
  `features → domain（规则 + 端口）→ data（真实实现）`。
  `domain/` 里**不 import Flutter、不碰 SQL**。需要新能力就在
  `domain/repositories/` 定义端口、在 `data/` 给实现、由 `app/app.dart` 注入 ——
  这样测试才能把「选文件」「保存导出」「升级安装」换成假实现。
* **注释写「为什么」，不写「做了什么」。**
  一看就懂的代码不要注释；需要解释的是**取舍**。
* **给用户看的错误消息要能直接读。** 规则层返回的拒绝理由会原样出现在界面上，
  不要写「error: 42」这种东西。
* **不撒谎**：拿不到数据的路径（网络失败、权限没给、版本读不到）
  绝不能显示成「已是最新 / 已开启 / 已保存」。这条在本仓库有专门用例守着。
* **提交信息用中文**，第一行说清改了什么，正文写**为什么**与**怎么验的**，
  和仓库里现有提交保持一致。

### 绝对不要做

| 不要 | 原因 |
| --- | --- |
| 跑 `dart format lib test integration_test` | 这个仓库是用**旧版** formatter 排版的；当前 SDK 的 tall style 会把 166 个文件里的 **118 个**全重排（数千行噪声），还会额外引入 `curly_braces_in_flow_control_structures` 告警 |
| 提交 `android/key.properties`、`*.jks`、`*.keystore` | 凭据不进仓库（已 gitignore，但别用 `-f` 绕开） |
| 提交 `app/test/账单/`、`设计稿/` | 真实账单与设计稿都是**私有的**，已在 `.gitignore` 里 |
| 把 token / 密码打印到输出里 | 需要凭据时从系统凭据管理器取，别 echo |
| 大范围重构、顺手改无关文件 | diff 一大，review 与回滚都失效。一次只做一件事 |
| 为了让测试变绿而改断言 | 除非你能说清「断言本身写错了，因为口径变了」并写进 DECISIONS |
| 声称未验证的事情已验证 | 人工核对清单里标着未验证的，就是没验过 |
| 删掉别人的注释（尤其是「为什么」） | 那些注释是资产 |

---

## 6. 文档必须跟着改

这个仓库的文档不是装饰，是**验收依据**。改完代码后按这张表更新：

| 改了什么 | 更新 |
| --- | --- |
| 任何取舍 / 偏离设计 / 修了一个真 bug | `app/docs/DECISIONS.md` 开**新的一节**（编号接着往下），写清现象、根因、修法、为什么这么修 |
| 完成度、验证程度、未验证项 | `app/docs/IMPLEMENTATION_STATUS.md` |
| 测试数量 | `app/docs/TEST_REPORT.md` + `IMPLEMENTATION_STATUS.md` 里的数字（**只写实际跑出来的**） |
| 需要人手验的东西 | `app/docs/MANUAL_CHECKS.md`（带复选框，标清哪些已验、哪天验的） |
| 构建 / 安装 / 发版流程 | `app/docs/RELEASE.md` |
| 目录结构、功能清单、环境要求 | `app/README.md` |
| 新增测试文件 | `app/test/README.md` 的清单 |

---

## 7. 常见坑速查

| 症状 | 原因 / 处理 |
| --- | --- |
| release 包**点开图标什么都没发生**，没有白屏、没有 flutter 日志 | R8 把反射实例化的类裁掉了。看 `AndroidRuntime` 的 `FATAL EXCEPTION`；保留规则在 `android/app/proguard-rules.pro`。**debug 构建永远看不出来** |
| 真机上「按钮点了没反应」 | `adb shell input tap` 被手势竞技场丢掉，改用 `input swipe x y x y 140` |
| 换了 `input swipe` 还是点不动任何东西（但 `input keyevent` 有效） | 有些小米/红米**整个屏蔽注入的点击**（`tap` 与 `swipe` 都不进应用，系统自己的窗口却能点到）。先在开发者选项里打开「USB 调试（安全设置）」；开不了就只能人工点，或用 widget 测试顶住接线 |
| 同一段文本匹配到两个节点（点到了标题） | 页面标题与按钮文案常常一样；按 `class="android.widget.Button"` 或 `enabled` 区分，或取 `bounds` 自己算坐标 |
| MIUI 安装失败 `INSTALL_FAILED_USER_RESTRICTED` | 先 `input keyevent KEYCODE_WAKEUP` + `svc power stayon true` 再重试 |
| 覆盖安装要清数据 | 换了签名（debug ↔ release）就等于换了应用。同签名覆盖安装**不会**丢数据 |
| `flutter install` 把数据弄没了 | 它装 release 包并**先卸载**。要装调试包用 `adb install -r` |
| sqflite 报同一个异常两次 | 一次回到 await 的 Future，一次落到 zone；测试里用 try/catch，别用 `runZonedGuarded`（会卡到超时） |
| 用错误口令打开加密库「打不开」测不出来 | sqflite 按**路径**缓存实例；测试要换一条没被打开过的路径（拷一份） |
| 发布时 APK 传不上去 / 标签变成 `untagged-xxxx` | 这个仓库开了「Release 不可变」且不允许 API 建标签。**先 `git push <tag>` → 建草稿 → 传 APK → 再发布**，详见 `docs/RELEASE.md` |
| 单元测试里想用 SQLite | 本机没有 `sqlite3.dll`，用不了。纯逻辑用内存实现，SQL 行为一律在真机上验 |
| `grep_search` / `file_search` 返回空 | 这台机器上的已知现象，改用终端 `Get-ChildItem -Recurse | Select-String` |

---

## 8. 收尾清单（提交之前逐项过一遍）

- [ ] `flutter analyze` 零告警
- [ ] `flutter test` 全绿（**数字变了就更新文档**）
- [ ] 碰了 SQL / 存储 → 真机 `database_test.dart` 全绿，**内存实现也一起改了**
- [ ] 碰了原生 / 依赖 / 准备发版 → `flutter build apk --release` 并**真机点开看过**
- [ ] 新写的测试**验证过它会红**（或者写清了它锁的是什么行为）
- [ ] `docs/DECISIONS.md` 补了这次的取舍与根因
- [ ] 需要人工验的部分写进了 `docs/MANUAL_CHECKS.md`，**没验的不写成已验**
- [ ] 没有改动无关文件、没有跑全库格式化、没有提交凭据/真实账单/设计稿
- [ ] 提交信息说清了「改了什么、为什么、怎么验的」

**如果某一步你做不到（例如没有设备），就在提交信息与文档里写清楚
「没验」** —— 这个仓库对「未验证」是宽容的，对「假装验证过」是零容忍。
