/// 主题预设。稳定 ID 与原始主色取自指南 7.1 / `theme.js`。
///
/// 原始色值是**用户输入**，派生色（primary / soft / ink…）只用于渲染，
/// 绝不写回存储（指南 7.2）。
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.name,
    required this.mood,
    required this.color,
  });

  /// 稳定 ID，用于持久化与「是否预设」判断。
  final String id;

  final String name;

  /// 设计稿里的气质描述，用于副标题。
  final String mood;

  /// 原始 `0xRRGGBB`。
  final int color;

  String get hex => '#${color.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

abstract final class ThemePresets {
  /// 默认主题 ID（指南 7.1：森林绿，默认）。
  static const String defaultId = 'forest';

  /// 自定义配色的 ID。
  static const String customId = 'custom';

  static const List<ThemePreset> all = <ThemePreset>[
    ThemePreset(id: 'forest', name: '森林绿', mood: '自然 · 安静', color: 0x315F4F),
    ThemePreset(id: 'ocean', name: '雾海蓝', mood: '清爽 · 专注', color: 0x376B96),
    ThemePreset(id: 'lavender', name: '暮山紫', mood: '温柔 · 松弛', color: 0x795A99),
    ThemePreset(id: 'rose', name: '玫瑰粉', mood: '柔和 · 浪漫', color: 0xA45170),
    ThemePreset(id: 'amber', name: '暖杏橙', mood: '温暖 · 活力', color: 0xA96230),
    ThemePreset(id: 'slate', name: '岩石灰', mood: '简约 · 克制', color: 0x53616B),
  ];

  static ThemePreset get defaultPreset =>
      all.firstWhere((p) => p.id == defaultId, orElse: () => all.first);

  /// 按原始色值反查预设 ID；不是预设时返回 [customId]。
  static String idForColor(int color) {
    for (final preset in all) {
      if (preset.color == color) return preset.id;
    }
    return customId;
  }

  static ThemePreset? byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}
