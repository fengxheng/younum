/// 账单来源的命名空间。
///
/// 指南 4.3：去重优先用「平台 / 账户命名空间 + 稳定源交易 ID」判定同源重复，
/// 所以来源要用**稳定标识**存库，不能把「微信支付」这种展示文案当键。
/// 文案改了不应该影响任何一笔历史记录。
library;

/// 来源命名空间与展示文案。
abstract final class LedgerSource {
  /// 微信支付。
  static const String wechat = 'wechat';

  /// 支付宝。
  static const String alipay = 'alipay';

  /// 手工补录。
  static const String manual = 'manual';

  /// 数据库里出现的全部来源。
  static const List<String> all = <String>[wechat, alipay, manual];

  /// 展示名称。未知命名空间如实说明，不猜成某个平台。
  static String labelOf(String? namespace) => switch (namespace) {
        wechat => '微信支付',
        alipay => '支付宝',
        manual => '手工补录',
        null => '未标注来源',
        _ => '其他来源',
      };

  /// 来源行使用的图标键。首版统一用钱包图标。
  static String iconKeyOf(String? namespace) => 'wallet';
}
