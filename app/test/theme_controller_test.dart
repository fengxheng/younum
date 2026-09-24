import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/core/designsystem/theme_presets.dart';

/// 主题持久化测试。
///
/// 对应实现指南 7.2 与 10.4：拖动只预览不写盘、提交才写盘、
/// 写盘失败要保留预览并允许多次重试、冷启动保持选择。
void main() {
  test('冷启动读取已保存的配色', () async {
    final store = InMemoryThemeStore();
    await store.save(
      const ThemePreferences(color: 0xBE4084, presetId: 'custom'),
    );

    final controller = await ThemeController.restore(store);
    expect(controller.rawColor, 0xBE4084);
    expect(controller.isCustom, isTrue);
    expect(controller.displayName, '自定义配色');
  });

  test('没有保存过时使用默认森林绿', () async {
    final controller = await ThemeController.restore(InMemoryThemeStore());
    expect(controller.rawColor, ThemePresets.defaultPreset.color);
    expect(controller.preset?.id, ThemePresets.defaultId);
    expect(controller.isDefault, isTrue);
  });

  test('preview 只改内存，不写盘', () async {
    final store = InMemoryThemeStore();
    final controller = await ThemeController.restore(store);

    controller.preview(0xA45170);
    expect(controller.rawColor, 0xA45170);
    expect(controller.isDirty, isTrue);

    // 重新加载仍应是默认色：预览没有落到磁盘。
    final reloaded = await ThemeController.restore(store);
    expect(reloaded.rawColor, ThemePresets.defaultPreset.color);
  });

  test('apply 会写盘，重启后保持', () async {
    final store = InMemoryThemeStore();
    final controller = await ThemeController.restore(store);

    final outcome = await controller.apply(0x376B96);
    expect(outcome, ThemeSaveOutcome.saved);
    expect(controller.hasUnsavedPreview, isFalse);

    final reloaded = await ThemeController.restore(store);
    expect(reloaded.rawColor, 0x376B96);
    expect(reloaded.preset?.id, 'ocean');
  });

  test('写盘失败：保留预览、明确标记未保存、可重试成功', () async {
    final store = InMemoryThemeStore()..failOnSave = true;
    final controller = await ThemeController.restore(store);

    final failed = await controller.apply(0x795A99);
    expect(failed, ThemeSaveOutcome.previewOnlySaveFailed);
    // 用户仍然看得见自己选的颜色。
    expect(controller.rawColor, 0x795A99);
    expect(controller.hasUnsavedPreview, isTrue);

    // 恢复存储后再重试。
    store.failOnSave = false;
    final retried = await controller.retrySave();
    expect(retried, ThemeSaveOutcome.saved);
    expect(controller.hasUnsavedPreview, isFalse);

    final reloaded = await ThemeController.restore(store);
    expect(reloaded.rawColor, 0x795A99);
  });

  test('放弃预览会回到最后一次成功保存的主题', () async {
    final store = InMemoryThemeStore();
    final controller = await ThemeController.restore(store);
    await controller.apply(0x376B96);

    controller.preview(0xA96230);
    expect(controller.rawColor, 0xA96230);

    controller.revertPreview();
    expect(controller.rawColor, 0x376B96);
    expect(controller.isDirty, isFalse);
  });

  test('恢复默认只改主题，不影响其它偏好', () async {
    final store = InMemoryThemeStore();
    final controller = await ThemeController.restore(store);
    await controller.apply(0x53616B);
    expect(controller.isDefault, isFalse);

    final outcome = await controller.restoreDefault();
    expect(outcome, ThemeSaveOutcome.saved);
    expect(controller.rawColor, ThemePresets.defaultPreset.color);
    expect(controller.isDefault, isTrue);
  });

  test('损坏的偏好回退到默认，不抛异常', () async {
    final store = InMemoryThemeStore(const <String, String>{
      PreferenceKeys.theme: '{"version":1,"color":"not-a-color"}',
    });
    final controller = await ThemeController.restore(store);
    expect(controller.rawColor, ThemePresets.defaultPreset.color);
  });

  test('纯白与纯黄也可作为自定义主色保存', () async {
    final store = InMemoryThemeStore();
    final controller = await ThemeController.restore(store);

    for (final color in <int>[0xFFFFFF, 0x000000, 0xFFFF00, 0xBE4084]) {
      final outcome = await controller.apply(color);
      expect(outcome, ThemeSaveOutcome.saved);
      // 原始输入值必须原样保留，不被派生色覆盖。
      expect(controller.rawColor, color);
      expect(controller.hex, '#${color.toRadixString(16).padLeft(6, '0').toUpperCase()}');
    }
  });
}
