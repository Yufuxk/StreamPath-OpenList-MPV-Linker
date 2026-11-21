import 'package:flutter/material.dart';

class FilmSubpageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FilmSubpageAppBar({
    super.key,
    required this.title,
    required this.sidebarInset,
    this.backgroundColor = Colors.transparent,
    this.actions,
  });

  final Widget title;
  final double sidebarInset;
  final Color backgroundColor;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return AppBar(
      toolbarHeight: preferredSize.height,
      automaticallyImplyLeading: false,
      leadingWidth: canPop ? sidebarInset + 56 : null,
      leading: canPop
          ? Padding(
              padding: EdgeInsets.only(left: sidebarInset),
              child: const BackButton(),
            )
          : null,
      backgroundColor: backgroundColor,
      shape: const Border(),
      title: title,
      actions: actions,
    );
  }
}

class FilmLibraryListTile extends StatelessWidget {
  const FilmLibraryListTile({
    super.key,
    required this.cover,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.onMenu,
  });

  static const padding = EdgeInsets.fromLTRB(16, 16, 16, 0);
  final Widget cover;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onSecondaryTapDown: onMenu == null
        ? null
        : (details) => onMenu!(details.globalPosition),
    child: ListTile(
      leading: SizedBox(
        width: 96,
        height: 54,
        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: cover),
      ),
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: trailing,
    ),
  );
}
