import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const RemoteFileManagerApp());
}

class RemoteFileManagerApp extends StatelessWidget {
  const RemoteFileManagerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote File Manager',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

class FileEntry {
  final String name;
  final bool isDir;
  final int? size;
  FileEntry({required this.name, required this.isDir, this.size});
  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        name: j['name'],
        isDir: j['is_dir'] ?? false,
        size: j['size'] == null ? null : (j['size'] as num).toInt(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Dio _dio = Dio();
  final TextEditingController _hostCtrl = TextEditingController();
  List<FileEntry> _entries = [];
  String _currentPath = "";
  bool _loading = false;
  String? _downloadDir;
  SharedPreferences? _prefs;
  static const String PREF_HOST = 'pref_host';
  static const String PREF_DOWNLOAD_DIR = 'pref_download_dir';

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    final host = _prefs?.getString(PREF_HOST);
    final savedDir = _prefs?.getString(PREF_DOWNLOAD_DIR);
    if (host != null && host.isNotEmpty) {
      _hostCtrl.text = host;
      // try to auto list using saved host
      _listFiles("");
    } else {
      // try discovery: runs in background and sets host when found
      _discoverServerAndConnect();
    }
    if (savedDir != null && savedDir.isNotEmpty) _downloadDir = savedDir;
    setState(() {});
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _dio.close();
    super.dispose();
  }

  Future<void> _ensureStoragePermission() async {
    if (Platform.isAndroid) {
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        await Permission.storage.request();
      }
    }
  }

  Future<void> _listFiles(String path) async {
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      _showSnack("No host set");
      return;
    }
    setState(() => _loading = true);
    final encoded = Uri.encodeComponent(path);
    try {
      final resp = await _dio.get("$host/files?path=$encoded",
          options: Options(
            responseType: ResponseType.json,
            sendTimeout: const Duration(milliseconds: 5000),
            receiveTimeout: const Duration(milliseconds: 5000),
          ));

      final data = resp.data;
      final arr = data is Map && data['entries'] != null ? data['entries'] : [];
      final List<FileEntry> list = [];
      for (final e in arr) {
        list.add(FileEntry.fromJson(Map<String, dynamic>.from(e)));
      }
      setState(() {
        _entries = list;
        _currentPath = path;
      });
      // persist host
      await _prefs?.setString(PREF_HOST, host);
    } catch (e) {
      debugPrint("list error: $e");
      _showSnack("Failed to list: $e");
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _downloadFile(String remotePath) async {
    await _ensureStoragePermission();
    final host = _hostCtrl.text.trim();
    final fname = remotePath.split('/').last;
    try {
      Directory outDir;
      if (_downloadDir != null && _downloadDir!.isNotEmpty) {
        outDir = Directory(_downloadDir!);
        if (!await outDir.exists()) await outDir.create(recursive: true);
      } else {
        if (Platform.isAndroid) {
          outDir = (await getExternalStorageDirectory())!;
        } else {
          outDir = await getApplicationDocumentsDirectory();
        }
      }
      final savePath = "${outDir.path}/$fname";
      await _dio.download(
        "$host/download?path=${Uri.encodeComponent(remotePath)}",
        savePath,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (r, t) {
          // optional: progress handling
        },
      );
      _showSnack("Saved: $savePath");
    } catch (e) {
      debugPrint("download error: $e");
      _showSnack("Download failed: $e");
    }
  }

  Future<void> _uploadFile() async {
    await _ensureStoragePermission();
    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) return;
    final host = _hostCtrl.text.trim();
    final fileName = path.split(Platform.pathSeparator).last;
    final form = FormData.fromMap({
      "path": _currentPath,
      "file": await MultipartFile.fromFile(path, filename: fileName),
    });

    try {
      final resp = await _dio.post("$host/upload", data: form);
      _showSnack("Upload result: ${resp.data}");
      await _listFiles(_currentPath);
    } catch (e) {
      debugPrint("upload error: $e");
      _showSnack("Upload failed: $e");
    }
  }

  void _openEntry(FileEntry e) {
    if (e.isDir) {
      final newPath =
          _currentPath.isEmpty ? e.name : "${_currentPath}/${e.name}";
      _listFiles(newPath);
    } else {
      final remote =
          _currentPath.isEmpty ? e.name : "${_currentPath}/${e.name}";
      _downloadFile(remote);
    }
  }

  void _goUp() {
    if (_currentPath.isEmpty) return;
    final parts = _currentPath.split('/');
    parts.removeLast();
    final up = parts.join('/');
    _listFiles(up);
  }

  void _showSnack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  // ---------- directory picker & persistence ----------
  Future<void> _pickDownloadDir() async {
    // file_picker supports directory selection on Android
    String? selected = await FilePicker.platform.getDirectoryPath();
    if (selected == null) return;
    _downloadDir = selected;
    await _prefs?.setString(PREF_DOWNLOAD_DIR, selected);
    setState(() {});
    _showSnack("Download dir set: $selected");
  }

  // ---------- server discovery ----------
  Future<String?> _getLocalIPv4() async {
    for (var iface in await NetworkInterface.list()) {
      for (var addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          // prefer private ranges
          final s = addr.address;
          if (s.startsWith('10.') ||
              s.startsWith('192.') ||
              s.startsWith('172.')) return s;
        }
      }
    }
    return null;
  }

  Future<void> _discoverServerAndConnect() async {
    final localIp = await _getLocalIPv4();
    if (localIp == null) {
      debugPrint("No local IP found");
      return;
    }
    final parts = localIp.split('.');
    if (parts.length != 4) return;
    final prefix = "${parts[0]}.${parts[1]}.${parts[2]}."; // e.g. 192.168.1.
    const port = 5000;
    const timeoutMs = 600; // small timeout per host
    const batchSize = 40;

    _showSnack("Discovering server on $prefix/24 ...");
    // create list of candidate ips
    List<String> candidates =
        List.generate(254, (i) => "$prefix${i + 1}"); // .1 .. .254
    // remove our own ip
    candidates.removeWhere((ip) => ip == localIp);

    String? found;
    for (int i = 0; i < candidates.length; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize);
      final futures = batch.map((ip) async {
        try {
          final url = Uri.parse("http://$ip:$port/files?path=");
          final resp = await _dio.getUri(
            url,
            options: Options(
              receiveTimeout: Duration(milliseconds: timeoutMs),
              sendTimeout: Duration(milliseconds: timeoutMs),
            ),
          );

          if (resp.statusCode == 200) return ip;
        } catch (_) {}
        return null;
      }).toList();
      final results = await Future.wait(futures);
      final ip = results.firstWhere((r) => r != null, orElse: () => null);
      if (ip != null) {
        found = ip as String;
        break;
      }
    }

    if (found != null) {
      final host = "http://$found:$port";
      _hostCtrl.text = host;
      await _prefs?.setString(PREF_HOST, host);
      _showSnack("Server discovered: $host");
      _listFiles("");
    } else {
      _showSnack("Server not found automatically; enter IP manually.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Remote File Manager"),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _pickDownloadDir,
            tooltip: "Choose download directory",
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _uploadFile,
            tooltip: "Upload file to current remote folder",
          ),
          IconButton(
              icon: const Icon(Icons.arrow_upward),
              onPressed: _goUp,
              tooltip: "Up"),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _discoverServerAndConnect,
            tooltip: "Discover server on LAN",
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _hostCtrl,
                  decoration: const InputDecoration(
                    labelText: "Server (e.g. http://192.168.1.12:5000)",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _listFiles(""),
                child: const Text("Connect"),
              )
            ]),
          ),
          Container(
            width: double.infinity,
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
                "Path: /$_currentPath  •  Download dir: ${_downloadDir ?? "(default app external)"}"),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      return ListTile(
                        leading: Icon(
                            e.isDir ? Icons.folder : Icons.insert_drive_file),
                        title: Text(e.name),
                        subtitle:
                            e.size == null ? null : Text("${e.size} bytes"),
                        trailing: e.isDir
                            ? const Icon(Icons.arrow_forward_ios, size: 16)
                            : const Icon(Icons.download, size: 20),
                        onTap: () => _openEntry(e),
                        onLongPress: () {
                          if (!e.isDir)
                            _downloadFile(_currentPath.isEmpty
                                ? e.name
                                : "${_currentPath}/${e.name}");
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
