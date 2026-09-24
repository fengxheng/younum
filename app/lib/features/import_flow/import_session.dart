/// 导入流程的会话状态。
///
/// 与 `ReviewSession` 同一个套路（`ChangeNotifier` + `InheritedNotifier` 作用域），
/// 理由也是一样的：导入是**跨多个页面**的一条流程（选文件 → 解析 → 映射 →
/// 核对 → 重复组 → 提交 → 历史），把状态放在页面里会导致返回上一步就丢。
///
/// 但这个会话**刻意不落盘**：暂存区本身已经落在数据库里了
/// （`import_batch` / `import_row`），所以进程被杀之后「已经解析好的这份账单」
/// 还能从数据库读回来重建；而内存里只留当前这次操作需要的东西
/// （文件字节、映射草稿、重复组的取舍）。
///
/// 文件字节为什么留在内存：重新读一份文件需要系统授权还活着，
/// 而授权随时可能被回收。与其记一个可能失效的引用，不如在这次操作里
/// 拿着字节。用户重新打开应用后再想导入，就从「选择文件」重来 ——
/// 这是指南 4.2.2 说的「URI 仍可能失效，应提供重新选择入口」。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../domain/models/import_records.dart';
import '../../domain/repositories/import_workflow.dart';
import '../../domain/repositories/ledger_file_source.dart';
import '../../domain/repositories/ledger_repository.dart';
import '../../domain/repositories/ledger_store.dart';
import '../../domain/rules/import_rules.dart';
import '../../domain/rules/text_decoding.dart';

/// 导入流程走到哪一步了。
enum ImportPhase {
  /// 还没选文件。
  idle,

  /// 系统文件选择器开着，等用户选。
  ///
  /// 单独一个阶段而不是复用 [reading]：这两件事对用户来说不一样
  /// （一个在挑文件、一个在等解析），而且它是防连点的依据 ——
  /// 少了这个状态，选择器开着的这段时间 [ImportSession.canPick] 仍为真。
  picking,

  /// 正在读文件并解析（I/O 与解析都在这一步完成）。
  reading,

  /// 文件读得出来，但表头认不出来，等用户做字段映射。
  needsMapping,

  /// 已暂存，等用户核对。
  ready,

  /// 正在写正式账。
  committing,

  /// 已提交。
  committed,

  /// 出错了，[ImportSession.errorMessage] 里有原因。
  failed,

  /// 已提交并且又被撤回了。
  reverted,
}

/// 一组疑似重复。
///
/// 指南 4.3 要求「疑似重复必须逐组明确处理……不能只处理第一组却提示全部完成」，
/// 所以分组是这件事的载体：一组一组给用户看，每组都要有明确的取舍。
final class ImportDuplicateGroup {
  const ImportDuplicateGroup({
    required this.key,
    required this.kind,
    required this.rows,
    required this.reason,
  });

  /// 分组键。同源重复用稳定单号，疑似重复用「商户+时间+金额」。
  final String key;

  final DuplicateVerdict kind;

  final List<ImportRow> rows;

  /// 为什么判成重复，直接展示给用户。
  final String reason;

  bool get isSameOrigin => kind == DuplicateVerdict.sameOrigin;

  int get totalCents =>
      rows.fold(0, (sum, row) => sum + (row.amountCents ?? 0));
}

/// 导入会话。
final class ImportSession extends ChangeNotifier {
  ImportSession({
    required this.repository,
    required this.fileSource,
    required this.ledgerId,
    this.sourceNamespace = 'manual',
  });

  final LedgerRepository repository;
  final LedgerFileSource fileSource;
  final int ledgerId;

  /// 来源命名空间。手工导入的文件归到 `manual`。
  ///
  /// 这个值会参与同源去重键，所以它和「微信/支付宝」区分开：
  /// 一份自己整理过的 CSV，不该和平台导出的账单混成同一个来源。
  final String sourceNamespace;

  ImportPhase _phase = ImportPhase.idle;
  String? _errorMessage;
  bool _errorNeedsReselect = false;

  /// 当前这次操作的文件。重试编码、重新映射都要用同一份字节。
  Uint8List? _bytes;
  String? _fileName;
  String? _sourceUri;

  ImportPreview? _preview;
  List<ImportRow> _rows = <ImportRow>[];
  ImportMappingRequired? _mapping;
  ImportCommitResult? _committed;
  List<ImportBatch> _history = <ImportBatch>[];

  /// 用户在核对页上对重复组做的取舍：分组键 → 是否保留。
  final Map<String, bool> _duplicateDecisions = <String, bool>{};

  /// 用户在映射页上手工指定的列。
  ImportFieldMapping? _mappingDraft;

  /// 用户在核对页上手工指定的编码（探测错了的时候）。
  TextEncoding? _encodingOverride;

  ImportPhase get phase => _phase;
  String? get errorMessage => _errorMessage;
  bool get errorNeedsReselect => _errorNeedsReselect;
  String? get fileName => _fileName;
  ImportPreview? get preview => _preview;
  List<ImportRow> get rows => _rows;
  ImportMappingRequired? get mapping => _mapping;
  ImportCommitResult? get committed => _committed;
  List<ImportBatch> get history => _history;
  TextEncoding? get encodingOverride => _encodingOverride;

  /// 用户手工指定的列（映射页的草稿）。
  ImportFieldMapping? get mappingDraft => _mappingDraft;

  bool get isBusy =>
      _phase == ImportPhase.picking ||
      _phase == ImportPhase.reading ||
      _phase == ImportPhase.committing;

  /// 能不能开始选文件。
  bool get canPick => !isBusy;

  /// 核对页上的暂存行：会被写进正式账的那些。
  List<ImportRow> get includableRows => <ImportRow>[
    for (final row in _rows)
      if (row.status != ImportRowStatus.invalid &&
          row.status != ImportRowStatus.duplicate)
        row,
  ];

  /// 校验失败、列出来给用户看的行。
  List<ImportRow> get invalidRows => <ImportRow>[
    for (final row in _rows)
      if (row.status == ImportRowStatus.invalid) row,
  ];

  /// 需要用户逐组处理的重复。
  List<ImportDuplicateGroup> get duplicateGroups => _groupDuplicates();

  /// 还有没处理的重复组。
  bool get hasUndecidedDuplicates => duplicateGroups.any(
    (group) => !_duplicateDecisions.containsKey(group.key),
  );

  /// 已处理的组数 / 总组数。
  int get decidedGroupCount => duplicateGroups
      .where((group) => _duplicateDecisions.containsKey(group.key))
      .length;

  /// 最终会写入正式账的行。
  ///
  /// 这是提交按钮上那个「共 N 笔」的来源，也是 [preview] 与实际结果的
  /// 唯一对照点 —— 两者不一致就说明界面在骗用户。
  List<ImportRow> get rowsToCommit => <ImportRow>[
    for (final row in _rows)
      if (row.status == ImportRowStatus.newRow && row.included) row,
  ];

  int get commitCount => rowsToCommit.length;

  int get commitCents =>
      rowsToCommit.fold(0, (sum, row) => sum + (row.amountCents ?? 0));

  /// 还没处理完的重复组，不能提交。
  bool get canCommit =>
      _phase == ImportPhase.ready && commitCount > 0 && !hasUndecidedDuplicates;

  // ---------------------------------------------------------------------------
  // 选文件与解析
  // ---------------------------------------------------------------------------

  /// 让用户选一份文件，然后立刻解析。
  Future<void> pickAndStage() async {
    if (isBusy) return;

    _errorMessage = null;
    _errorNeedsReselect = false;
    // 先把状态切成「正在选文件」，选择器开着的这段时间才挡得住连点。
    _setPhase(ImportPhase.picking);

    if (!await fileSource.isAvailable()) {
      _fail('这台设备上暂时不能选择文件');
      return;
    }

    final PickOutcome outcome;
    try {
      outcome = await fileSource.pick();
    } on Object catch (error) {
      _fail('打开文件选择器时出错了：$error');
      return;
    }

    switch (outcome) {
      case PickCanceled():
        // 用户取消：什么都不改，回到取消之前的状态。
        // ⚠️ 必须显式恢复，否则阶段会永久停在 picking，
        // 界面上就是一个再也点不动的「选择文件」按钮。
        _setPhase(_previousPhase());
      case PickFailed(:final message, :final needsReselect):
        _errorNeedsReselect = needsReselect;
        _fail(message);
      case DocumentPicked(:final document):
        await stageDocument(document);
    }
  }

  /// 取消或出错之后该回到哪个阶段。
  ImportPhase _previousPhase() {
    if (_bytes == null) return ImportPhase.idle;
    if (_mapping != null) return ImportPhase.needsMapping;
    if (_preview != null) return ImportPhase.ready;
    return ImportPhase.idle;
  }

  /// 直接解析一份文件（选文件之外的入口，测试与「重新解析」也走这里）。
  Future<void> stageDocument(PickedDocument document) async {
    _bytes = document.bytes;
    _fileName = document.name;
    _sourceUri = document.uri;
    _encodingOverride = null;
    _mappingDraft = null;
    await _stage();
  }

  /// 换一个编码重新解析当前文件。
  ///
  /// 编码探测是启发式（见 `text_decoding.dart` 的局限说明），所以必须给用户
  /// 一个「不对，是另一个编码」的出口，而不是让他面对一份乱码没辙。
  Future<void> retryWithEncoding(TextEncoding encoding) async {
    _encodingOverride = encoding;
    await _stage();
  }

  /// 带着用户手工指定的列重新解析。
  Future<void> applyMapping(ImportFieldMapping mapping) async {
    _mappingDraft = mapping;
    await _stage();
  }

  /// 重试当前这份文件。
  Future<void> retry() => _stage();

  Future<void> _stage() async {
    final bytes = _bytes;
    if (bytes == null) {
      _fail('还没有选择文件');
      return;
    }

    // 读文件与解析都放进 loading 状态：指南 4.2.9 要求这些都在后台执行，
    // 界面上给的是不定进度而不是编造的百分比。
    _setPhase(ImportPhase.reading);

    try {
      final result = await repository.stageImport(
        ledgerId: ledgerId,
        fileName: _fileName ?? 'bill.csv',
        bytes: bytes,
        sourceNamespace: sourceNamespace,
        sourceUri: _sourceUri,
        encoding: _encodingOverride,
        mapping: _mappingDraft,
      );

      switch (result) {
        case ImportStaged(:final preview):
          _preview = preview;
          _rows = await repository.importRows(batchId: preview.batchId);
          _mapping = null;
          _duplicateDecisions.clear();
          _setPhase(ImportPhase.ready);
        case ImportMappingRequired():
          _mapping = result;
          _preview = null;
          _rows = <ImportRow>[];
          _setPhase(ImportPhase.needsMapping);
        case ImportStageRejected(:final message):
          _fail(message);
      }
    } on Object catch (error) {
      _fail('解析这份文件时出错了：$error');
    }
  }

  // ---------------------------------------------------------------------------
  // 核对
  // ---------------------------------------------------------------------------

  /// 用户在核对页上取消勾选某一行。
  Future<void> setIncluded(int? rowId, bool included) async {
    if (rowId == null) return;
    _rows = <ImportRow>[
      for (final row in _rows)
        if (row.id == rowId) row.copyWith(included: included) else row,
    ];
    // ⚠️ 不能顺手把 _preview 置空：提交要的是它的 batchId。
    notifyListeners();
    await repository.updateImportRows(<ImportRow>[
      for (final row in _rows)
        if (row.id == rowId) row,
    ]);
  }

  /// 对一组疑似重复做出取舍。
  ///
  /// [keep] 为 true 表示「这确实是两笔，都要留下」。
  Future<void> decideDuplicateGroup(
    ImportDuplicateGroup group, {
    required bool keep,
  }) async {
    _duplicateDecisions[group.key] = keep;
    final changed = <ImportRow>[];
    _rows = <ImportRow>[
      for (final row in _rows)
        if (group.rows.any((candidate) => candidate.id == row.id))
          () {
            // 同源重复不允许「保留成独立一笔」：稳定单号一致就是同一笔，
            // 真的插两条会撞唯一索引。它们只能选择「绑定到已有那一笔」，
            // 因此在这一步一律标成不计入 —— 但这不等于丢掉，
            // 提交时它仍然会给已有交易补一条来源绑定。
            final next = row.copyWith(
              included: !group.isSameOrigin && keep,
              status: row.status,
            );
            changed.add(next);
            return next;
          }()
        else
          row,
    ];
    notifyListeners();
    if (changed.isNotEmpty) await repository.updateImportRows(changed);
  }

  // ---------------------------------------------------------------------------
  // 提交与撤回
  // ---------------------------------------------------------------------------

  Future<void> commit() async {
    final preview = _preview;
    if (!canCommit || preview == null) return;

    _setPhase(ImportPhase.committing);
    try {
      final result = await repository.commitImport(
        ledgerId: ledgerId,
        batchId: preview.batchId,
      );
      _committed = result;
      await loadHistory();
      _setPhase(ImportPhase.committed);
    } on Object catch (error) {
      // 提交是一个事务：失败就是整批没进，不会留下半个批次。
      // 但暂存区还在，用户可以再点一次。
      _fail('保存时出错了：$error');
    }
  }

  /// 撤回一个已提交的批次。
  Future<ImportRevert?> revert(int batchId) async {
    try {
      final revert = await repository.revertImport(batchId: batchId);
      await loadHistory();
      if (_committed?.batch.id == batchId) {
        _setPhase(ImportPhase.reverted);
      } else {
        notifyListeners();
      }
      return revert;
    } on Object catch (error) {
      _fail('撤回时出错了：$error');
      return null;
    }
  }

  /// 丢弃一个还没提交的批次。
  Future<void> discard(int batchId) async {
    try {
      await repository.discardImport(batchId);
      if (_sourceUri != null) await fileSource.release(_sourceUri!);
      if (_preview?.batchId == batchId) reset();
      await loadHistory();
    } on Object catch (error) {
      _fail('丢弃时出错了：$error');
    }
  }

  Future<void> loadHistory() async {
    _history = await repository.importBatches(ledgerId: ledgerId);
    notifyListeners();
  }

  /// 回到「还没选文件」。
  void reset() {
    _bytes = null;
    _fileName = null;
    _sourceUri = null;
    _preview = null;
    _rows = <ImportRow>[];
    _mapping = null;
    _committed = null;
    _mappingDraft = null;
    _encodingOverride = null;
    _duplicateDecisions.clear();
    _errorMessage = null;
    _errorNeedsReselect = false;
    _setPhase(ImportPhase.idle);
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    _errorNeedsReselect = false;
    _setPhase(_previousPhase());
  }

  // ---------------------------------------------------------------------------

  void _fail(String message) {
    _errorMessage = message;
    notifyListeners();
    _phase = ImportPhase.failed;
    notifyListeners();
  }

  void _setPhase(ImportPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  List<ImportDuplicateGroup> _groupDuplicates() {
    final sameOrigin = <String, List<ImportRow>>{};
    final suspected = <String, List<ImportRow>>{};

    for (final row in _rows) {
      switch (row.status) {
        case ImportRowStatus.duplicate:
          final key = row.dedupeKey ?? '${row.id}';
          sameOrigin.putIfAbsent(key, () => <ImportRow>[]).add(row);
        case ImportRowStatus.newRow:
          // 疑似重复在暂存时状态仍是「新增」：它本来就是「默认保留、
          // 只是要用户确认」。靠 issue 上的标记前缀认出来。
          final issue = row.issue;
          if (issue != null &&
              issue.startsWith(suspectedDuplicateIssuePrefix)) {
            final key = ImportRules.weakKeyOf(
              merchant: row.merchant ?? '',
              occurredAtMs: row.occurredAtMs ?? 0,
              amountCents: row.amountCents ?? 0,
            );
            suspected.putIfAbsent(key, () => <ImportRow>[]).add(row);
          }
        case ImportRowStatus.invalid:
        case ImportRowStatus.skipped:
        case ImportRowStatus.imported:
          break;
      }
    }

    return <ImportDuplicateGroup>[
      for (final entry in sameOrigin.entries)
        ImportDuplicateGroup(
          key: entry.key,
          kind: DuplicateVerdict.sameOrigin,
          rows: entry.value,
          reason: '这份账单里的交易单号，库里已经有了同一笔',
        ),
      for (final entry in suspected.entries)
        ImportDuplicateGroup(
          key: entry.key,
          kind: DuplicateVerdict.suspected,
          rows: entry.value,
          reason: '商户、时间、金额与另一笔完全一致，但账单里没有交易单号',
        ),
    ];
  }
}

/// 让整棵树都能拿到导入会话。
///
/// 与 `ReviewSessionScope` 同样的写法：`InheritedNotifier` 会在会话
/// `notifyListeners()` 时重建依赖它的页面。
class ImportSessionScope extends InheritedNotifier<ImportSession> {
  const ImportSessionScope({
    super.key,
    required ImportSession session,
    required super.child,
  }) : super(notifier: session);

  static ImportSession of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ImportSessionScope>();
    assert(scope != null, 'ImportSessionScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }

  /// 不需要订阅变化时使用，例如在异步回调里读取。
  static ImportSession read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ImportSessionScope>();
    assert(scope != null, 'ImportSessionScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }
}
