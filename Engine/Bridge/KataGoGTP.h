//
//  KataGoGTP.h
//  GoLearner
//
//  Objective-C façade over the vendored KataGo engine's in-process GTP loop.
//  Mirrors the reference (ChinChangYang/KataGo ios-dev) KataGoCpp bridge: the
//  engine's std::cout/std::cin are rebound to two thread-safe stream buffers so
//  Swift can drive `MainCmds::gtp` over GTP without a subprocess (iOS forbids
//  spawning one). All methods are class methods because the engine + its I/O
//  buffers are process-global (one engine per process).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KataGoGTP : NSObject

/// Launch the engine's GTP loop on the CURRENT thread. Blocks until the engine
/// exits (i.e. a `quit` command), so callers run this on a dedicated thread.
///
/// `deviceAssignments` holds one inference device code per NN-server thread
/// (0 = MLX/GPU, 100 = CoreML/ANE). On the Simulator, pass a single 100 (ANE)
/// entry — MLX/GPU inference is unavailable there. `homeDataDir` must be an
/// app-writable path (the sandbox container root is not writable, and the MLX
/// Winograd autotuner aborts otherwise); pass the app's Application Support dir.
+ (void)runGTPWithModelPath:(NSString *)modelPath
             humanModelPath:(NSString *)humanModelPath
                 configPath:(NSString *)configPath
          deviceAssignments:(NSArray<NSNumber *> *)deviceAssignments
           numSearchThreads:(int)numSearchThreads
             nnMaxBatchSize:(int)nnMaxBatchSize
      maxBoardSizeForNNBuffer:(int)maxBoardSizeForNNBuffer
          requireExactNNLen:(BOOL)requireExactNNLen
                homeDataDir:(NSString *)homeDataDir
                  tunerFull:(BOOL)tunerFull
                     reTune:(BOOL)reTune
    NS_SWIFT_NAME(runGTP(modelPath:humanModelPath:configPath:deviceAssignments:numSearchThreads:nnMaxBatchSize:maxBoardSizeForNNBuffer:requireExactNNLen:homeDataDir:tunerFull:reTune:));

/// Block until the next output line from the engine is available; returns it
/// without the trailing newline. Returns @"" at end-of-output.
+ (NSString *)getMessageLine;

/// Send one GTP command to the engine (a newline is appended).
+ (void)sendCommand:(NSString *)command;

/// Drop buffered, not-yet-read output lines left by a prior engine run.
+ (void)clearMessages;

@end

NS_ASSUME_NONNULL_END
