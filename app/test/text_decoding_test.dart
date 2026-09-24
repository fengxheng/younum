import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/rules/text_decoding.dart';

/// 编码探测与解码。
///
/// 指南 4.2.4：平台常见编码都要支持；无法确定时允许用户选择，
/// 不默默吞乱码。
void main() {
  /// '微' '信' '支' '付' 的 GBK 码位。
  ///
  /// 这里**硬编码字节**而不是用 `gbk.encode` 现场生成：
  /// 否则就是用同一个库编码再用同一个库解码，等于什么都没验证。
  const wechatGbk = <int>[0xCE, 0xA2, 0xD0, 0xC5, 0xD6, 0xA7, 0xB8, 0xB6];

  group('UTF-8', () {
    test('带 BOM 的 UTF-8：BOM 被去掉，并记下来源', () {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('商户,金额')];
      final (decoded, error) = TextDecoding.decode(bytes);

      expect(error, isNull);
      expect(decoded!.text, '商户,金额');
      expect(decoded.encoding, TextEncoding.utf8);
      expect(decoded.hadByteOrderMark, isTrue);
      expect(decoded.text.startsWith('\uFEFF'), isFalse);
    });

    test('不带 BOM 的 UTF-8', () {
      final (decoded, error) = TextDecoding.decode(utf8.encode('交易时间,金额'));
      expect(error, isNull);
      expect(decoded!.encoding, TextEncoding.utf8);
      expect(decoded.hadByteOrderMark, isFalse);
      expect(decoded.detected, isTrue);
    });

    test('纯 ASCII 也判成 UTF-8', () {
      final (decoded, _) = TextDecoding.decode(utf8.encode('a,b,c\n1,2,3'));
      expect(decoded!.encoding, TextEncoding.utf8);
    });
  });

  group('GBK', () {
    test('GBK 中文能被正确识别并还原', () {
      // 真实文件里总是有 ASCII（分隔符、换行），这里补上一个逗号让输入贴近现实。
      final (decoded, error) = TextDecoding.decode(<int>[...wechatGbk, 0x2C]);

      expect(error, isNull);
      expect(decoded!.encoding, TextEncoding.gbk);
      expect(decoded.text, '微信支付,');
    });

    test('GBK 的完整一行（含 ASCII 与中文）', () {
      // '交易时间' + ',' + '商户' 的 GBK 字节
      final bytes = <int>[
        0xBD, 0xBB, 0xD2, 0xD7, 0xCA, 0xB1, 0xBC, 0xE4, // 交易时间
        0x2C,
        0xC9, 0xCC, 0xBB, 0xA7, // 商户
      ];
      final (decoded, error) = TextDecoding.decode(bytes);

      expect(error, isNull);
      expect(decoded!.encoding, TextEncoding.gbk);
      expect(decoded.text, '交易时间,商户');
    });

    test('强制指定 GBK 时跳过探测', () {
      final (decoded, _) = TextDecoding.decode(<int>[
        ...wechatGbk,
      ], force: TextEncoding.gbk);
      expect(decoded!.text, '微信支付');
      expect(decoded.detected, isFalse);
    });
  });

  group('不支持与无法确定', () {
    test('UTF-16 LE 明确说不支持，而不是猜出一份乱码', () {
      final bytes = <int>[0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00];
      final (decoded, error) = TextDecoding.decode(bytes);

      expect(decoded, isNull);
      expect(error, isA<DecodeUnsupportedEncoding>());
      expect(error!.message, contains('UTF-16'));
    });

    test('UTF-16 BE 同样明确拒绝', () {
      final (decoded, error) = TextDecoding.decode(<int>[0xFE, 0xFF, 0x00, 0x41]);
      expect(decoded, isNull);
      expect(error, isA<DecodeUnsupportedEncoding>());
    });

    test('两种编码都解释不出可读文本时交给用户选', () {
      // 孤立的 0x81 字节：GBK 严格解码失败，UTF-8 宽松解码全是替换字符。
      final bytes = List<int>.filled(64, 0x81);
      final (decoded, error) = TextDecoding.decode(bytes);

      expect(decoded, isNull);
      expect(error, isA<DecodeAmbiguous>());
    });

    test('空文件明确失败', () {
      final (decoded, error) = TextDecoding.decode(<int>[]);
      expect(decoded, isNull);
      expect(error, isA<DecodeEmptyFile>());
    });
  });

  group('供界面使用的元数据', () {
    test('可选编码只有 UTF-8 与 GBK，顺序稳定', () {
      expect(TextDecoding.selectable, <TextEncoding>[
        TextEncoding.utf8,
        TextEncoding.gbk,
      ]);
    });

    test('编码名可以往返存取', () {
      expect(TextEncoding.utf8.storageValue, 'UTF-8');
      expect(TextEncoding.gbk.storageValue, 'GBK');
      expect(TextEncoding.tryParse('GBK'), TextEncoding.gbk);
      expect(TextEncoding.tryParse('UTF-8'), TextEncoding.utf8);
      expect(TextEncoding.tryParse('UTF-16'), isNull);
      expect(TextEncoding.tryParse(null), isNull);
    });

    test('探测结果里带编码名，界面可以显示给用户核对', () {
      final (decoded, _) = TextDecoding.decode(<int>[...wechatGbk, 0x0A]);
      expect(decoded!.encoding.label, contains('GBK'));
    });

    test('纯高位字节、一个 ASCII 都没有的输入不会被当成中文文本', () {
      // 这条锁住上面那条判据存在的理由：GBK 能把这种噪声解成一堆合法汉字。
      final (decoded, error) =
          TextDecoding.decode(List<int>.filled(64, 0x81));
      expect(decoded, isNull);
      expect(error, isA<DecodeAmbiguous>());
    });
  });
}
