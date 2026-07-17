//
//  KataGoGTP.mm
//  GoLearner
//
//  ObjC++ implementation of the in-process GTP bridge. Ports the reference
//  KataGoCpp.cpp (ChinChangYang/KataGo ios-dev): a pair of thread-safe
//  std::streambufs rebind the engine's cout/cin, and `MainCmds::gtp` is driven
//  with an argv assembled from the caller's backend/threading knobs.
//

#import "KataGoGTP.h"

#include <condition_variable>
#include <mutex>
#include <atomic>
#include <string>
#include <vector>
#include <iostream>

#include "main.h"

using namespace std;

namespace {

// Thread-safe stream buffer (verbatim behavior from the reference bridge): the
// engine writes GTP output here byte-by-byte; the Swift reader blocks in
// underflow/uflow until a newline arrives.
class ThreadSafeStreamBuf : public std::streambuf {
    std::string buffer;
    std::mutex m;
    std::condition_variable cv;
    std::atomic<bool> done {false};

public:
    int overflow(int c) override {
        std::lock_guard<std::mutex> lock(m);
        buffer += static_cast<char>(c);
        if (c == '\n') {
            cv.notify_all();
        }
        return c;
    }

    int underflow() override {
        std::unique_lock<std::mutex> lock(m);
        cv.wait(lock, [&]{ return !buffer.empty() || done; });
        if (buffer.empty()) {
            return std::char_traits<char>::eof();
        }
        return buffer.front();
    }

    int uflow() override {
        std::unique_lock<std::mutex> lock(m);
        cv.wait(lock, [&]{ return !buffer.empty() || done; });
        if (buffer.empty()) {
            return std::char_traits<char>::eof();
        }
        int c = buffer.front();
        buffer.erase(buffer.begin());
        return c;
    }

    void setDone() {
        done = true;
        cv.notify_all();
    }

    void clear() {
        std::lock_guard<std::mutex> lock(m);
        buffer.clear();
    }
};

// Process-global engine I/O streams (one engine per process).
ThreadSafeStreamBuf tsbFromKataGo;
istream inFromKataGo(&tsbFromKataGo);
ThreadSafeStreamBuf tsbToKataGo;
ostream outToKataGo(&tsbToKataGo);

} // namespace

@implementation KataGoGTP

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
                     reTune:(BOOL)reTune {
    // Rebind the engine's global streams to our thread-safe buffers.
    cout.rdbuf(&tsbFromKataGo);
    cin.rdbuf(&tsbToKataGo);

    const int numDevices = (int)deviceAssignments.count;

    vector<string> subArgs;
    subArgs.push_back("gtp");
    subArgs.push_back("-model");
    subArgs.push_back(modelPath.UTF8String);
    subArgs.push_back("-human-model");
    subArgs.push_back(humanModelPath.UTF8String);
    subArgs.push_back("-config");
    subArgs.push_back(configPath.UTF8String);
    // Inference mux: one device code per NN server thread (0 = MLX/GPU,
    // 100 = CoreML/ANE). Order MUST match setup.cpp's read order:
    // numNNServerThreadsPerModel, per-thread devices, then mlxUseFP16.
    subArgs.push_back(string("-override-config numNNServerThreadsPerModel=") + to_string(numDevices));
    for (int i = 0; i < numDevices; i++) {
        subArgs.push_back(string("-override-config mlxDeviceToUseThread") + to_string(i) +
                          "=" + to_string(deviceAssignments[i].intValue));
    }
    subArgs.push_back("-override-config mlxUseFP16=true");
    subArgs.push_back(string("-override-config numSearchThreads=") + to_string(numSearchThreads));
    subArgs.push_back(string("-override-config nnMaxBatchSize=") + to_string(nnMaxBatchSize));
    subArgs.push_back(string("-override-config maxBoardSizeForNNBuffer=") + to_string(maxBoardSizeForNNBuffer));
    subArgs.push_back(string("-override-config requireMaxBoardSize=") + (requireExactNNLen ? "true" : "false"));
    // Point the MLX autotuner's home-data dir at an app-writable location.
    if (homeDataDir.length > 0) {
        subArgs.push_back(string("-override-config homeDataDir=") + homeDataDir.UTF8String);
    }
    subArgs.push_back(string("-override-config mlxTunerFull=") + (tunerFull ? "true" : "false"));
    subArgs.push_back(string("-override-config mlxReTune=") + (reTune ? "true" : "false"));

    MainCmds::gtp(subArgs);
}

+ (NSString *)getMessageLine {
    string line;
    getline(inFromKataGo, line);
    return [NSString stringWithUTF8String:line.c_str()];
}

+ (void)sendCommand:(NSString *)command {
    outToKataGo << command.UTF8String << endl;
}

+ (void)sendMessage:(NSString *)message {
    cout << message.UTF8String;
}

+ (void)clearMessages {
    tsbFromKataGo.clear();
}

@end
