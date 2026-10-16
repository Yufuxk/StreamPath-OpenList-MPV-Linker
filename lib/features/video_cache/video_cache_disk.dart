import 'dart:io';
import 'package:ffi/ffi.dart';
import 'dart:ffi';
import 'package:win32/win32.dart';
import 'video_cache_models.dart';

/// 必须在下载 worker 内调用，路径先解析到实际目标卷。
Map<String, dynamic> videoCacheDisk(String path) {
  if (!Platform.isWindows) throw const VideoCacheException('视频缓存仅支持 Windows');
  final target = Directory(path).resolveSymbolicLinksSync();
  final input = target.toNativeUtf16();
  final available = calloc<Uint64>();
  final volume = calloc<Uint16>(32768).cast<Utf16>();
  final fs = calloc<Uint16>(64).cast<Utf16>();
  try {
    if (GetDiskFreeSpaceEx(input, available, nullptr, nullptr) == 0 ||
        GetVolumePathName(input, volume, 32768) == 0 ||
        GetVolumeInformation(
              volume,
              nullptr,
              0,
              nullptr,
              nullptr,
              nullptr,
              fs,
              64,
            ) ==
            0) {
      throw const VideoCacheException('无法读取缓存目录的磁盘空间');
    }
    return {
      'available': available.value,
      'volume': volume.toDartString().toLowerCase(),
      'fat32': fs.toDartString().toUpperCase() == 'FAT32',
    };
  } finally {
    calloc.free(input);
    calloc.free(available);
    calloc.free(volume);
    calloc.free(fs);
  }
}
