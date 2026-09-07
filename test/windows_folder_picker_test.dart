import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streampath/domain/services/windows_folder_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('streampath/folder_picker');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('原生目录选择器返回所选路径', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickDirectory');
          expect(call.arguments, <String, Object>{'title': '选择本地文件夹'});
          return r'D:\Media';
        });

    expect(
      await WindowsFolderPicker.pickDirectory(title: '选择本地文件夹'),
      r'D:\Media',
    );
  });

  test('原生目录选择器取消时返回 null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    expect(await WindowsFolderPicker.pickDirectory(title: '选择本地文件夹'), isNull);
  });
}
