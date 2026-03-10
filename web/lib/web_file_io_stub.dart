Future<void> downloadTextFile({
  required String filename,
  required String content,
}) async {
  throw UnsupportedError('File download is only available in web builds.');
}

Future<String?> pickTextFile() async {
  throw UnsupportedError('File import is only available in web builds.');
}
