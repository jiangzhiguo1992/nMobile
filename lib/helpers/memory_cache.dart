class CacheEntry {
  final int? invalid;
  final String key;
  final dynamic val;

  CacheEntry({required this.key, required this.val, this.invalid});
}

class MemoryCache {
  static const String KEY_DRAFT = 'draft';
  Map<String, CacheEntry> _cacheMap = {};

  MemoryCache();

  put(String key, dynamic value) {
    CacheEntry cacheEntry = CacheEntry(key: key, val: value, invalid: 0);
    _cacheMap[key] = cacheEntry;
  }

  get(String key) {
    CacheEntry? cacheEntry = _cacheMap[key];
    if (cacheEntry == null) {
      return null;
    }
    return cacheEntry.val;
  }

  remove(String key) {
    _cacheMap.remove(key);
  }

  // draft
  getDraft(String? targetId) {
    if (targetId == null) return null;
    return get('$targetId:$KEY_DRAFT');
  }

  setDraft(String? targetId, String draft) {
    if (targetId == null) return;
    put('$targetId:$KEY_DRAFT', draft);
  }

  removeDraft(String? targetId) {
    if (targetId == null) return;
    remove('$targetId:$KEY_DRAFT');
  }
}
