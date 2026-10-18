/// Keep the original subscription untouched; this helper only amends the
/// in-memory copy that Bettbox sends to the running Mihomo configuration.
///
/// Smart's persistent online Bandit and Tiny Router learn from completed
/// connections independently of `collectdata`. That option only writes an
/// optional CSV for offline model training. Converted groups can use the
/// bundled LightGBM baseline immediately unless the profile explicitly
/// requested a different model policy.
bool enableSmartLearningForConvertedGroup(
  Map group,
  Set<String> convertedGroupNames,
) {
  final name = group['name'];
  if (name is! String ||
      name == 'GLOBAL' ||
      !convertedGroupNames.contains(name)) {
    return false;
  }
  const convertible = {'select', 'url-test', 'fallback', 'load-balance'};
  if (!convertible.contains(group['type'])) return false;

  group['type'] = 'smart';
  // Preserve explicitly supplied false. This changes only newly converted
  // groups; Smart groups originating in YAML retain their own defaults.
  group.putIfAbsent('uselightgbm', () => true);
  // Do NOT enable collectdata by default. Online learning is already active;
  // raw training CSV collection is opt-in for privacy/disk endurance.
  return true;
}
