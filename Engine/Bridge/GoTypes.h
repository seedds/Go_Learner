//
//  GoTypes.h
//  GoLearner
//
//  Shared Swift-facing value types for the Go domain, independent of any engine.
//  `GoColor` outlives the retired GoBridge (P0 engine pivot): the UI and the
//  stateless replay bridge both speak this enum. Values match KataGo's
//  C_EMPTY / C_BLACK / C_WHITE.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(int, GoColor) {
    GoColorEmpty = 0,
    GoColorBlack = 1,
    GoColorWhite = 2,
};
