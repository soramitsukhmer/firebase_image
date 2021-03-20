/// Safe way to get a map, never fails
Map<K, V>? asMap<K, V>(dynamic value) {
  if (value is Map<K, V>) {
    return value;
  }
  if (value is Map) {
    try {
      return value.cast<K, V>();
    } catch (_) {}
  }
  return null;
}