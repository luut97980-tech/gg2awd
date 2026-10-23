#pragma once
#import <Foundation/Foundation.h>

namespace vt {

// Library/Application Support/VTMenu, created on first use.
NSURL* stateFolder();

// Appends one timestamped line to Library/Application Support/VTMenu/<file>.
// Capped at 256 KB per file. Silent on failure: diagnostics must never take the
// host app down, so nothing here throws or returns an error.
void logLineTo(NSString* file,NSString* line);

// Same, into menu.log.
void logLine(NSString* line);

}  // namespace vt
