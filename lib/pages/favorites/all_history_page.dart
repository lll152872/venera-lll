part of 'favorites_page.dart';

class _AllHistoryPage extends StatefulWidget {
  const _AllHistoryPage();

  @override
  State<_AllHistoryPage> createState() => _AllHistoryPageState();
}

class _AllHistoryPageState extends State<_AllHistoryPage> {
  var comics = HistoryManager().getAllUnfiltered();

  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    super.dispose();
  }

  void onUpdate() {
    if (!mounted) return;
    setState(() {
      comics = HistoryManager().getAllUnfiltered();
    });
  }

  void _removeHistory(History comic) {
    if (comic.sourceKey.startsWith("Unknown")) {
      HistoryManager().remove(
        comic.id,
        ComicType(int.parse(comic.sourceKey.split(':')[1])),
      );
    } else if (comic.sourceKey == 'local') {
      HistoryManager().remove(
        comic.id,
        ComicType.local,
      );
    } else {
      HistoryManager().remove(
        comic.id,
        ComicType(comic.sourceKey.hashCode),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppbar(
          leading: context.width <= _kTwoPanelChangeWidth
              ? IconButton(
                  icon: const Icon(Icons.menu),
                  color: context.colorScheme.primary,
                  onPressed: () =>
                      context.findAncestorStateOfType<_FavoritesPageState>()
                          ?.showFolderSelector(),
                )
              : null,
          title: Text("All History".tl),
        ),
        if (comics.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history,
                      size: 64, color: context.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text("No history".tl),
                ],
              ),
            ),
          )
        else
          SliverGridComics(
            comics: comics,
            badgeBuilder: (c) => ComicSource.find(c.sourceKey)?.name,
            menuBuilder: (c) => [
              MenuEntry(
                icon: Icons.remove,
                text: 'Remove'.tl,
                color: context.colorScheme.error,
                onClick: () => _removeHistory(c as History),
              ),
            ],
          ),
      ],
    );
  }
}
