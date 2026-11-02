// BERT Tokenizer 实现

/// BERT Tokenizer 实现
/// 基于 WordPiece 算法的文本分词器
class BertTokenizer {
  final Map<String, int> _vocab;
  final Map<int, String> _invVocab;
  final int _unkTokenId;
  final int _clsTokenId;
  final int _sepTokenId;
  final int _padTokenId;
  final int _maskTokenId;

  // 特殊标记
  static const String unkToken = '[UNK]';
  static const String clsToken = '[CLS]';
  static const String sepToken = '[SEP]';
  static const String padToken = '[PAD]';
  static const String maskToken = '[MASK]';

  BertTokenizer._({
    required Map<String, int> vocab,
    required Map<int, String> invVocab,
    required int unkTokenId,
    required int clsTokenId,
    required int sepTokenId,
    required int padTokenId,
    required int maskTokenId,
  })  : _vocab = vocab,
        _invVocab = invVocab,
        _unkTokenId = unkTokenId,
        _clsTokenId = clsTokenId,
        _sepTokenId = sepTokenId,
        _padTokenId = padTokenId,
        _maskTokenId = maskTokenId;

  /// 从词汇表字符串创建 tokenizer
  static BertTokenizer fromVocabulary(String vocabText) {
    final lines = vocabText.split('\n');
    final Map<String, int> vocab = {};
    final Map<int, String> invVocab = {};

    for (int i = 0; i < lines.length; i++) {
      final token = lines[i].trim();
      if (token.isNotEmpty) {
        vocab[token] = i;
        invVocab[i] = token;
      }
    }

    return BertTokenizer._(
      vocab: vocab,
      invVocab: invVocab,
      unkTokenId: vocab[unkToken] ?? 100,
      clsTokenId: vocab[clsToken] ?? 101,
      sepTokenId: vocab[sepToken] ?? 102,
      padTokenId: vocab[padToken] ?? 0,
      maskTokenId: vocab[maskToken] ?? 103,
    );
  }

  /// 编码文本为 token IDs
  TokenizerResult tokenize(String text, {required int maxLen}) {
    // 文本预处理
    text = _preprocess(text);

    // 基础分词
    List<String> tokens = _basicTokenize(text);

    // WordPiece 分词
    List<String> wordpieceTokens = [];
    for (String token in tokens) {
      wordpieceTokens.addAll(_wordpieceTokenize(token));
    }

    // 添加特殊标记
    List<String> finalTokens = [clsToken];
    finalTokens.addAll(wordpieceTokens);
    finalTokens.add(sepToken);

    // 截断或填充到固定长度
    if (finalTokens.length > maxLen) {
      finalTokens = finalTokens.sublist(0, maxLen - 1);
      finalTokens.add(sepToken);
    }

    // 转换为 ID（须为可增长 List，后续要 padding；勿用默认 List.filled 的固定长度）
    final inputIds =
        List<int>.from(finalTokens.map((token) => _vocab[token] ?? _unkTokenId));
    final attentionMask =
        List<int>.filled(inputIds.length, 1, growable: true);

    while (inputIds.length < maxLen) {
      inputIds.add(_padTokenId);
      attentionMask.add(0);
    }

    return TokenizerResult(
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokens: finalTokens,
    );
  }

  /// 文本预处理
  String _preprocess(String text) {
    // 转为小写
    text = text.toLowerCase();

    // 移除多余空格
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 处理标点符号
    text = text.replaceAll(RegExp(r'([。，！？；：])'), r' \1 ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return text;
  }

  /// 基础分词
  List<String> _basicTokenize(String text) {
    return text.split(' ').where((token) => token.isNotEmpty).toList();
  }

  /// WordPiece 分词
  List<String> _wordpieceTokenize(String word) {
    if (_vocab.containsKey(word)) {
      return [word];
    }

    List<String> tokens = [];
    int start = 0;

    while (start < word.length) {
      int end = word.length;
      String? curSubstr;

      while (start < end) {
        String substr = word.substring(start, end);
        if (start > 0) {
          substr = '##$substr';
        }

        if (_vocab.containsKey(substr)) {
          curSubstr = substr;
          break;
        }
        end--;
      }

      if (curSubstr == null) {
        tokens.add(unkToken);
        break;
      }

      tokens.add(curSubstr);
      start = end;
    }

    return tokens;
  }

  /// 解码 token IDs 为文本
  String decode(List<int> tokenIds) {
    return tokenIds
        .map((id) => _invVocab[id] ?? unkToken)
        .where((token) =>
            token != clsToken && token != sepToken && token != padToken)
        .join(' ')
        .replaceAll('##', '');
  }

  /// 获取词汇表大小
  int get vocabSize => _vocab.length;

  /// 获取特殊token ID
  int get unkTokenId => _unkTokenId;
  int get clsTokenId => _clsTokenId;
  int get sepTokenId => _sepTokenId;
  int get padTokenId => _padTokenId;
  int get maskTokenId => _maskTokenId;
}

/// Tokenizer 结果
class TokenizerResult {
  final List<int> inputIds;
  final List<int> attentionMask;
  final List<String> tokens;

  TokenizerResult({
    required this.inputIds,
    required this.attentionMask,
    required this.tokens,
  });

  @override
  String toString() {
    return 'TokenizerResult{\n'
        '  tokens: $tokens,\n'
        '  inputIds: $inputIds,\n'
        '  attentionMask: $attentionMask\n'
        '}';
  }
}
