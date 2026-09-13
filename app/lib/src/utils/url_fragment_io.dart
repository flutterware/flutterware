/// See `url_fragment.dart` — off the web there is no address bar.
void writeUrlFragment(String fragment) {}

void pushUrlFragment(String fragment, {String? from}) {}

String? get urlFragmentPushedFrom => null;

void urlHistoryBack() {}

Stream<String> get urlFragmentChanges => const Stream.empty();
