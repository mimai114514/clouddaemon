import 'web_file_io_stub.dart'
    if (dart.library.html) 'web_file_io_web.dart' as impl;

Future<void> downloadTextFile({
  required String filename,
  required String content,
}) {
  return impl.downloadTextFile(filename: filename, content: content);
}

Future<String?> pickTextFile() {
  return impl.pickTextFile();
}
