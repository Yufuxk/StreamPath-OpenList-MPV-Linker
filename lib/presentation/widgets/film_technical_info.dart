import 'package:flutter/material.dart';

import '../controllers/film_catalog_controller.dart';
import '../localization/app_localizations.dart';
import '../localization/app_text.dart';

List<String> filmTechnicalTags(Map<String, dynamic>? info) {
  final video = (info?['video'] as List? ?? []).whereType<Map>().firstOrNull;
  if (video == null) return [];
  return [
    if (video['hdr'] != null && '${video['hdr']}'.isNotEmpty) '${video['hdr']}',
    if (video['width'] != null && video['height'] != null)
      '${video['width']} × ${video['height']}',
  ];
}

String _size(num bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble(), index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(index == 0 ? 0 : 2)} ${units[index]}';
}

/// 参数只来自探测缓存，打开详情不会读取媒体内容。
class FilmTechnicalInfo extends StatelessWidget {
  const FilmTechnicalInfo({super.key, required this.info});
  final Map<String, dynamic>? info;

  @override
  Widget build(BuildContext context) {
    final data = info;
    if (data == null) return const AppText('尚未探测；默认在播放时获取视频信息');
    final l10n = context.l10n;
    Widget field(String label, Object? value) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SelectableText('${l10n.text(label)}：${value ?? l10n.text('未知')}'),
    );
    String? bitrate(Object? value) =>
        value is num ? '${(value / 1000000).toStringAsFixed(2)} Mb/s' : null;
    final duration = data['duration'];
    final videos = (data['video'] as List? ?? []).whereType<Map>().toList();
    final audio = (data['audio'] as List? ?? []).whereType<Map>().toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data['state'] == 'failed' || data['fullProbeState'] == 'failed')
          AppText(filmCatalogErrorText(data['error'] as String)),
        if (data['state'] == 'partial' || data['fullProbeState'] == 'partial')
          const AppText('已达到读取上限；以下仅显示已获取的参数'),
        field('参数来源', data['origin']),
        field(
          '文件体积',
          data['fileSize'] is num ? _size(data['fileSize'] as num) : null,
        ),
        field(
          '实际时长',
          duration is num
              ? Duration(
                  milliseconds: (duration * 1000).round(),
                ).toString().split('.').first
              : null,
        ),
        if (data['programme'] != null)
          field(
            data['programmeType'] == 'edition' ? '当前蓝光 Title' : '蓝光播放列表',
            data['programme'],
          ),
        if (data['programmes'] != null) const AppText('完整探测的时长与视频参数对应最长主标题'),
        field('总码率', bitrate(data['bitrate'])),
        for (var i = 0; i < videos.length; i++) ...[
          const SizedBox(height: 12),
          Text(
            l10n.format('视频轨道 {number}', {'number': i + 1}),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          field('编码', videos[i]['codec']),
          field(
            '分辨率',
            videos[i]['width'] == null || videos[i]['height'] == null
                ? null
                : '${videos[i]['width']} × ${videos[i]['height']}',
          ),
          field('特殊视频参数', videos[i]['hdr']),
          if (videos[i]['hdrProfile'] != null)
            field('HDR / DV Profile', videos[i]['hdrProfile']),
          field('码率', bitrate(videos[i]['bitrate'])),
          field('帧率', videos[i]['frameRate']),
          field('位深', videos[i]['bitDepth']),
          field('传递函数', videos[i]['transfer']),
          field('色域', videos[i]['colorPrimaries']),
        ],
        for (var i = 0; i < audio.length; i++) ...[
          const SizedBox(height: 12),
          Text(
            l10n.format('音频轨道 {number}', {'number': i + 1}),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          field('编码', audio[i]['codec']),
          if (audio[i]['profile'] != null) field('音频配置', audio[i]['profile']),
          field('语言', audio[i]['language']),
          if (audio[i]['title'] != null) field('轨道标题', audio[i]['title']),
          field('声道数', audio[i]['channels']),
          field(
            '采样率',
            audio[i]['sampleRate'] is num
                ? '${audio[i]['sampleRate']} Hz'
                : null,
          ),
          field('位深', audio[i]['bitDepth']),
          field('码率', bitrate(audio[i]['bitrate'])),
        ],
      ],
    );
  }
}
