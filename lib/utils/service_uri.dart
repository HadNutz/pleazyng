/// Validates an HTTPS service destination before displaying it or sending data.
bool isHttpsServiceUri(Uri? uri, {String? host, bool allowCustomPort = false}) =>
    uri != null &&
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    (host == null || uri.host == host) &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (allowCustomPort || uri.port == 443);
