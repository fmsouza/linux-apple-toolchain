#import "CoreLib.h"
#import "CoreLibPrivate.h"
#ifndef CORELIB_FLAG
#error "COMPILER_FLAGS of the build file were not applied"
#endif
NSString *CoreLibGreeting(void) { return [CORELIB_PREFIX stringByAppendingString:@" greeting"]; }
