part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text(
              "V${App.version}",
              style: const TextStyle(fontSize: 16),
            ),
            Text("Venera is a free and open-source app for comic reading.".tl),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/lll152872/venera-lll/releases");
          },
        ).toSliver(),
        ListTile(
          title: const Text("Telegram"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://t.me/venera_release");
          },
        ).toSliver(),
      ],
    );
  }
}

/// 从 GitHub Releases API 获取最新版本信息
Future<Map<String, dynamic>?> _fetchLatestRelease() async {
  try {
    var res = await AppDio().get(
      "https://api.github.com/repos/lll152872/venera-lll/releases/latest",
      options: Options(headers: {"Accept": "application/vnd.github.v3+json"}),
    );
    if (res.statusCode != 200) return null;
    var data = res.data;
    var tagName = data["tag_name"]?.toString().replaceFirst("v", "") ?? "";
    var assets = data["assets"] as List? ?? [];
    String? apkUrl;
    for (var a in assets) {
      var name = a["name"]?.toString() ?? "";
      if (name.endsWith(".apk")) {
        apkUrl = a["browser_download_url"]?.toString();
        break;
      }
    }
    return {
      "version": tagName,
      "apkUrl": apkUrl,
      "name": data["name"]?.toString() ?? tagName,
      "body": data["body"]?.toString() ?? "",
      "url": data["html_url"]?.toString() ?? "",
    };
  } catch (e) {
    Log.error("Update", "Failed to fetch release: $e");
    return null;
  }
}

Future<bool> checkUpdate() async {
  var release = await _fetchLatestRelease();
  if (release == null) return false;
  return _compareVersion(
    release["version"] as String,
    App.version,
  );
}

Future<void> checkUpdateUi([bool showMessageIfNoUpdate = true, bool delay = false]) async {
  try {
    var release = await _fetchLatestRelease();
    if (release == null) {
      if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(message: "Failed to check for updates".tl);
      }
      return;
    }
    var latestVersion = release["version"] as String;
    if (_compareVersion(latestVersion, App.version)) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      var apkUrl = release["apkUrl"] as String?;
      var body = release["body"] as String? ?? "";
      if (!App.rootContext.mounted) return;

      showDialog(
        context: App.rootContext,
        builder: (ctx) {
          var isDownloading = false;
          var downloadProgress = 0.0;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return ContentDialog(
                title: "v$latestVersion".tl,
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (body.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: SingleChildScrollView(
                          child: Text(body),
                        ),
                      ),
                    if (isDownloading) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: downloadProgress),
                      const SizedBox(height: 4),
                      Text(
                        "${(downloadProgress * 100).toStringAsFixed(0)}%",
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ],
                ),
                actions: [
                  Button.text(
                    onPressed: () => Navigator.pop(context),
                    child: Text("Cancel".tl),
                  ),
                  if (apkUrl != null)
                    Button.filled(
                      isLoading: isDownloading,
                      onPressed: () {
                        if (isDownloading) return;
                        setDialogState(() {
                          isDownloading = true;
                          downloadProgress = 0;
                        });
                        _downloadAndOpen(apkUrl, (progress) {
                          setDialogState(() {
                            downloadProgress = progress;
                          });
                        }).whenComplete(() {
                          if (context.mounted) {
                            Navigator.pop(context);
                          }
                        });
                      },
                      child: Text(isDownloading ? "Downloading...".tl : "Download".tl),
                    )
                  else
                    Button.filled(
                      onPressed: () {
                        Navigator.pop(context);
                        launchUrlString(release["url"] as String);
                      },
                      child: Text("Open Release Page".tl),
                    ),
                ],
              );
            },
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}

/// 下载文件并打开
Future<void> _downloadAndOpen(String url, void Function(double) onProgress) async {
  var downloadsDir = await getApplicationDocumentsDirectory();
  var fileName = "venera-update.apk";
  // Android 下保存到外部存储以便安装
  if (App.isAndroid) {
    try {
      var extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        downloadsDir = extDir;
      }
    } catch (_) {}
  }
  var savePath = "${downloadsDir.path}/$fileName";

  await AppDio().download(
    url,
    savePath,
    onReceiveProgress: (count, total) {
      if (total > 0) {
        onProgress(count / total);
      }
    },
    options: Options(
      responseType: ResponseType.bytes,
      followRedirects: true,
    ),
  );

  // 打开文件触发安装
  if (App.isAndroid || App.isWindows) {
    launchUrlString(savePath);
  }
  // 显示成功消息
  App.rootContext.showMessage(
    message: "Download complete".tl,
  );
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = version1.split(".");
  var v2 = version2.split(".");
  for (var i = 0; i < v1.length; i++) {
    if (i >= v2.length) return true;
    var n1 = int.tryParse(v1[i]) ?? 0;
    var n2 = int.tryParse(v2[i]) ?? 0;
    if (n1 > n2) return true;
    if (n1 < n2) return false;
  }
  return false;
}
