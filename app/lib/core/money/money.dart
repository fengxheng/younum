/// 金额处理。
///
/// 硬性规则（实现指南 3.1）：
/// * 所有人民币金额以 `int` 保存「分」，例如 ¥28.00 = `2800`。
/// * 数据库与业务计算**禁止** `double` / `float` 金额。
/// * 超过两位小数的输入进入异常待处理，不能默默四舍五入。
///
/// 这里之所以用 `int` 而不是 `BigInt`：`int` 在 Dart 中为 64 位，可表示约
/// ±9.2 × 10^16 分（约 9 × 10^14 元），远超个人账单量级；同时提供显式的
/// [addAll] 溢出检查，避免极端输入静默回绕。
library;

/// 金额解析失败的原因。使用明确错误类型，不把一切异常都说成同一种错。
sealed class MoneyError {
  const MoneyError(this.message);

  final String message;
}

/// 输入为空。
final class EmptyAmount extends MoneyError {
  const EmptyAmount() : super('请填写金额');
}

/// 不是合法数字，或小数位超过两位。
final class InvalidAmount extends MoneyError {
  const InvalidAmount(this.detail) : super(detail);

  final String detail;
}

/// 超出可表示范围。
final class AmountOutOfRange extends MoneyError {
  const AmountOutOfRange() : super('金额超出可处理范围');
}

abstract final class Money {
  /// 1 元 = 100 分。
  static const int centsPerYuan = 100;

  /// 允许的绝对值上限（分）。约 1 亿元，足够个人账单且远离 [int] 边界。
  static const int maxAbsCents = 10000000000;

  /// 千分位分组。
  static String _group(String digits) {
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// `2800` → `'28.00'`；`-3650` → `'-36.50'`。
  static String format(int cents, {bool grouped = false}) {
    final negative = cents < 0;
    final abs = negative ? -cents : cents;
    final yuan = abs ~/ centsPerYuan;
    final fraction = abs % centsPerYuan;
    final whole = grouped ? _group(yuan.toString()) : yuan.toString();
    return '${negative ? '-' : ''}$whole.${fraction.toString().padLeft(2, '0')}';
  }

  /// 带符号的展示形式：支出显示 `−28.00`，退款显示 `+28.00`。
  ///
  /// 使用 U+2212 减号而非连字符，视觉上更清晰，也避免与短横线混淆。
  static String formatWithSign(int cents, {bool grouped = false}) {
    final body = format(cents.abs(), grouped: grouped);
    return cents < 0 ? '\u2212$body' : '+$body';
  }

  /// 只取整数元部分（列表摘要）。
  static int yuanPart(int cents) => cents ~/ centsPerYuan;

  /// 精确解析「元」字符串为「分」。
  ///
  /// 全程按十进制字符串处理，不经过 `double`，因此不存在 `0.1 + 0.2` 之类的
  /// 精度漂移，也不会把 `0.005` 悄悄四舍五入成 `0.01`。
  static (int?, MoneyError?) parseYuan(String input) {
    final text = input.trim().replaceAll(',', '').replaceAll('，', '');
    if (text.isEmpty) return (null, const EmptyAmount());

    var body = text;
    var negative = false;
    if (body.startsWith('+')) {
      body = body.substring(1);
    } else if (body.startsWith('-') || body.startsWith('\u2212')) {
      negative = true;
      body = body.substring(1);
    }
    if (body.isEmpty) return (null, const InvalidAmount('缺少数字'));

    final parts = body.split('.');
    if (parts.length > 2) return (null, const InvalidAmount('小数点数量不正确'));

    final wholeText = parts[0].isEmpty ? '0' : parts[0];
    final fractionText = parts.length == 2 ? parts[1] : '';
    if (!RegExp(r'^\d+$').hasMatch(wholeText)) {
      return (null, const InvalidAmount('包含无法识别的字符'));
    }
    if (fractionText.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fractionText)) {
      return (null, const InvalidAmount('小数部分包含无法识别的字符'));
    }
    if (fractionText.length > 2) {
      return (null, const InvalidAmount('金额最多保留两位小数'));
    }

    final whole = int.tryParse(wholeText);
    if (whole == null) return (null, const AmountOutOfRange());
    final fraction = fractionText.isEmpty
        ? 0
        : int.parse(fractionText.padRight(2, '0'));

    final total = whole * centsPerYuan + fraction;
    if (total > maxAbsCents) return (null, const AmountOutOfRange());
    return (negative ? -total : total, null);
  }

  /// 求和并检查溢出（指南 3.1：金额加总检查溢出）。
  ///
  /// 返回 null 表示结果超出安全范围，调用方必须作为错误处理，不得截断。
  static int? addAll(Iterable<int> amounts) {
    var total = 0;
    for (final amount in amounts) {
      final next = total + amount;
      // 同号相加却变号，说明发生了 64 位回绕。
      if (((total ^ next) & (amount ^ next)) < 0) return null;
      if (next.abs() > maxAbsCents) return null;
      total = next;
    }
    return total;
  }
}
