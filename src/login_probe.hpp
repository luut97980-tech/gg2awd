#pragma once

namespace vt {

// Records every HTTP(S) exchange made by the host app into VTMenu/login.log.
// The probe never rewrites a request or a response: it copies the body for the
// log, then forwards the original bytes untouched.
//
// Disabled when VTMenu/noprobe exists, and never installed under safe boot.
void installLoginProbe();

}  // namespace vt
