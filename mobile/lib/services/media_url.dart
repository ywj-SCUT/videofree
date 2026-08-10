String resolveMediaUrl(String serverUrl, String value) {
  if (value.isEmpty) return value;

  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) return value;

  final normalizedBase = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
  final base = Uri.tryParse(normalizedBase);
  if (base == null || !base.hasScheme || base.host.isEmpty) return value;

  return base.resolve(value).toString();
}
