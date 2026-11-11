class FilmExtraType {
  const FilmExtraType(this.id, this.label, this.aliases, {this.custom = false});
  final String id, label;
  final List<String> aliases;
  final bool custom;

  factory FilmExtraType.fromJson(Map<String, dynamic> value) => FilmExtraType(
    value['id'] as String,
    value['label'] as String,
    (value['aliases'] as List).cast<String>(),
    custom: value['custom'] == true,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'label': label,
    'aliases': aliases,
    'custom': custom,
  };
}

class FilmExtraRules {
  const FilmExtraRules({this.revision = 1, this.types = defaults});
  final int revision;
  int get classificationVersion => revision * 1000 + 1;
  final List<FilmExtraType> types;
  static const genericAliases = [
    'Extras',
    'Extra',
    'Specials',
    'Bonus',
    'Bonus Features',
    '特典',
    '映像特典',
    '特典映像',
  ];
  static const defaults = [
    FilmExtraType('ncop', 'NCOP', [
      'NCOP',
      'Creditless OP',
      'Non Credit OP',
      '无字幕OP',
      '無字幕OP',
      'ノンクレジットOP',
      'ノンクレジットオープニング',
    ]),
    FilmExtraType('nced', 'NCED', [
      'NCED',
      'Creditless ED',
      'Non Credit ED',
      '无字幕ED',
      '無字幕ED',
      'ノンクレジットED',
      'ノンクレジットエンディング',
    ]),
    FilmExtraType('sp', 'SP', [
      'SP',
      'SPs',
      'Special',
      '特别篇',
      '特別篇',
      '特別編',
      '番外篇',
      '番外編',
      '番外',
    ]),
    FilmExtraType('pv', 'PV', [
      'PV',
      'PVs',
      'Promo',
      'Promos',
      'Promotion Video',
      '宣传影像',
      '宣傳影像',
      'プロモーション映像',
    ]),
    FilmExtraType('cm', 'CM', [
      'CM',
      'CMs',
      'Commercial',
      'Commercials',
      '广告',
      '廣告',
    ]),
    FilmExtraType('menu', 'MENU', ['MENU', 'MENUs', '菜单影像', '菜單影像']),
    FilmExtraType('info', 'INFO', [
      'INFO',
      'INFOs',
      'Information',
      '介绍影像',
      '介紹影像',
    ]),
    FilmExtraType('ova', 'OVA / OAD', [
      'OVA',
      'OVAs',
      'OAV',
      'OAVs',
      'OAD',
      'OADs',
    ]),
    FilmExtraType('ona', 'ONA', ['ONA', 'ONAs']),
    FilmExtraType('trailer', '预告片', [
      'Trailer',
      'Trailers',
      'Teaser',
      'Teasers',
      '预告片',
      '預告片',
      '预告',
      '預告',
      '予告編',
    ]),
    FilmExtraType('next', '下集预告', ['NEXT', '次回予告', '下集预告', '下集預告']),
    FilmExtraType('eyecatch', '过场动画', [
      'EYECATCH',
      'EYECATCHs',
      'EVECATCH',
      'アイキャッチ',
      '过场动画',
      '過場動畫',
    ]),
    FilmExtraType('making_of', '幕后花絮', [
      'Making Of',
      'Behind the Scenes',
      '幕后花絮',
      '幕後花絮',
      '花絮',
      'メイキング',
    ]),
    FilmExtraType('interview', '访谈', [
      'Interview',
      'Interviews',
      '访谈',
      '訪談',
      'インタビュー',
    ]),
    FilmExtraType('deleted_scene', '删减片段', [
      'Deleted Scene',
      'Deleted Scenes',
      '删减片段',
      '刪減片段',
      '未公開シーン',
    ]),
    FilmExtraType('featurette', '制作特辑', [
      'Featurette',
      'Featurettes',
      '制作特辑',
      '製作特輯',
    ]),
    FilmExtraType('short', '短片', ['Short', 'Shorts', '短片']),
    FilmExtraType('music_video', '音乐影像', ['MV', 'Music Video', '音乐影像', '音樂影像']),
    FilmExtraType('event', '活动影像', [
      'Live Event',
      'Stage Greeting',
      '舞台挨拶',
      '活动影像',
      '活動影像',
    ]),
    FilmExtraType('mixed', '混合特典', []),
    FilmExtraType('other', '其他特典', genericAliases),
  ];

  factory FilmExtraRules.fromJson(Map<String, dynamic> value) => FilmExtraRules(
    revision: value['revision'] as int,
    types: (value['types'] as List)
        .map((e) => FilmExtraType.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
  Map<String, Object> toJson() => {
    'revision': revision,
    'types': types.map((t) => t.toJson()).toList(),
  };
  FilmExtraType type(String id) => types.firstWhere((t) => t.id == id);
}

class FilmExtraClassification {
  const FilmExtraClassification({
    this.kind,
    this.origin = 'unset',
    this.status = 'unknown',
    this.keywords = const [],
    this.kinds = const [],
    this.directory,
  });
  final String? kind;
  final String origin, status;
  final List<String> keywords, kinds;
  final String? directory;
  bool get isExtra => status == 'extra';
  Map<String, Object> get evidence => {
    'keywords': keywords,
    'kinds': kinds,
    'directory': ?directory,
  };
  FilmExtraClassification inDirectory(String value) => FilmExtraClassification(
    kind: kind,
    origin: origin,
    status: status,
    keywords: keywords,
    kinds: kinds,
    directory: value,
  );
}
