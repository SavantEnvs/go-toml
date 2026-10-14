// Build-time LeakSanitizer off-switch (fleet policy): ASan stays on, leak detection does not.
extern "C" int __lsan_is_turned_off() { return 1; }
