#include <stdint.h>
#include <IOKit/IOMessage.h>

// These SDK macros expand through function-like macros that Swift does not
// import. Resolve the original constants in C instead of duplicating values.
static inline uint32_t MuesliPowerCanSystemSleep(void) { return kIOMessageCanSystemSleep; }
static inline uint32_t MuesliPowerSystemWillSleep(void) { return kIOMessageSystemWillSleep; }
static inline uint32_t MuesliPowerSystemHasPoweredOn(void) { return kIOMessageSystemHasPoweredOn; }
