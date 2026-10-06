import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/data/models/media_library_item.dart';
import 'package:streampath/data/models/web_dav_file.dart';

class _CountedFile extends WebDavFile {
  _CountedFile(String name, {bool directory = false})
    : super(name: name, href: '/$name', isDirectory: directory);

  var typeReads = 0;

  @override
  bool get isIso {
    typeReads++;
    return super.isIso;
  }
}

void main() {
  test('文件名称不匹配时不解析类型，同名文件仍严格校验类型', () {
    const item = MediaLibraryItem(
      sourceId: 'a',
      parentPath: 'Shows',
      name: 'e1.mkv',
      kind: MediaLibraryKind.video,
    );
    final unrelated = _CountedFile('e2.mkv');
    expect(item.matches(unrelated), isFalse);
    expect(unrelated.typeReads, 0);
    final matched = _CountedFile('e1.mkv');
    expect(item.matches(matched), isTrue);
    expect(matched.typeReads, greaterThan(0));
    expect(item.matches(_CountedFile('e1.mkv', directory: true)), isFalse);
    const disc = MediaLibraryItem(
      sourceId: 'a',
      parentPath: '',
      name: 'Disc',
      kind: MediaLibraryKind.iso,
      discRootPath: 'Disc',
    );
    expect(disc.matches(_CountedFile('Disc', directory: true)), isTrue);
  });
}
