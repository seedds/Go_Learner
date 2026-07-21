/*
 * largestackthread.h
 * GoLearner addition (NOT upstream KataGo).
 *
 * A minimal drop-in replacement for the subset of std::thread that KataGo uses
 * to spawn its engine-internal threads (search, analyze-callback, NN-server),
 * differing only in that the new thread gets a large explicit stack.
 *
 * Why this exists: std::thread offers no way to set the stack size, so its
 * threads inherit the platform default. On iOS that default is 512 KB, which is
 * too small for KataGo compiled with COMPILE_MAX_BOARD_LEN=37 — the search
 * thread recurses through Search::playoutDescend with multi-KB frames plus a
 * ~40 KB Board::calculateAreaForPla frame, the analyze-callback thread builds
 * ~44 KB of getAnalysisData buffers, and the NN-server thread runs Swift/CoreML
 * prediction frames. All overflow 512 KB and SIGSEGV. Only the Swift-created
 * GTP thread (InProcessKataGoEngine) could previously be given a big stack; this
 * gives the C++-created threads one too, via pthread with a 4 MB stack.
 *
 * It implements exactly the std::thread API the call sites use — default ctor,
 * a variadic (callable, args...) ctor, move construction/assignment, and
 * join()/joinable() — with the same "std::terminate if destroyed while
 * joinable" contract, so it is a literal token-for-token swap at each site.
 */

#ifndef CORE_LARGESTACKTHREAD_H_
#define CORE_LARGESTACKTHREAD_H_

#include <exception>
#include <functional>
#include <memory>
#include <type_traits>

#include <pthread.h>

#include "../core/global.h"

class LargeStackThread {
 public:
  // 4 MB — comfortably covers the deepest engine stacks at
  // COMPILE_MAX_BOARD_LEN=37 while staying far below the GTP thread's 8 MB.
  static constexpr size_t STACK_SIZE = 4 * 1024 * 1024;

  LargeStackThread() noexcept : thread_(), started_(false) {}

  // Mirror std::thread: decay-copy the callable and args, run them on the new
  // thread. SFINAE keeps this from hijacking the move constructor.
  template<
    class F, class... Args,
    class = typename std::enable_if<
      !std::is_same<typename std::decay<F>::type, LargeStackThread>::value
    >::type
  >
  explicit LargeStackThread(F&& f, Args&&... args) : thread_(), started_(false) {
    auto* task = new std::function<void()>(
      std::bind(std::forward<F>(f), std::forward<Args>(args)...)
    );

    pthread_attr_t attr;
    if(pthread_attr_init(&attr) != 0) {
      delete task;
      throw StringError("LargeStackThread: pthread_attr_init failed");
    }
    pthread_attr_setstacksize(&attr, STACK_SIZE);
    int rc = pthread_create(&thread_, &attr, &LargeStackThread::run, task);
    pthread_attr_destroy(&attr);
    if(rc != 0) {
      delete task;
      throw StringError("LargeStackThread: pthread_create failed");
    }
    started_ = true;
  }

  LargeStackThread(const LargeStackThread&) = delete;
  LargeStackThread& operator=(const LargeStackThread&) = delete;

  LargeStackThread(LargeStackThread&& other) noexcept
    : thread_(other.thread_), started_(other.started_) {
    other.started_ = false;
  }

  LargeStackThread& operator=(LargeStackThread&& other) noexcept {
    if(this != &other) {
      // std::thread contract: overwriting a still-joinable thread is a bug.
      if(started_)
        std::terminate();
      thread_ = other.thread_;
      started_ = other.started_;
      other.started_ = false;
    }
    return *this;
  }

  ~LargeStackThread() {
    if(started_)
      std::terminate();
  }

  bool joinable() const noexcept { return started_; }

  void join() {
    if(!started_)
      throw StringError("LargeStackThread: join() on non-joinable thread");
    pthread_join(thread_, nullptr);
    started_ = false;
  }

 private:
  static void* run(void* arg) {
    std::unique_ptr<std::function<void()>> task(
      static_cast<std::function<void()>*>(arg)
    );
    (*task)();
    return nullptr;
  }

  pthread_t thread_;
  bool started_;
};

#endif  // CORE_LARGESTACKTHREAD_H_
