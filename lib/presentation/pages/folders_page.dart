import 'package:flutter/material.dart';

import '../localization/app_localizations.dart';
import '../localization/app_text.dart';
import '../widgets/sp_icons.dart';
import 'global_search_page.dart';
import 'local_storage_page.dart';
import 'network_storage_page.dart';

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key, required this.onOpenResult});
  static const searchRouteName = 'folder-search';
  final OpenGlobalSearchResult onOpenResult;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        title: const AppText('文件夹'),
        actions: [
          IconButton(
            key: const Key('folders-search'),
            tooltip: context.l10n.text('搜索文件和文件夹'),
            icon: const Icon(SPIcons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: searchRouteName),
                builder: (_) => GlobalSearchPage(onOpenResult: onOpenResult),
              ),
            ),
          ),
        ],
        bottom: const TabBar(
          dividerColor: Colors.transparent,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelPadding: EdgeInsets.symmetric(horizontal: 20),
          tabs: [
            Tab(key: Key('folders-network-tab'), child: AppText('网络文件夹')),
            Tab(key: Key('folders-local-tab'), child: AppText('本地文件夹')),
          ],
        ),
      ),
      body: const TabBarView(
        children: [
          SingleChildScrollView(
            key: PageStorageKey('folders-network'),
            padding: EdgeInsets.all(20),
            child: NetworkStoragePage(embedded: true),
          ),
          SingleChildScrollView(
            key: PageStorageKey('folders-local'),
            padding: EdgeInsets.all(20),
            child: LocalStoragePage(embedded: true),
          ),
        ],
      ),
    ),
  );
}
