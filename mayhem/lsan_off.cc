// Leak detection off at build time (SPEC §6.2 item 15); ASan and UBSan stay fully active.
extern "C" int __lsan_is_turned_off() { return 1; }
