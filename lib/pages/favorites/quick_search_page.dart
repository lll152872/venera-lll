part of 'favorites_page.dart';

class _QuickSearchPage extends StatefulWidget {
  const _QuickSearchPage();
  @override
  State<_QuickSearchPage> createState() => _QuickSearchPageState();
}

class _QuickSearchPageState extends State<_QuickSearchPage> {
  @override
  Widget build(BuildContext context) {
    var entries = QuickSearchManager().entries;
    return CustomScrollView(
      slivers: [
        SliverAppbar(
          leading: context.width <= _kTwoPanelChangeWidth
              ? IconButton(
                  icon: const Icon(Icons.menu),
                  color: context.colorScheme.primary,
                  onPressed: () => context
                      .findAncestorStateOfType<_FavoritesPageState>()
                      ?.showFolderSelector(),
                )
              : null,
          title: Text("Quick Search".tl),
        ),
        if (entries.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.search_off, size: 64,
                      color: context.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text("No quick search yet".tl),
                  const SizedBox(height: 8),
                  Text("Long press a tag in comic details to save".tl),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: context.width > 900 ? 4 : context.width > 600 ? 3 : 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 3,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildCard(entries[index], index),
                childCount: entries.length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCard(QuickSearchEntry entry, int index) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.to(() => SearchResultPage(
              text: entry.keyword,
              sourceKey: entry.sourceKey,
            )),
        onLongPress: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text("Remove".tl),
              content: Text("Remove this quick search?".tl),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text("Cancel".tl),
                ),
                TextButton(
                  onPressed: () {
                    QuickSearchManager().removeAt(index);
                    Navigator.pop(ctx);
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.search, color: context.colorScheme.secondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.keyword,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(entry.sourceName,
                        style: ts.s12.withColor(context.colorScheme.outline)),
                  ],
                ),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  icon: Icon(Icons.close, size: 18,
                      color: context.colorScheme.outline),
                  onPressed: () => QuickSearchManager().removeAt(index),
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}