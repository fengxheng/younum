/// 文本编码探测与解码。
///
/// 指南 4.2.4：CSV 必须支持 **引号、字段内逗号、换行、BOM、CRLF 和平台常见编码**；
/// **编码无法确定时允许选择，不默默吞乱码**。
///
/// 现实情况：微信导出的 CSV 是带 BOM 的 UTF-8，支付宝导出的常见是 GBK。
/// GBK 是 Dart 标准库没有的编码，因此引入 `charset`（**纯 Dart**，不含原生代码，
/// 不参与 Android 构建，所以没有多一个原生编译环节的风险）。
///
/// 探测策略与它的局限都写在 [decode] 上，不假装是万无一失的。
library;

import 'dart:convert';

import 'package:charset/charset.dart';

/// 支持的编码。
enum TextEncoding {
  /// UTF-8（可能带 BOM）。
  utf8('UTF-8'),

  /// GBK / GB18030。
  ///
  /// 支付宝等平台的导出常见。`charset` 的 GBK 解码表覆盖 GB18030 的常用区。
  gbk('GBK / GB18030');

  const TextEncoding(this.label);

  /// 给用户看的名称。
  final String label;

  /// 数据库里保存的值。显式映射，不依赖 `Enum.name`。
  String get storageValue => switch (this) {
        TextEncoding.utf8 => 'UTF-8',
        TextEncoding.gbk => 'GBK',
      };

  static TextEncoding? tryParse(String? value) => switch (value) {
        'UTF-8' => TextEncoding.utf8,
        'GBK' => TextEncoding.gbk,
        _ => null,
      };
}

/// 解码结果。
final class DecodedText {
  const DecodedText({
    required this.text,
    required this.encoding,
    required this.hadByteOrderMark,
    required this.detected,
  });

  final String text;

  final TextEncoding encoding;

  /// 原文是不是带 BOM 的（BOM 已被去掉）。
  final bool hadByteOrderMark;

  /// true 表示编码是探测出来的，false 表示用户指定。
  final bool detected;

  @override
  String toString() =>
      'DecodedText(${encoding.label}, bom=$hadByteOrderMark, detected=$detected)';
}

/// 解码失败的原因。
sealed class DecodeError {
  const DecodeError(this.message);

  final String message;
}

/// 首版不支持的编码。
///
/// 明确说明而不是硬猜：猜错会得到一整份乱码，用户还以为导入成功了。
final class DecodeUnsupportedEncoding extends DecodeError {
  const DecodeUnsupportedEncoding(this.encodingName)
      : super('这个文件是 $encodingName 编码，首版还不支持。'
            '可以在导出时选择「UTF-8」或「GBK」，或者用表格软件另存为 CSV。');

  final String encodingName;
}

/// 无法确定编码，需要用户自己选。
final class DecodeAmbiguous extends DecodeError {
  const DecodeAmbiguous()
      : super('无法判断这个文件是哪种编码。请手动选择一次，选错了会看到乱码。');
}

/// 空文件。
final class DecodeEmptyFile extends DecodeError {
  const DecodeEmptyFile() : super('这个文件是空的，没有内容可以解析。');
}

/// 编码探测与解码。
abstract final class TextDecoding {
  /// 可以让用户选的编码，顺序即展示顺序。
  static const List<TextEncoding> selectable = <TextEncoding>[
    TextEncoding.utf8,
    TextEncoding.gbk,
  ];

  /// 解码。
  ///
  /// 策略（按顺序）：
  ///
  /// 1. 有 BOM 就按 BOM 说的算 —— 这是唯一一个不需要猜的信号；
  /// 2. 能按 UTF-8 **严格**解码就当作 UTF-8。GBK 编码的中文几乎不可能
  ///    恰好构成合法的 UTF-8 序列，所以这个判据在实践中很可靠；
  /// 3. 否则按 GBK 严格解码，同时按 UTF-8 **宽松**解码（把坏字节换成 U+FFFD），
  ///    用「可读字符占比」挑更像的那一个；
  /// 4. 两个都不像可读文本 → 交给用户选。
  ///
  /// **局限**：第 3 步是启发式，不是保证。它对「大部分是中文与 ASCII 的账单」
  /// 判断准确，但如果文件本身就是乱码或二进制，它可能仍然给出一个结果 ——
  /// 所以界面必须把**探测出的编码显示出来**，让用户有机会发现不对。
  ///
  /// 传 [force] 时跳过探测，直接按指定编码解。
  static (DecodedText?, DecodeError?) decode(
    List<int> bytes, {
    TextEncoding? force,
  }) {
    if (bytes.isEmpty) return (null, const DecodeEmptyFile());

    if (force != null) {
      final text = _decodeWith(bytes, force);
      if (text == null) return (null, const DecodeAmbiguous());
      return (
        DecodedText(
          text: _stripBom(text),
          encoding: force,
          hadByteOrderMark: false,
          detected: false,
        ),
        null,
      );
    }

    // 1. BOM
    final bom = _bomOf(bytes);
    if (bom == 'UTF-8') {
      return (
        DecodedText(
          text: _stripBom(utf8.decode(bytes, allowMalformed: true)),
          encoding: TextEncoding.utf8,
          hadByteOrderMark: true,
          detected: true,
        ),
        null,
      );
    }
    if (bom != null) {
      // UTF-16 等：明确说不支持，而不是硬猜出一个乱码结果。
      return (null, DecodeUnsupportedEncoding(bom));
    }

    // 2. 严格 UTF-8
    try {
      final text = utf8.decode(bytes);
      return (
        DecodedText(
          text: _stripBom(text),
          encoding: TextEncoding.utf8,
          hadByteOrderMark: false,
          detected: true,
        ),
        null,
      );
    } on FormatException {
      // 落到第 3 步。
    }

    // 3. 比较 GBK 严格解码与 UTF-8 宽松解码
    final asGbk = _tryStrictGbk(bytes);
    final asUtf8Lenient = utf8.decode(bytes, allowMalformed: true);

    final gbkScore = asGbk == null ? null : _score(asGbk);
    final utf8Score = _score(asUtf8Lenient);

    final gbkOk = gbkScore != null && gbkScore.isPlausibleText;
    final utf8Ok = utf8Score.isPlausibleText;

    if (gbkOk && (!utf8Ok || gbkScore.readable > utf8Score.readable)) {
      return (
        DecodedText(
          text: _stripBom(asGbk!),
          encoding: TextEncoding.gbk,
          hadByteOrderMark: false,
          detected: true,
        ),
        null,
      );
    }
    if (utf8Ok) {
      return (
        DecodedText(
          text: _stripBom(asUtf8Lenient),
          encoding: TextEncoding.utf8,
          hadByteOrderMark: false,
          detected: true,
        ),
        null,
      );
    }
    return (null, const DecodeAmbiguous());
  }

  /// 只探测，不返回内容。给「编码选择器」显示当前判断用。
  static TextEncoding? detect(List<int> bytes) => decode(bytes).$1?.encoding;

  /// BOM 的编码名。返回 null 表示没有 BOM。
  static String? _bomOf(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return 'UTF-8';
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return 'UTF-16 LE';
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return 'UTF-16 BE';
    }
    return null;
  }

  static String? _decodeWith(List<int> bytes, TextEncoding encoding) {
    switch (encoding) {
      case TextEncoding.utf8:
        return utf8.decode(bytes, allowMalformed: true);
      case TextEncoding.gbk:
        return _tryStrictGbk(bytes) ?? gbk.decode(bytes, allowMalformed: true);
    }
  }

  static String? _tryStrictGbk(List<int> bytes) {
    try {
      return gbk.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static String _stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;

  /// 「像不像可读文本」的打分。
  static _Plausibility _score(String text) {
    if (text.isEmpty) return const _Plausibility(0, 0);
    var good = 0;
    var ascii = 0;
    var length = 0;
    for (final rune in text.runes) {
      length++;
      if (_isPlausibleRune(rune)) good++;
      if (rune < 0x80) ascii++;
    }
    return _Plausibility(good / length, ascii / length);
  }

  static bool _isPlausibleRune(int rune) {
    // ASCII 可打印 + 常见空白
    if (rune >= 0x20 && rune <= 0x7E) return true;
    if (rune == 0x09 || rune == 0x0A || rune == 0x0D) return true;
    // CJK 统一表意文字（含扩展 A）
    if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    if (rune >= 0x3400 && rune <= 0x4DBF) return true;
    // 中文标点与全角字符
    if (rune >= 0x3000 && rune <= 0x303F) return true;
    if (rune >= 0xFF00 && rune <= 0xFFEF) return true;
    // 常见符号
    if (rune >= 0x2000 && rune <= 0x206F) return true;
    if (rune == 0xFFFD) return false; // 替换字符一定不是好信号
    return false;
  }
}

/// 一段文本的可读性打分。
final class _Plausibility {
  const _Plausibility(this.readable, this.asciiRatio);

  /// 落在「可读字符」集合里的比例。
  final double readable;

  /// ASCII 字符占比。
  final double asciiRatio;

  /// 是否够格当成「正确的解码结果」。
  ///
  /// 两个条件：
  ///
  /// * [readable] 高 —— 排除解错编码产生的大量生僻字与替换字符；
  /// * [asciiRatio] **大于零** —— 这一条是必需的，因为 **GBK 几乎能把任意
  ///   偶数字节序列都解成合法汉字**，只看「解码是否成功」或「有没有汉字」，
  ///   会把一段二进制数据当成一份中文账单。
  ///
  /// 为什么只要求「至少一个 ASCII 字符」而不是某个比例：中文表头可能几乎全是
  /// 汉字，定高了会误杀真文件。而作为一份 **CSV 文件**，它必然有换行
  /// （`\n` 或 `\r`）和分隔符，这些都是 ASCII；纯高位字节的噪声则一个都没有。
  bool get isPlausibleText => readable > 0.9 && asciiRatio > 0;

  @override
  String toString() =>
      '_Plausibility(readable=${readable.toStringAsFixed(3)}, '
      'ascii=${asciiRatio.toStringAsFixed(3)})';
}
