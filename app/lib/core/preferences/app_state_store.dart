import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 账本模式。
///
/// 实现指南 1.3：示例体验只能进入独立的演示账本，**不得混入用户的真实账本**；
/// 退出演示后恢复真实数据。这里把两者做成互斥模式，避免出现「示例记录进了
/// 真实月度概况」这类事故。
enum LedgerMode {
  /// 真实账本。
  real,

  /// 隔离的演示账本。
  demo;

  static LedgerMode parse(String? value) =>
      value == demo.name ? LedgerMode.demo : LedgerMode.real;
}

/// 应用级状态快照。
class AppState {
  const AppState({required this.onboardingSeen, required this.ledgerMode});

  const AppState.initial() : onboardingSeen = false, ledgerMode = LedgerMode.real;

  final bool onboardingSeen;
  final LedgerMode ledgerMode;

  AppState copyWith({bool? onboardingSeen, LedgerMode? ledgerMode}) => AppState(
        onboardingSeen: onboardingSeen ?? this.onboardingSeen,
        ledgerMode: ledgerMode ?? this.ledgerMode,
      );
}

/// 应用级状态存储接口。
abstract interface class AppStateStore {
  Future<AppState> load();

  Future<void> save(AppState state);
}

/// SharedPreferences 实现。
///
/// 只存引导状态与账本模式这类小配置；账单本身未来落在本地数据库，
/// 不走这里（指南 7.2 的同类约束）。
class SharedPreferencesAppStateStore implements AppStateStore {
  SharedPreferencesAppStateStore(this._preferences);

  final SharedPreferences _preferences;

  static const String _onboardingKey = 'younum.onboarding.seen';
  static const String _ledgerKey = 'younum.ledger.mode';

  static Future<SharedPreferencesAppStateStore> open() async =>
      SharedPreferencesAppStateStore(await SharedPreferences.getInstance());

  @override
  Future<AppState> load() async => AppState(
        onboardingSeen: _preferences.getBool(_onboardingKey) ?? false,
        ledgerMode: LedgerMode.parse(_preferences.getString(_ledgerKey)),
      );

  @override
  Future<void> save(AppState state) async {
    await _preferences.setBool(_onboardingKey, state.onboardingSeen);
    await _preferences.setString(_ledgerKey, state.ledgerMode.name);
  }
}

/// 内存实现，供测试与存储不可用时兜底。
class InMemoryAppStateStore implements AppStateStore {
  InMemoryAppStateStore([this._state = const AppState.initial()]);

  AppState _state;

  @override
  Future<AppState> load() async => _state;

  @override
  Future<void> save(AppState state) async => _state = state;
}

/// 应用级状态控制器。
class AppStateController extends ChangeNotifier {
  AppStateController(this._store, this._state);

  final AppStateStore _store;
  AppState _state;

  static Future<AppStateController> restore(AppStateStore store) async {
    AppState state;
    try {
      state = await store.load();
    } catch (_) {
      state = const AppState.initial();
    }
    return AppStateController(store, state);
  }

  bool get onboardingSeen => _state.onboardingSeen;

  LedgerMode get ledgerMode => _state.ledgerMode;

  bool get isDemoLedger => _state.ledgerMode == LedgerMode.demo;

  /// 是否已有账单数据。
  ///
  /// 阶段 2 起改为查询数据库；目前以「是否进入演示账本」近似表达，
  /// 以便走查同时覆盖 `empty` 与 `home` 两个设计状态。
  bool get hasBills => _state.ledgerMode == LedgerMode.demo;

  /// 引导完成后持久化，避免每次启动重复出现（阶段 1 验收条件）。
  Future<void> completeOnboarding() => _update(_state.copyWith(onboardingSeen: true));

  /// 进入隔离的演示账本。
  Future<void> enterDemoLedger() =>
      _update(_state.copyWith(ledgerMode: LedgerMode.demo));

  /// 退出演示，恢复真实账本。
  Future<void> exitDemoLedger() =>
      _update(_state.copyWith(ledgerMode: LedgerMode.real));

  /// 清除本地账单后回到空状态。
  ///
  /// 首版约定：保留独立主题偏好与已看引导状态（指南 8.3），因此这里只改账本数据。
  Future<void> clearLedger() => _update(_state.copyWith(ledgerMode: LedgerMode.real));

  Future<void> _update(AppState next) async {
    _state = next;
    notifyListeners();
    try {
      await _store.save(next);
    } catch (_) {
      // 写入失败不回滚内存状态：用户当下看到的行为仍然一致，
      // 下次启动会回落到上一次成功保存的值。
    }
  }
}

/// 把 [AppStateController] 提供给子树。
class AppStateScope extends InheritedNotifier<AppStateController> {
  const AppStateScope({
    super.key,
    required AppStateController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppStateController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }

  static AppStateController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }
}
