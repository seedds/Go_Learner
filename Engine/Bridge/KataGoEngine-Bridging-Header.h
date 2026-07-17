//
//  KataGoEngine-Bridging-Header.h
//  Exposes the in-process GTP bridge (KataGoGTP) to the engine smoke-test
//  target, which links the full vendored KataGo engine (libkatago.a +
//  KataGoSwift) rather than the legacy Engine/cpp slice.
//

#import "KataGoGTP.h"
